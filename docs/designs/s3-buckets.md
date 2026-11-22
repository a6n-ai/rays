# S3 buckets

Add S3-compatible buckets (AWS S3, Cloudflare R2, Backblaze B2, Wasabi, MinIO) to Rays. Browse a bucket and download objects with the same engine as HTTP downloads: split parts, resume and the adaptive connection count all apply. Available in the app, the `dl` command and MCP.

## Decisions

- **One entry per bucket.** A bucket has a name, an endpoint, a region, an access key ID, and path-style or virtual-host addressing. Bucket names are unique in Rays, so a link is just `s3://bucket/key`.
- **Secrets in the Keychain only.** The secret access key goes to the macOS Keychain (service `ai.a6n.rays.s3`, account = bucket name), never to SQLite, logs or events. The engine runs inside the app, and `dl` and MCP reach it over the socket, so only the signed app reads the Keychain: no access prompt for each command. Tests use an in-memory secret store.
- **Sign each request.** A job keeps its `s3://` link. Each GET (the probe and every part) is signed when it is sent, as a pre-signed URL valid for 1 hour (`rusty-s3`, already rustcrypto-based). S3 checks the signature only when a request starts, so a long part keeps streaming, and a resume never hits an expired link. `Range` is not signed, so splitting works unchanged.
- **Listing.** `ListObjectsV2` with `delimiter=/` returns folders and objects (key, size, modified) for one level of a prefix, paged by continuation token.
- **No adding buckets from MCP.** An AI client can list buckets, browse and download, but credentials never pass through it. `dl bucket add` reads the secret from standard input, so it stays out of shell history and `ps`.

## Cloud providers

Settings > Cloud has a provider picker. A preset fills in the endpoint, region and addressing, so the user types only what differs (account ID, region, keys). **Generic S3** takes any endpoint. Presets live in the engine, so `dl bucket add --provider r2 --account-id …` uses the same table.

| Provider | Endpoint template | Region | Addressing |
|---|---|---|---|
| Amazon S3 | `https://s3.{region}.amazonaws.com` | required | virtual host |
| Cloudflare R2 | `https://{account_id}.r2.cloudflarestorage.com` | `auto` | path |
| Backblaze B2 | `https://s3.{region}.backblazeb2.com` | e.g. `us-west-004` | virtual host |
| Wasabi | `https://s3.{region}.wasabisys.com` | required | virtual host |
| DigitalOcean Spaces | `https://{region}.digitaloceanspaces.com` | e.g. `nyc3` | virtual host |
| Google Cloud Storage (HMAC keys) | `https://storage.googleapis.com` | `auto` | path |
| Hetzner Object Storage | `https://{region}.your-objectstorage.com` | `fsn1`, `nbg1`, `hel1` | virtual host |
| Akamai / Linode | `https://{region}.linodeobjects.com` | required | virtual host |
| Scaleway | `https://s3.{region}.scw.cloud` | e.g. `fr-par` | virtual host |
| OVHcloud | `https://s3.{region}.io.cloud.ovh.net` | required | virtual host |
| Oracle Cloud | `https://{namespace}.compat.objectstorage.{region}.oraclecloud.com` | required | path |
| Alibaba Cloud OSS | `https://oss-{region}.aliyuncs.com` | required | virtual host |
| Supabase Storage | `https://{project_ref}.supabase.co/storage/v1/s3` | project region | path |
| Tigris | `https://fly.storage.tigris.dev` | `auto` | virtual host |
| MinIO / self-hosted | user's URL | `us-east-1` | path |
| Generic S3 | user's URL | user's | user's choice |

Each template is checked against the provider's current docs before it ships; a preset only pre-fills the form, and every field stays editable.

**Not S3:** Azure Blob Storage uses its own REST API and Shared Key or SAS auth. Azure SAS links already work today as plain HTTPS downloads; browsing Azure containers is a separate later backend.

## Surface

| Where | Added |
|---|---|
| Engine API (uniffi) | `add_bucket(config, secret)`, `remove_bucket(name)`, `buckets()`, `list_bucket(name, prefix, token)`; `add()` accepts `s3://` links |
| Socket protocol | `Buckets`, `BucketAdd`, `BucketRemove`, `BucketList { bucket, prefix }` |
| `dl` | `dl bucket add <name> --endpoint <url> [--region r] [--key-id id] [--path-style]` (secret on stdin), `dl bucket remove <name>`, `dl bucket list`, `dl ls s3://bucket/prefix/`, `dl s3://bucket/key` |
| MCP | `list_buckets`, `browse_bucket { bucket, prefix }`; `add_downloads` takes `s3://` links |
| App | Settings > Cloud: provider picker (presets + Generic S3), add, remove, test; a Buckets sidebar section that browses folders and downloads objects |
| Site | Docs page "S3 buckets"; `dl` and MCP pages updated |

## Phases

1. **Engine:** store migration (`buckets` table), Keychain secret store, signer, `s3://` jobs in `check_url`/`run`, listing, API. Tests: unit (link parsing, signing), integration against a local fake S3 server that checks the signature and serves `Range`; a manual run against MinIO in Docker.
2. **`dl` and MCP:** protocol requests, CLI commands, MCP tools, tests.
3. **App:** Settings tab and browser view.
4. **Docs and site.**

## Later

- Download a whole prefix (`dl s3://bucket/folder/`).
- Uploads (multipart), sync.
- Temporary credentials (session tokens, SSO).
