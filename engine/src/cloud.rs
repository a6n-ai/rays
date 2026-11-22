//! Logged-in cloud CLIs as a key source: a bucket linked to an AWS profile gets its keys from
//! `aws configure export-credentials` when needed, so Rays stores no secret for it.
use std::collections::HashMap;
use std::process::Command;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

/// Short enough that `aws login` and SSO sessions (often 1 hour) are re-read well before they expire.
const CACHE_FOR: Duration = Duration::from_secs(300);

#[derive(Clone, Debug, PartialEq)]
pub struct Keys {
    pub key: String,
    pub secret: String,
    pub token: Option<String>,
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AwsBucket {
    pub name: String,
    pub region: String,
}

static CACHE: Mutex<Option<HashMap<String, (Keys, Instant)>>> = Mutex::new(None);
/// A bucket's region never changes, and asking costs one `aws` run per bucket.
static REGIONS: Mutex<Option<HashMap<String, String>>> = Mutex::new(None);

/// Keys for an AWS CLI profile, from the CLI itself (saved keys, `aws login`, SSO or credential_process).
pub fn aws_keys(profile: &str) -> Result<Keys, String> {
    let mut cache = CACHE.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some((keys, at)) = cache.as_ref().and_then(|c| c.get(profile))
        && at.elapsed() < CACHE_FOR
    {
        return Ok(keys.clone());
    }
    let out = aws(&["configure", "export-credentials", "--profile", profile, "--format", "process"])?;
    let keys = parse_keys(&out)?;
    cache.get_or_insert_with(HashMap::new).insert(profile.to_owned(), (keys.clone(), Instant::now()));
    Ok(keys)
}

pub fn aws_profiles() -> Vec<String> {
    aws(&["configure", "list-profiles"])
        .map(|out| out.lines().map(str::trim).filter(|l| !l.is_empty()).map(str::to_owned).collect())
        .unwrap_or_default()
}

/// Buckets the profile can see, each with its region (S3 needs the bucket's own regional endpoint).
pub fn aws_buckets(profile: &str) -> Result<Vec<AwsBucket>, String> {
    let out = aws(&["s3api", "list-buckets", "--profile", profile, "--query", "Buckets[].Name", "--output", "json"])?;
    let names: Vec<String> = serde_json::from_str(&out).map_err(|e| format!("aws list-buckets: {e}"))?;
    Ok(names
        .into_iter()
        .map(|name| {
            let known = REGIONS.lock().unwrap_or_else(PoisonError::into_inner).as_ref().and_then(|m| m.get(&name).cloned());
            let region = known.unwrap_or_else(|| {
                let found = aws(&["s3api", "get-bucket-location", "--bucket", &name, "--profile", profile,
                                  "--query", "LocationConstraint", "--output", "text"])
                    .map(|r| region_from_location(r.trim()));
                let region = found.clone().unwrap_or_else(|_| "us-east-1".into());
                if found.is_ok() {
                    REGIONS.lock().unwrap_or_else(PoisonError::into_inner).get_or_insert_with(HashMap::new).insert(name.clone(), region.clone());
                }
                region
            });
            AwsBucket { name, region }
        })
        .collect())
}

/// `get-bucket-location` says "None" for us-east-1 and "EU" for the oldest eu-west-1 buckets.
fn region_from_location(loc: &str) -> String {
    match loc {
        "" | "None" | "null" => "us-east-1".into(),
        "EU" => "eu-west-1".into(),
        other => other.into(),
    }
}

fn parse_keys(json: &str) -> Result<Keys, String> {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "PascalCase")]
    struct Out {
        access_key_id: String,
        secret_access_key: String,
        session_token: Option<String>,
    }
    let o: Out = serde_json::from_str(json).map_err(|e| format!("aws export-credentials: {e}"))?;
    Ok(Keys { key: o.access_key_id, secret: o.secret_access_key, token: o.session_token.filter(|t| !t.is_empty()) })
}

#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct CfAccount {
    pub id: String,
    pub name: String,
    pub buckets: Vec<String>,
}

