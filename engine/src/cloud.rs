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
            let region = aws(&["s3api", "get-bucket-location", "--bucket", &name, "--profile", profile,
                               "--query", "LocationConstraint", "--output", "text"])
                .map(|r| region_from_location(r.trim()))
                .unwrap_or_else(|_| "us-east-1".into());
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

/// An app opened from Finder has a bare PATH, so the usual install places are tried first.
fn aws(args: &[&str]) -> Result<String, String> {
    let bin = ["/opt/homebrew/bin/aws", "/usr/local/bin/aws", "/usr/bin/aws"]
        .into_iter()
        .find(|p| std::path::Path::new(p).exists())
        .unwrap_or("aws");
    let out = Command::new(bin).args(args).output().map_err(|e| format!("AWS CLI not found: {e}"))?;
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
    fn maps_bucket_locations_to_regions() {
        assert_eq!(region_from_location("None"), "us-east-1");
        assert_eq!(region_from_location("EU"), "eu-west-1");
        assert_eq!(region_from_location("ap-south-1"), "ap-south-1");
    }
}
