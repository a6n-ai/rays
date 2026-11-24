# Hugging Face Models Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Search Hugging Face models by name in Rays, pick files (one GGUF version or one weights format), download them with the engine into a per-model folder, and give the sorter an AI Models category.

**Architecture:** All logic that needs tests lives in the Rust engine (`engine/src/hf.rs` plus job changes), exported to Swift through UniFFI like the cloud-bucket calls. The Swift app has no test target, so `ModelsView.swift` stays UI only and calls engine functions. The sorter gets a rule-based category in `sorter/src/main.rs`.

**Tech Stack:** Rust (tokio, reqwest 0.13, rusqlite, security-framework, sha2, UniFFI), SwiftUI (macOS 26), axum for engine test servers.

**Spec:** `docs/superpowers/specs/2026-11-24-huggingface-models-design.md`

## Global Constraints

- The Hugging Face token is sent only to the Hugging Face host (`huggingface.co`, configurable for tests). Never to the CDN it redirects to. Never written to SQLite or logs.
- Token storage: Keychain, service `ai.a6n.rays.hf`, account `token`, through the existing `Secrets` trait (`engine/src/s3.rs:103`).
- Downloads pin the commit SHA from model info: URL `https://huggingface.co/<repo>/resolve/<sha>/<path>`.
- Default destination `~/Downloads/AI Models/<org>/<model>/`, files keep their in-repo path.
- Same-name setting applies to all downloads; default **Keep both** (`name (1).ext`, today's behaviour).
- Existing callers of `Engine::add(urls:)` behave exactly as today.
- Sorter never renames model-weight files and never hashes them for duplicates.
- Hugging Face API (verified 2026-11-24):
  - Search: `GET /api/models?search=<q>&sort=downloads&direction=-1&limit=30&expand[]=gated&expand[]=downloads&expand[]=likes&expand[]=tags`. Each item has `id`, `gated` (`false` | `"auto"` | `"manual"`), `downloads`, `likes`, `tags`.
  - Model: `GET /api/models/<repo>?blobs=true`. Returns `sha`, `gated`, `downloads`, `likes`, `tags`, and `siblings[] {rfilename, size, lfs?: {sha256, size}}`.
  - `resolve` answers 302 to a CDN host (e.g. `us.aws.cdn.hf.co`) for LFS/Xet files, and 307 on the same host for small files. A gated file without a token returns 401.
- Commands: engine unit `cargo test -q -p dl-engine --lib`; engine integration `cargo test -p dl-engine --test download` / `--test engine`; sorter `cargo test -p sorter`; lint `cargo clippy -p dl-engine --all-targets -- -D warnings`; bindings `scripts/build-engine.sh`; app `swift build --package-path macos`.

## Review Focus

- **Quant parsing:** a repo with both a merged file and a split set for the same quant (`…-q4_k_m.gguf` and `…-q4_k_m-00001-of-00002.gguf`, as in `Qwen/Qwen2.5-Coder-7B-Instruct-GGUF`) must give one `Q4_K_M` version that uses the merged file. Test in Task 3.
- **Token on redirect:** a resumed download, or an extra connection after a 302 to another host, must not carry `Authorization`. Test in Task 4.
- **Gated without a token:** a 401 from `resolve` must fail the job with a message that says to add a token, not a raw `HTTP 401`. Test in Task 4.
- **Nested repo paths** (`onnx/model.onnx`, `original/params.json`): parent folders are created under the destination, and `..` or absolute paths from the API are rejected. Test in Task 1 (dir) and Task 5 (path join).
- **Restart mid-download:** a job with a custom dir, fixed name and expected SHA-256 must survive an engine restart and finish in the same place, verified. Test in Task 1 (store round-trip) and Task 5.

---

### Task 1: Per-job destination folder and fixed file name

**Files:**
- Modify: `engine/src/types.rs` (`Job`: add `dir: Option<PathBuf>`, `fixed_name: bool`, `sha256: Option<String>`)
- Modify: `engine/src/store.rs` (append migrations; `COLUMNS`; load/save/insert)
- Modify: `engine/src/scheduler.rs` (`add_to`, `insert_job`, pass job dir to `download::run`)
- Modify: `engine/src/download.rs` (skip `Content-Disposition` rename when `fixed_name`; `finish` uses the job's dir)
- Modify: `engine/src/api.rs` (export `add_to`)
- Test: `engine/src/store.rs` tests, `engine/tests/download.rs`

**Interfaces:**
- Produces: `Scheduler::add_to(self: &Arc<Self>, urls: Vec<String>, dir: Option<PathBuf>, fixed_names: Vec<Option<String>>) -> Vec<AddResult>`. `fixed_names[i] = Some(name)` sets `job.name = name` and `job.fixed_name = true`. Uniffi: `Engine::add_to(urls: Vec<String>, dir: Option<String>, names: Vec<Option<String>>) -> Vec<AddResult>`.
- Produces: `Job.sha256: Option<String>` (stored only; Task 5 sets and checks it).
- `Scheduler::add(urls)` becomes `add_to(urls, None, vec![None; n])`.

- [ ] **Step 1: Write failing tests**
  - `store.rs`: `job_dir_name_and_hash_round_trip`: insert a job with `dir: Some("/x/AI Models/a/b")`, `fixed_name: true`, `sha256: Some("ab12…")`, reopen the store, `load_all()` returns them equal. Also assert `user_version == MIGRATIONS.len()`.
  - `tests/download.rs`: `add_to_saves_in_given_dir_with_fixed_name`: the server sends `Content-Disposition: attachment; filename="other.bin"`. `add_to([url], Some(tmp/"m/sub"), [Some("weights.gguf")])` ends `Done` at `tmp/m/sub/weights.gguf`. The folder `m/sub` didn't exist before and gets created.
  - `tests/download.rs`: `add_keeps_disposition_name_in_default_dir`: the existing behaviour is unchanged.
- [ ] **Step 2:** `cargo test -q -p dl-engine --lib job_dir` and `cargo test -p dl-engine --test download add_` both fail to compile or fail.
- [ ] **Step 3: Implement**
  - Migrations, appended: `"ALTER TABLE jobs ADD COLUMN dir TEXT"`, `"ALTER TABLE jobs ADD COLUMN fixed_name INTEGER NOT NULL DEFAULT 0"`, `"ALTER TABLE jobs ADD COLUMN sha256 TEXT"`.
  - `download::run` takes the job's dir: `job.dir.unwrap_or(downloads_dir)`. Call `create_dir_all` before the `.part` is created.
  - `part_path` lives in that same dir, so the final hard link stays on one volume.
- [ ] **Step 4:** both commands pass; `cargo clippy -p dl-engine --all-targets -- -D warnings` is clean.
- [ ] **Step 5: Commit** `Engine: per-job destination folder and fixed file name`

### Task 2: Same-name setting (keep both or replace)

**Files:**
- Modify: `engine/Cargo.toml` (add `trash = "5"` under `full`)
- Modify: `engine/src/scheduler.rs` (`replace_existing: AtomicBool`, setter)
- Modify: `engine/src/download.rs` (`finish`)
- Modify: `engine/src/api.rs` (`set_replace_existing(on: bool)`)
- Test: `engine/tests/download.rs`

**Interfaces:**
- Produces: `Engine::set_replace_existing(&self, on: bool)`; default `false`.
- `download::Env` gets `replace_existing: bool`, read when the job starts.

- [ ] **Step 1: Failing tests**
  - `replace_off_keeps_both`: put `a.bin` with content `old` in the dir, then download `a.bin`. Afterwards `a.bin` still reads `old`, and `a (1).bin` holds the new data.
  - `replace_on_moves_old_to_trash`: with `set_replace_existing(true)`, `a.bin` holds the new data, and the old file is gone from the dir. The test uses an injected trash function that records the path, so CI doesn't touch the real Trash. Give `Env` an `trash: fn(&Path) -> io::Result<()>` that defaults to `trash::delete`.
- [ ] **Step 2:** `cargo test -p dl-engine --test download replace_` fails.
- [ ] **Step 3: Implement in `finish`.** When `replace_existing` is on and `dir/name` exists, trash it, then hard-link the `.part` to `dir/name`. If the trash call fails, fall back to `unique_final`; never delete without the Trash. This happens at finish, not at start, so the old file survives a failed download. (This deliberately deviates from the spec's "when the download starts"; it's safer.)
- [ ] **Step 4:** the tests pass, and clippy is clean.
- [ ] **Step 5: Commit** `Engine: setting to replace same-name files (old one to Trash)`

### Task 3: Hugging Face file logic (pure functions)

**Files:**
- Create: `engine/src/hf.rs` (`#[cfg(feature = "full")]` module, declared in `lib.rs`)
- Test: unit tests in `engine/src/hf.rs`

**Interfaces (all `#[derive(uniffi::Record)]` / `#[uniffi::export]`):**
- `pub struct HfFile { pub path: String, pub size: u64, pub sha256: Option<String> }`
- `pub struct HfVersion { pub label: String, pub files: Vec<String>, pub size: u64, pub recommended: bool }` (`size` includes the attached mmproj)
- `pub fn hf_repo_from_input(input: String) -> Option<String>`: returns `org/repo` for `org/repo`, for `https://huggingface.co/org/repo[/tree|blob|resolve/…]`, and for `hf.co/org/repo`. Returns `None` for free text with spaces or a single word.
- `pub fn hf_versions(files: Vec<HfFile>) -> Vec<HfVersion>`: empty when the repo has no `.gguf`.
- `pub fn hf_recommended(files: Vec<HfFile>) -> Vec<String>`: the paths to tick by default.

- [ ] **Step 1: Failing tests**
  - `input_parsing`: `"Qwen/Qwen3-8B"`, `"https://huggingface.co/Qwen/Qwen3-8B/tree/main"` and `"hf.co/Qwen/Qwen3-8B"` all give `Some("Qwen/Qwen3-8B")`. `"qwen 8b"` and `"qwen"` give `None`.
  - `quant_labels`: `x-Q4_K_M.gguf` → `Q4_K_M`; `x-q4_k_m-00001-of-00002.gguf` → `Q4_K_M`; `x-IQ4_XS.gguf` → `IQ4_XS`; `x-Q8_0.gguf` → `Q8_0`; `x-f16.gguf` → `F16`; `x-BF16.gguf` → `BF16`. Labels are uppercase.
  - `split_set_is_one_version`: two `-0000N-of-00002` parts with the same quant give one version, with both files and the summed size.
  - `merged_beats_split`: the file list of `Qwen/Qwen2.5-Coder-7B-Instruct-GGUF` (q4_k_m merged plus 2 split parts) gives `Q4_K_M.files == ["…-q4_k_m.gguf"]`.
  - `mmproj_attached`: `mmproj-x-F16.gguf` (888 MB) and `mmproj-x-Q8_0.gguf` (500 MB) are not versions themselves. The smallest one is in every version's `files`, and its size is counted.
  - `recommended_q4_k_m`: when present, it is the only `recommended == true`. Without it, the first present version from the order `Q4_K_M, Q4_K_S, Q5_K_M, Q4_0, Q5_K_S, Q5_0, Q6_K, Q8_0, IQ4_XS` wins; if none match, the smallest version wins.
  - `recommended_gguf_paths`: `hf_recommended` on a GGUF repo equals the recommended version's `files`. `README.md` and `.gitattributes` are not in it.
  - `recommended_safetensors`: files `config.json, generation_config.json, tokenizer.json, tokenizer_config.json, tokenizer.model, merges.txt, model-00001-of-00002.safetensors, model-00002-of-00002.safetensors, model.safetensors.index.json, pytorch_model.bin, onnx/model.onnx, original/consolidated.00.pth, README.md, LICENSE, .gitattributes`. The result is exactly the first 9: the config, tokenizer and merges files, both safetensors shards, and `model.safetensors.index.json`. `pytorch_model.bin`, `onnx/`, `original/`, the docs and `.gitattributes` are left out.
  - `recommended_bin_when_no_safetensors`: without `.safetensors`, the result includes `pytorch_model.bin` and the configs.
- [ ] **Step 2:** `cargo test -q -p dl-engine --lib hf::` fails.
- [ ] **Step 3: Implement.** Find the quant label without a regex dependency: strip `.gguf` and any `-NNNNN-of-NNNNN`, split on `-` and `.`, then take the last token matching `^(I?Q\d(_[A-Z0-9]+)*|F16|BF16|F32|FP16)$`, case-insensitive. Normalize `FP16` to `F16`. Weights extensions: `safetensors, bin, pt, pth, ckpt, onnx, msgpack, h5`. Subfolders `onnx/`, `coreml/`, `openvino/` and `original/` are skipped unless they hold the only weights. Docs left out: `*.md`, `LICENSE*`, `.gitattributes`, images.
- [ ] **Step 4:** the tests pass, and clippy is clean.
- [ ] **Step 5: Commit** `Engine: Hugging Face version grouping and recommended files`

### Task 4: Hugging Face API client and token

**Files:**
- Modify: `engine/src/hf.rs` (HTTP calls)
- Modify: `engine/src/scheduler.rs` (`hf_base: String`, default `https://huggingface.co`; token via `secrets`; header on requests)
- Modify: `engine/src/download.rs` (the two `client.get(...)` sites at lines 213 and 1037 go through one `env.get(url)` helper that adds `Authorization` when the URL's host equals the HF host)
- Modify: `engine/src/types.rs` (`EngineConfig.hf_base: Option<String>` with `#[uniffi(default = None)]`, so the Swift call site keeps compiling until Task 6 regenerates the bindings; a test-only override, where `None` means the default)
- Modify: `engine/src/api.rs`
- Test: `engine/tests/download.rs` (or a new `engine/tests/hf.rs`)

**Interfaces:**
- `pub struct HfModel { pub id: String, pub downloads: u64, pub likes: u64, pub gated: bool, pub gguf: bool }` (`gated` is true for `"auto"` or `"manual"`; `gguf` means the tags contain `gguf`)
- `pub struct HfRepo { pub id: String, pub sha: String, pub gated: bool, pub downloads: u64, pub likes: u64, pub files: Vec<HfFile> }`
- `Engine::hf_search(query: String) -> Result<Vec<HfModel>, EngineError>` (async, on `self.rt` like `list_bucket`)
- `Engine::hf_model(repo: String) -> Result<HfRepo, EngineError>` (async)
- `Engine::set_hf_token(token: Option<String>) -> Result<(), EngineError>` (`None` deletes it); `Engine::has_hf_token() -> bool`
- Both API calls send the token when one is saved, so private and gated repos list.

- [ ] **Step 1: Failing tests** (axum: an "hf" server on `127.0.0.1:A` and a "cdn" server on `localhost:B`, so the hosts differ)
  - `search_parses_fields`: the hf server returns the search JSON shape from Global Constraints, and `hf_search("qwen")` maps it, including `gated: "manual"` to `true`.
  - `model_parses_siblings`: a `blobs=true` reply maps `lfs.sha256` to `HfFile.sha256` and leaves it `None` without `lfs`.
  - `token_only_to_hf_host`: with a token set, `GET /org/m/resolve/<sha>/w.gguf` on the hf server records an `Authorization: Bearer t` header, then 302s to the cdn server. The cdn server records that no `Authorization` arrived, including on a second ranged request after a pause and resume.
  - `gated_401_message`: the hf server answers 401. The job fails with `"This model is gated: add your Hugging Face token in Settings"`. A 403 fails with `"Accept this model's license on huggingface.co"`.
  - `no_token_no_header`: no token saved means no `Authorization` header.
- [ ] **Step 2:** the tests fail.
- [ ] **Step 3: Implement.** Map statuses in the place that maps `HTTP {status}` failures (`download.rs` ~245), only for jobs whose URL is on the HF host. The token comes from `secrets.get("hf-token")`, using the dedicated Keychain service from Global Constraints. Add `Keychain::with_service` if the trait only knows the s3 service.
- [ ] **Step 4:** the tests pass, and clippy is clean.
- [ ] **Step 5: Commit** `Engine: Hugging Face search, model info and token (sent only to huggingface.co)`

### Task 5: Add a model's files, verify SHA-256, skip ones already there

**Files:**
- Modify: `engine/src/hf.rs`, `engine/src/scheduler.rs`, `engine/src/download.rs` (`finish`), `engine/src/api.rs`
- Test: `engine/tests/hf.rs`

**Interfaces:**
- Consumes: `Scheduler::add_to` (Task 1), `HfFile` (Task 3), the HF host and token (Task 4).
- Produces: `pub struct HfAdd { pub path: String, pub status: HfAddStatus }`, `pub enum HfAddStatus { Added { id: JobId }, AlreadyThere, Rejected { error: String } }`
- `Engine::add_hf(repo: String, sha: String, files: Vec<HfFile>, dest_dir: String) -> Vec<HfAdd>`
- `pub fn hf_target(dest_dir: &Path, path: &str) -> Option<(PathBuf, String)>`: the parent dir and file name. Returns `None` for an absolute path, any `..` part, or an empty name.

- [ ] **Step 1: Failing tests**
  - `adds_into_repo_paths`: files `w.gguf` and `onnx/m.onnx` with dest `tmp/AI Models/org/m` end as `tmp/AI Models/org/m/w.gguf` and `…/onnx/m.onnx`. Each URL is `<hf>/org/m/resolve/<sha>/<path>`, with the path percent-encoded per segment.
  - `rejects_unsafe_paths`: `../x`, `/etc/x` and `a/../../x` come back `Rejected`, and nothing gets added.
  - `already_there_by_size`: a file at the target with the API size is `AlreadyThere`, and no job is created. A file there with a different size goes through `add_to`, so the same-name setting from Task 2 decides what happens.
  - `sha_checked_on_finish`: with `sha256: Some(correct)`, the job ends `Done`. With a wrong hash, it fails with `"Checksum didn't match"`, no final file exists, the `.part` is deleted and the segments are reset, so Resume downloads it fresh.
  - `restart_keeps_dir_name_hash`: pause mid-download, drop the engine, start a new one on the same data dir and resume. The job finishes at the same path and is verified.
- [ ] **Step 2:** the tests fail.
- [ ] **Step 3: Implement.** `add_hf` sets `job.sha256` from `HfFile.sha256`. `finish` hashes the `.part` on the blocking pool (`sha2`, already a dependency) before linking, but only when `job.sha256` is `Some`. Hashing only happens when a hash is published (the design's "hash when published"). The already-there check compares size only: hashing a 40 GB file before every add is too slow, and the finish-time hash covers new downloads. (This is a deliberate narrowing of the spec.)
- [ ] **Step 4:** the tests pass, and clippy is clean.
- [ ] **Step 5: Commit** `Engine: add Hugging Face files into a model folder, verify SHA-256, skip files already there`

### Task 6: App wiring: bindings, engine calls, Settings

**Files:**
- Run: `scripts/build-engine.sh` (regenerates `macos/Sources/Rays/Generated/dl_engine.swift`)
- Modify: `macos/Sources/Rays/EngineModel.swift`. Add `SettingsKey.replaceExisting = "replaceExisting"`. Apply it at startup next to the other settings. Add wrappers `hfSearch(_:) async throws -> [HfModel]`, `hfModel(_:) async throws -> HfRepo`, `addModel(repo:sha:files:to:) -> [HfAdd]`, `setHFToken(_:) throws`, `hasHFToken: Bool`, `setReplaceExisting(_:)`.
- Modify: `macos/Sources/Rays/SettingsView.swift` (`DownloadsTab`). Add a picker **If a file with the same name exists**: `Keep both` / `Replace (old file goes to the Trash)`. Add a **Hugging Face** section with a `SecureField` "Access token", Save and Remove buttons, and the footer "Needed for gated and private models. Sent only to huggingface.co. Stored in Keychain."

- [ ] **Step 1:** `scripts/build-engine.sh` succeeds, and the generated Swift contains `hfSearch`, `addHf` and `setReplaceExisting`.
- [ ] **Step 2:** implement the wrappers and Settings rows, following `CloudSettings.swift` for the secret field.
- [ ] **Step 3:** `swift build --package-path macos` prints `Build complete!`.
- [ ] **Step 4: Manual check.** Run `scripts/bundle-app.sh`, open `bin/Rays.app`, set a token, quit and reopen. The token row shows "Saved", and the picker value persists.
- [ ] **Step 5: Commit** `App: Hugging Face token and same-name setting`

### Task 7: Models section UI

**Files:**
- Create: `macos/Sources/Rays/ModelsView.swift`
- Create: `macos/Sources/Rays/AIModelsFolder.swift` (`enum AIModelsFolder { static func base(downloadsDir: URL, destinations: [String: [String: String]]) -> URL; static var lmStudioModels: URL? }`)
- Modify: `macos/Sources/Rays/ContentView.swift`. Add `DownloadsSection.models`, a toolbar icon `cube` with the title "Hugging Face models", and the `pageView` case.

**Interfaces:**
- Consumes: the Task 6 wrappers; `SorterModel` destinations (`[folderPath: [category: dest]]`, loaded in `SorterModel.swift:164`).
- `AIModelsFolder.base`: `destinations[downloadsDir.path]["AI Models"]` if it's an absolute path, else `downloadsDir/AI Models`. `lmStudioModels`: `~/.lmstudio/models` if `~/.lmstudio` exists, else `nil`.

- [ ] **Step 1: Build the view to the spec's sketch:**
  - Search field with a 300 ms debounce. If `hf_repo_from_input` returns a repo, open it directly; otherwise show the results list (repo id, downloads, likes, a lock when gated without a saved token).
  - Opened model:
    - Header: id, a `GGUF` tag, downloads, an **Open on Hugging Face** link, the selected total, and free space (`volumeAvailableCapacityForImportantUsage`).
    - Version chips from `hf_versions`, with ★ on the recommended one.
    - File list with checkboxes and sizes, **Recommended / Select all / None**, and "N of M selected".
    - **Save to**: the path, **Choose…** (NSOpenPanel for directories), and **Save into LM Studio's models folder** when `lmStudioModels != nil`.
    - Rows with an existing same-name file show "Replaces the file there" or "Saves as name (1)", per the setting. With Keep both, they add "Some apps need exact file names".
  - **Download** is disabled when nothing is selected or the total exceeds free space ("Not enough space: needs X, Y free"). On click it calls `addModel` and switches the section to Recent. `AlreadyThere` rows show "Already downloaded"; `Rejected` rows show their error.
  - Gated model without a token: the panel shows "This model is gated. Add your Hugging Face token in Settings" and a button that opens Settings.
- [ ] **Step 2:** `swift build --package-path macos` prints `Build complete!`.
- [ ] **Step 3: Manual check** with `bin/Rays.app`:
  - Search `qwen2.5 coder 7b gguf`, open `Qwen/Qwen2.5-Coder-7B-Instruct-GGUF`. `Q4_K_M ★` is selected.
  - Download the smallest version (`Q2_K`). The file lands in `~/Downloads/AI Models/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/` and appears in Recent.
  - Paste `https://huggingface.co/meta-llama/Llama-3.1-8B-Instruct` without a token. The gated notice shows.
- [ ] **Step 4: Commit** `App: Hugging Face models section in Downloads`

### Task 8: Sorter AI Models category

**Files:**
- Modify: `sorter/src/main.rs` (`CATEGORIES`, `MODEL_EXT`, `rule()`, the planning `match` near line 657)
- Test: `sorter/src/main.rs` tests module

**Interfaces:**
- `const MODEL_EXT: &[(&str, &str)] = &[("gguf","GGUF"),("safetensors","Safetensors"),("onnx","ONNX"),("mlmodel","Core ML"),("tflite","TFLite"),("ckpt","PyTorch"),("pt","PyTorch"),("pth","PyTorch")];`
- `CATEGORIES` gains `("AI Models", "machine-learning model weights and checkpoints")`, placed before `"Other"`.

- [ ] **Step 1: Failing tests**
  - `rule_sends_model_files_to_ai_models`: each extension above maps to `("AI Models", <subfolder>)`, case-insensitive (`X.GGUF`). `weights.bin` gives `None`.
  - `model_files_skip_duplicate_check_and_keep_name`: run the planner in dry-run on a temp folder holding `a.gguf` plus an identical copy already sorted. The log line is `a.gguf -> …/AI Models/GGUF/a.gguf (AI Models/GGUF rule)`, not `duplicate of`, and the file name is unchanged. Use the existing dry-run test pattern; if none exists, extract the planning `match` into `fn plan(...)` so it can be tested.
- [ ] **Step 2:** `cargo test -p sorter` fails.
- [ ] **Step 3: Implement.** Check `MODEL_EXT` before `index.find_duplicate`, and use `orig_stem` with no `fm` rename and no `tidy_name`. Folders stay untouched, as today.
- [ ] **Step 4:** `cargo test -p sorter` passes, and the app's **Where files go** list shows AI Models (it reads categories from `status --json`).
- [ ] **Step 5: Commit** `Sorter: AI Models category for model weights, no hashing or renaming`

### Task 9: Docs

**Files:**
- Create: `site/src/content/docs/docs/app/models.md`. Cover search (name, `org/repo` or link), versions and Recommended, Save to and the LM Studio shortcut, the token, the checksum check, skipped files, and the same-name setting.
- Modify: `site/src/content/docs/docs/features.md` (one bullet), `site/src/content/docs/docs/app/sorter.md` (the AI Models category), `site/src/content/docs/docs/app/downloads.md` (the same-name setting), and the docs sidebar config if pages are listed by hand (grep `app/sorter` under `site/`).

- [ ] **Step 1:** write the pages in the existing docs voice: short sentences, bold UI names.
- [ ] **Step 2:** `cd site && npm run build` succeeds.
- [ ] **Step 3: Commit** `Docs: Hugging Face models and AI Models sorter category`