/// The account `cf` is logged in to and its R2 buckets.
/// shortcut: takes the first account; add a picker when someone has several.
pub fn cf_account() -> Result<CfAccount, String> {
    let accounts: serde_json::Value = serde_json::from_str(&run("cf", &["accounts", "list"])?).map_err(|e| format!("cf accounts: {e}"))?;
    let first = accounts.as_array().and_then(|a| a.first()).ok_or("cf is logged in to no account")?;
    let id = first["id"].as_str().unwrap_or_default().to_owned();
    let name = first["name"].as_str().unwrap_or_default().to_owned();
    let listed: serde_json::Value = serde_json::from_str(&run("cf", &["r2", "buckets", "list"])?).map_err(|e| format!("cf r2: {e}"))?;
    let buckets = listed["buckets"].as_array().into_iter().flatten().filter_map(|b| b["name"].as_str().map(str::to_owned)).collect();
    Ok(CfAccount { id, name, buckets })
}

/// Creates a read-only R2 API token through `cf`. R2's S3 key ID is the token ID and its secret is
/// the SHA-256 of the token value, which is hashed here and never kept.
pub fn cf_create_keys(account_id: &str) -> Result<Keys, String> {
    let policies = format!(
        r#"[{{"effect":"allow","permission_groups":[{{"id":"{R2_STORAGE_READ}"}}],"resources":{{"com.cloudflare.api.account.{account_id}":"*"}}}}]"#
    );
    let out = run("cf", &["user", "tokens", "create", "--name", "Rays (read-only R2)", "--policies", &policies])?;
    let v: serde_json::Value = serde_json::from_str(&out).map_err(|e| format!("cf tokens: {e}"))?;
    let v = v.get("result").unwrap_or(&v);
    let (Some(id), Some(value)) = (v["id"].as_str(), v["value"].as_str()) else {
        return Err("cf didn't return a token".into());
    };
    Ok(Keys { key: id.to_owned(), secret: r2_secret(value), token: None })
}

/// Cloudflare's "Workers R2 Storage Read" permission group: list buckets and read objects, account-wide.
const R2_STORAGE_READ: &str = "b4992e1108244f5d8bfbd5744320c2e1";

fn r2_secret(token: &str) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(token.as_bytes()).iter().map(|b| format!("{b:02x}")).collect()
}

fn aws(args: &[&str]) -> Result<String, String> {
    run("aws", args)
}

/// An app opened from Finder has a bare PATH, so the usual install places (and node, for `cf`) are added.
fn run(tool: &str, args: &[&str]) -> Result<String, String> {
    let home = std::env::var("HOME").unwrap_or_default();
    let path = format!("/opt/homebrew/bin:/usr/local/bin:{home}/.npm-global/bin:{home}/.local/bin:{}",
                       std::env::var("PATH").unwrap_or_else(|_| "/usr/bin:/bin".into()));
    let out = Command::new(tool).args(args).env("PATH", &path).output();
    // Command::new looks up the parent's PATH, not the one passed to the child, so try each place.
    let out = match out {
        Ok(o) => o,
        Err(_) => path
            .split(':')
            .map(|dir| std::path::Path::new(dir).join(tool))
            .find(|p| p.exists())
            .ok_or_else(|| format!("{tool} command not found"))
            .and_then(|bin| Command::new(bin).args(args).env("PATH", &path).output().map_err(|e| e.to_string()))?,
    };
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        return Err(err.trim().lines().last().unwrap_or("aws failed").to_owned());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_export_credentials_with_and_without_token() {
        let k = parse_keys(r#"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"S","SessionToken":"T","Expiration":"x"}"#).unwrap();
        assert_eq!(k, Keys { key: "AK".into(), secret: "S".into(), token: Some("T".into()) });
        let k = parse_keys(r#"{"Version":1,"AccessKeyId":"AK","SecretAccessKey":"S"}"#).unwrap();
        assert_eq!(k.token, None);
    }

    #[test]
    fn r2_secret_is_sha256_hex_of_the_token() {
        assert_eq!(r2_secret("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn maps_bucket_locations_to_regions() {
        assert_eq!(region_from_location("None"), "us-east-1");
        assert_eq!(region_from_location("EU"), "eu-west-1");
        assert_eq!(region_from_location("ap-south-1"), "ap-south-1");
    }
}

/// Reads the `cf` login, run by hand: `cargo test -p dl-engine --lib live_cf -- --ignored`.
#[cfg(test)]
#[test]
#[ignore = "needs a cf login"]
fn live_cf_account_lists_r2_buckets() {
    let acct = cf_account().unwrap();
    assert_eq!(acct.id.len(), 32, "{acct:?}");
    println!("{} buckets", acct.buckets.len());
}
