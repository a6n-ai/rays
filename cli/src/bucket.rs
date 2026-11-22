//! `dl bucket …` and `dl ls s3://…`: S3 buckets through the running app, which keeps secrets in the Keychain.
use crate::ask_rays;
use dl_engine::protocol::{Request, Response};
use std::io::{BufRead, IsTerminal, Write};
use std::process::{Command, ExitCode};

pub const USAGE: &str = "  dl bucket providers           cloud providers and their ids
  dl bucket add NAME --provider ID --key-id KEY [--region R] [--account-id A | --namespace N |
                --project-ref P] [--endpoint URL] [--path-style | --virtual-host] [--aws-profile NAME]
                                add a bucket; the secret key is read from stdin, or with
                                --aws-profile the AWS CLI login supplies the keys
  dl bucket list | dl bucket remove NAME
  dl ls s3://BUCKET/[PREFIX/]   list one level of a bucket";

pub fn run(args: &[String]) -> ExitCode {
    let req = match args {
        [cmd] if cmd == "providers" => Request::Providers,
        [cmd] if cmd == "list" => Request::Buckets,
        [cmd, name] if cmd == "remove" => Request::BucketRemove { name: name.clone() },
        [cmd, name, flags @ ..] if cmd == "add" => match add_request(name, flags) {
            Ok(req) => req,
            Err(e) => return fail(&e, 1),
        },
        _ => return fail(&format!("usage:\n{USAGE}"), 1),
    };
    send(&req)
}

pub fn ls(link: &str) -> ExitCode {
    let Some(rest) = link.strip_prefix("s3://") else {
        return fail("ls takes an s3://bucket/prefix link", 1);
    };
    let (bucket, prefix) = rest.split_once('/').unwrap_or((rest, ""));
    let mut token = None;
    loop {
        let req = Request::BucketList { bucket: bucket.into(), prefix: prefix.into(), token: token.take() };
        let reply = match reply(&req) {
            Ok(r) => r,
            Err(code) => return code,
        };
        let listing = reply.listing.unwrap_or_default();
        for f in &listing.folders {
            println!("{:>12}  {:<24}  s3://{bucket}/{f}", "DIR", "");
        }
        for o in &listing.objects {
            println!("{:>12}  {:<24}  s3://{bucket}/{}", o.size, o.modified, o.key);
        }
        match listing.next_token {
            Some(t) => token = Some(t),
            None => return ExitCode::SUCCESS,
        }
    }
}

fn add_request(name: &str, flags: &[String]) -> Result<Request, String> {
    let (mut provider, mut endpoint, mut region, mut field, mut key_id, mut path_style) =
        (String::new(), String::new(), String::new(), String::new(), String::new(), None);
    let mut profile = None;
    let mut it = flags.iter();
    while let Some(flag) = it.next() {
        let mut value = || it.next().cloned().ok_or_else(|| format!("{flag} needs a value"));
        match flag.as_str() {
            "--provider" => provider = value()?,
            "--endpoint" => endpoint = value()?,
            "--region" => region = value()?,
            "--account-id" | "--namespace" | "--project-ref" | "--field" => field = value()?,
            "--key-id" => key_id = value()?,
            "--aws-profile" => profile = Some(value()?),
            "--path-style" => path_style = Some(true),
            "--virtual-host" => path_style = Some(false),
            other => return Err(format!("unknown option {other}")),
        }
    }
    if provider.is_empty() {
        provider = if endpoint.is_empty() { return Err("--provider is required (see dl bucket providers)".into()) } else { "generic".into() };
    }
    if profile.is_some() {
        // Keys come from the AWS CLI each time; nothing secret is read or stored.
        return Ok(Request::BucketAdd { name: name.into(), provider, endpoint, region, field, access_key_id: key_id, secret: String::new(), path_style, profile });
    }
    if key_id.is_empty() {
        return Err("--key-id is required (or --aws-profile NAME)".into());
    }
    let secret = read_secret()?;
    Ok(Request::BucketAdd { name: name.into(), provider, endpoint, region, field, access_key_id: key_id, secret, path_style, profile })
}

/// From a pipe as is; from a terminal with echo off, so the key never shows on screen or in history.
fn read_secret() -> Result<String, String> {
    let stdin = std::io::stdin();
    let tty = stdin.is_terminal();
    if tty {
        eprint!("Secret access key: ");
        let _ = std::io::stderr().flush();
        let _ = Command::new("stty").arg("-echo").status();
    }
    let mut line = String::new();
    let read = stdin.lock().read_line(&mut line);
    if tty {
        let _ = Command::new("stty").arg("echo").status();
        eprintln!();
    }
    read.map_err(|e| e.to_string())?;
    let secret = line.trim_end_matches(['\r', '\n']).to_owned();
    if secret.is_empty() { Err("no secret key on stdin".into()) } else { Ok(secret) }
}

fn send(req: &Request) -> ExitCode {
    let reply = match reply(req) {
        Ok(r) => r,
        Err(code) => return code,
    };
    for p in &reply.providers {
        let field = p.field.as_deref().map(|f| format!(" --{}", f.replace('_', "-"))).unwrap_or_default();
        let endpoint = if p.endpoint.is_empty() { "--endpoint URL" } else { &p.endpoint };
        println!("{:<10} {:<24} {endpoint}{field}", p.id, p.name);
    }
    for b in &reply.buckets {
        println!("{}\t{}\t{}\t{}", b.name, b.provider, b.region, b.endpoint);
    }
    if matches!(req, Request::BucketAdd { .. } | Request::BucketRemove { .. }) {
        println!("ok");
    }
    ExitCode::SUCCESS
}

fn reply(req: &Request) -> Result<Response, ExitCode> {
    match ask_rays(req) {
        Ok(r) if r.ok => Ok(r),
        Ok(r) => Err(fail(&r.error.unwrap_or_default(), 1)),
        Err(e) => Err(fail(&e, 2)),
    }
}

fn fail(msg: &str, code: u8) -> ExitCode {
    eprintln!("dl: {msg}");
    ExitCode::from(code)
}
