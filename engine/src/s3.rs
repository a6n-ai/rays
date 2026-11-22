//! S3-compatible buckets: provider presets, secrets, `s3://bucket/key` links, request signing and listing.
//! See docs/designs/s3-buckets.md.
use crate::types::EngineError;
use rusty_s3::actions::{ListObjectsV2, S3Action};
use rusty_s3::{Bucket, Credentials, UrlStyle};
use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::Duration;

/// Each GET is signed as it is sent; S3 checks the signature only when a request starts.
const SIGN_FOR: Duration = Duration::from_secs(3600);
const KEYCHAIN_SERVICE: &str = "ai.a6n.rays.s3";

/// A bucket Rays can browse and download from. The secret key is never part of it.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BucketConfig {
    pub name: String,
    /// A preset id from `providers()`, or "generic".
    pub provider: String,
    pub endpoint: String,
    pub region: String,
    pub access_key_id: String,
    pub path_style: bool,
}

/// A cloud provider preset. `endpoint` may contain `{region}` and `{field}`, where `field` names the one extra
/// value the provider needs (for example `account_id`); an empty template means the user types the endpoint.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ProviderPreset {
    pub id: String,
    pub name: String,
    pub endpoint: String,
    pub region: String,
    pub region_hint: String,
    pub field: Option<String>,
    pub field_label: Option<String>,
    pub path_style: bool,
}

/// (id, name, endpoint template, default region, region hint, extra field, field label, path style)
type Row = (&'static str, &'static str, &'static str, &'static str, &'static str, Option<&'static str>, Option<&'static str>, bool);

// shortcut: templates are from each provider's docs as of 2026-11; a preset only pre-fills fields the user can edit.
const PRESETS: &[Row] = &[
    ("aws", "Amazon S3", "https://s3.{region}.amazonaws.com", "us-east-1", "us-east-1", None, None, false),
    ("r2", "Cloudflare R2", "https://{account_id}.r2.cloudflarestorage.com", "auto", "auto", Some("account_id"), Some("Account ID"), true),
    ("b2", "Backblaze B2", "https://s3.{region}.backblazeb2.com", "", "us-west-004", None, None, false),
    ("wasabi", "Wasabi", "https://s3.{region}.wasabisys.com", "us-east-1", "us-east-1", None, None, false),
    ("spaces", "DigitalOcean Spaces", "https://{region}.digitaloceanspaces.com", "nyc3", "nyc3", None, None, false),
    ("gcs", "Google Cloud Storage", "https://storage.googleapis.com", "auto", "auto", None, None, true),
    ("hetzner", "Hetzner Object Storage", "https://{region}.your-objectstorage.com", "fsn1", "fsn1, nbg1, hel1", None, None, false),
    ("linode", "Akamai / Linode", "https://{region}.linodeobjects.com", "", "us-east-1", None, None, false),
    ("scaleway", "Scaleway", "https://s3.{region}.scw.cloud", "fr-par", "fr-par", None, None, false),
    ("ovh", "OVHcloud", "https://s3.{region}.io.cloud.ovh.net", "", "gra", None, None, false),
    ("oracle", "Oracle Cloud", "https://{namespace}.compat.objectstorage.{region}.oraclecloud.com", "", "us-ashburn-1", Some("namespace"), Some("Namespace"), true),
    ("alibaba", "Alibaba Cloud OSS", "https://oss-{region}.aliyuncs.com", "", "cn-hangzhou", None, None, false),
    ("supabase", "Supabase Storage", "https://{project_ref}.supabase.co/storage/v1/s3", "", "us-east-1", Some("project_ref"), Some("Project ref"), true),
    ("tigris", "Tigris", "https://fly.storage.tigris.dev", "auto", "auto", None, None, false),
    ("minio", "MinIO / self-hosted", "", "us-east-1", "us-east-1", None, None, true),
    ("generic", "Generic S3", "", "us-east-1", "us-east-1", None, None, false),
];

pub fn providers() -> Vec<ProviderPreset> {
    PRESETS
        .iter()
        .map(|&(id, name, endpoint, region, region_hint, field, field_label, path_style)| ProviderPreset {
            id: id.into(),
            name: name.into(),
            endpoint: endpoint.into(),
            region: region.into(),
            region_hint: region_hint.into(),
            field: field.map(Into::into),
            field_label: field_label.map(Into::into),
            path_style,
        })
        .collect()
}

/// Fills a preset's endpoint template. Fails if the template needs a value that is empty.
pub fn endpoint_for(provider: &str, region: &str, field: &str) -> Result<String, EngineError> {
    let p = providers().into_iter().find(|p| p.id == provider).ok_or_else(|| invalid(format!("unknown provider {provider}")))?;
    if p.endpoint.is_empty() {
        return Err(invalid(format!("{} needs an endpoint URL", p.name)));
    }
    let mut out = p.endpoint.replace("{region}", region);
    if let Some(name) = &p.field {
        out = out.replace(&format!("{{{name}}}"), field);
    }
    if region.is_empty() && p.endpoint.contains("{region}") || field.is_empty() && p.field.is_some() {
        return Err(invalid(format!("{} needs {}", p.name, p.field_label.unwrap_or_else(|| "a region".into()))));
    }
    Ok(out)
}

fn invalid(msg: String) -> EngineError {
    EngineError::InvalidUrl { msg }
}

/// Where secret access keys live. The app uses the Keychain; tests use memory so they never touch it.
pub trait Secrets: Send + Sync {
    fn get(&self, bucket: &str) -> Option<String>;
    fn set(&self, bucket: &str, secret: &str) -> Result<(), EngineError>;
    fn delete(&self, bucket: &str);
}

pub struct Keychain;

impl Secrets for Keychain {
    fn get(&self, bucket: &str) -> Option<String> {
        let bytes = security_framework::passwords::get_generic_password(KEYCHAIN_SERVICE, bucket).ok()?;
        String::from_utf8(bytes).ok()
    }

    fn set(&self, bucket: &str, secret: &str) -> Result<(), EngineError> {
        security_framework::passwords::set_generic_password(KEYCHAIN_SERVICE, bucket, secret.as_bytes())
            .map_err(|e| EngineError::Io { msg: format!("keychain: {e}") })
    }

    fn delete(&self, bucket: &str) {
        let _ = security_framework::passwords::delete_generic_password(KEYCHAIN_SERVICE, bucket);
    }
}

#[derive(Default)]
pub struct MemorySecrets(Mutex<HashMap<String, String>>);

impl Secrets for MemorySecrets {
    fn get(&self, bucket: &str) -> Option<String> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).get(bucket).cloned()
    }

    fn set(&self, bucket: &str, secret: &str) -> Result<(), EngineError> {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).insert(bucket.into(), secret.into());
        Ok(())
    }

    fn delete(&self, bucket: &str) {
        self.0.lock().unwrap_or_else(PoisonError::into_inner).remove(bucket);
    }
}

/// `s3://bucket/key` split into its bucket and key. The key keeps its slashes and is percent-decoded.
pub fn parse_link(link: &str) -> Option<(String, String)> {
    let rest = link.strip_prefix("s3://")?;
    let (bucket, key) = rest.split_once('/')?;
    let key = percent_decode(key);
    (!bucket.is_empty() && !key.is_empty()).then(|| (bucket.to_owned(), key))
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && let Some(b) = s.get(i + 1..i + 3).and_then(|h| u8::from_str_radix(h, 16).ok())
        {
            out.push(b);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Signs requests for one bucket.
pub struct Signer {
    bucket: Bucket,
    creds: Credentials,
}

impl Signer {
    pub fn new(cfg: &BucketConfig, secret: &str) -> Result<Signer, EngineError> {
        let endpoint = reqwest::Url::parse(&cfg.endpoint).map_err(|e| invalid(format!("endpoint: {e}")))?;
        let style = if cfg.path_style { UrlStyle::Path } else { UrlStyle::VirtualHost };
        let region = if cfg.region.is_empty() { "us-east-1".to_owned() } else { cfg.region.clone() };
        let bucket = Bucket::new(endpoint, style, cfg.name.clone(), region).map_err(|e| invalid(format!("bucket: {e}")))?;
        Ok(Signer { bucket, creds: Credentials::new(cfg.access_key_id.clone(), secret.to_owned()) })
    }

    /// A fresh pre-signed GET URL for `key`.
    pub fn get(&self, key: &str) -> String {
        self.bucket.get_object(Some(&self.creds), key).sign(SIGN_FOR).to_string()
    }

    /// One level of `prefix`: folders, then objects, and the token for the next page.
    pub async fn list(&self, client: &reqwest::Client, prefix: &str, token: Option<&str>) -> Result<Listing, EngineError> {
        let mut action = self.bucket.list_objects_v2(Some(&self.creds));
        action.with_delimiter("/");
        if !prefix.is_empty() {
            action.with_prefix(prefix);
        }
        if let Some(t) = token {
            action.with_continuation_token(t);
        }
        let url = action.sign(SIGN_FOR);
        let io = |e: reqwest::Error| EngineError::Io { msg: format!("list: {e}") };
        let resp = client.get(url).send().await.map_err(io)?;
        let status = resp.status();
        let body = resp.text().await.map_err(io)?;
        if !status.is_success() {
            return Err(EngineError::Io { msg: format!("list: HTTP {} {}", status.as_u16(), s3_error(&body)) });
        }
        let parsed = ListObjectsV2::parse_response(&body).map_err(|e| EngineError::Io { msg: format!("list: {e}") })?;
        Ok(Listing {
            folders: parsed.common_prefixes.into_iter().map(|p| p.prefix).collect(),
            objects: parsed
                .contents
                .into_iter()
                .map(|o| BucketObject { key: o.key, size: o.size.unwrap_or(0), modified: o.last_modified.unwrap_or_default() })
                .collect(),
            next_token: parsed.next_continuation_token,
        })
    }
}

/// The `<Code>` of an S3 XML error body, so "SignatureDoesNotMatch" or "AccessDenied" reaches the user.
fn s3_error(body: &str) -> String {
    let code = body.split_once("<Code>").and_then(|(_, r)| r.split_once("</Code>")).map(|(c, _)| c);
    code.unwrap_or("").to_owned()
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct BucketObject {
    pub key: String,
    pub size: u64,
    pub modified: String,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq, Default)]
pub struct Listing {
    pub folders: Vec<String>,
    pub objects: Vec<BucketObject>,
    pub next_token: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(path_style: bool) -> BucketConfig {
        BucketConfig {
            name: "media".into(),
            provider: "generic".into(),
            endpoint: "https://s3.example.com".into(),
            region: "eu-1".into(),
            access_key_id: "AKID".into(),
            path_style,
        }
    }

    #[test]
    fn links_split_into_bucket_and_key() {
        assert_eq!(parse_link("s3://media/a/b%20c.zip"), Some(("media".into(), "a/b c.zip".into())));
        assert_eq!(parse_link("s3://media/"), None);
        assert_eq!(parse_link("s3:///x"), None);
        assert_eq!(parse_link("https://media/x"), None);
    }

    #[test]
    fn signed_get_carries_a_signature_and_never_the_secret() {
        let url = Signer::new(&cfg(true), "TOPSECRET").unwrap().get("a/b c.zip");
        assert!(url.starts_with("https://s3.example.com/media/a/b%20c.zip?"), "{url}");
        assert!(url.contains("X-Amz-Signature=") && url.contains("X-Amz-Credential=AKID"), "{url}");
        assert!(!url.contains("TOPSECRET"));
        let vhost = Signer::new(&cfg(false), "s").unwrap().get("k");
        assert!(vhost.starts_with("https://media.s3.example.com/k?"), "{vhost}");
    }

    #[test]
    fn presets_fill_their_endpoints() {
        assert_eq!(endpoint_for("r2", "auto", "abc123").unwrap(), "https://abc123.r2.cloudflarestorage.com");
        assert_eq!(endpoint_for("aws", "eu-west-1", "").unwrap(), "https://s3.eu-west-1.amazonaws.com");
        assert!(endpoint_for("r2", "auto", "").is_err());
        assert!(endpoint_for("generic", "x", "").is_err());
        assert!(endpoint_for("nope", "x", "").is_err());
        let ids: Vec<String> = providers().into_iter().map(|p| p.id).collect();
        assert!(ids.contains(&"generic".to_string()) && ids.len() == PRESETS.len());
    }

    #[test]
    fn s3_error_code_is_extracted() {
        assert_eq!(s3_error("<Error><Code>AccessDenied</Code></Error>"), "AccessDenied");
        assert_eq!(s3_error("nope"), "");
    }
}
