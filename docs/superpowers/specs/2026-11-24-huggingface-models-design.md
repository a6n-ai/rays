# Hugging Face model search and download

Status: approved (2026-11-24)

## Intent

People doing AI development fetch models from Hugging Face with `hf download`, a browser, or `git lfs`. Rays already downloads big files faster than those. This feature lets them find a model by name inside Rays and download it with Rays' engine. Downloaded models land in one predictable folder, and the sorter keeps loose model files there too, so models are easy to find later.

## Goals

- Search Hugging Face models by name from the Downloads window.
- Open a model, see its files with sizes, tick the ones to download.
- Download them as normal Rays jobs (progress, pause, resume, speed limit, Downloads list).
- Keep a model's files together in `<AI Models>/<org>/<model>/`, preserving subfolders inside the repo.
- Gated models (Llama, Gemma, …) work once the user adds a Hugging Face token.
- The sorter gets an **AI Models** category: loose model-weight files dropped in a watched folder go there.

## Non-goals

- Datasets and Spaces. Models only.
- Hugging Face's cache layout (`~/.cache/huggingface/hub/models--…`, blobs + symlinks). Approach C, not picked.
- Running, converting or quantizing models. Rays downloads; other tools run them.
- Uploading, logging in with OAuth, browsing model cards beyond a one-line summary.
- Moving whole model folders with the sorter. Folders in watched folders stay untouched, as today.
- From the reference, left out for now: **Download later** (Rays has no scheduled downloads to hook into) and **mirror endpoints** like hf-mirror.com. Both can come later.

## Anti-goals

- Downloading a whole repo by default when it holds many quantizations: a 7B GGUF repo can be 100+ GB across a dozen variants.
- Sending the user's token anywhere except `huggingface.co`.
- The sorter splitting a model's files apart, or spending minutes hashing a 40 GB file.

## Constraints (from the code today)

- `Engine.add(urls:)` (`engine/src/api.rs:50`, `scheduler.rs:159`) takes URLs only; every job lands in the one downloads dir. Per-model folders need a destination per job.
- Jobs carry an optional `SignUrl` (`download.rs:145`, a sync `Fn() -> String`) used by `s3://` to presign every request. Hugging Face resolve links redirect (302) to short-lived signed CDN links, so a resumed or long download must re-resolve rather than reuse a stale CDN link.
- Secrets already live in Keychain via the engine store (`store.rs`) and `CloudSettings.swift` for bucket keys.
- The sorter checks duplicates by size, then SHA-256 (`sorter/src/main.rs:172`), before `rule()` applies. `rule()` (`main.rs:112`) maps extensions to fixed `(category, subfolder)`. Custom destinations per category come from `sorter.json` (`config.rs`, `Layout::cat_dir`).
- Downloads window sections: `enum DownloadsSection { recent, files, settings }` (`ContentView.swift:119`), shown as toolbar icons.

## Approaches

- **A. Search panel in Downloads (picked).** Search by name, open a model, tick files, download into a per-model folder. Lets people pick one quantization instead of the whole repo. Costs one new screen.
- **B. `hf:` prefix in the paste-links box.** `hf:org/name` downloads the whole repo. Almost no UI, but needs the exact name and always downloads everything.
- **C. A, saved in Hugging Face's cache layout.** Python `transformers` would find models without a path, but needs the blob/symlink/refs layout, and nobody asked for Python use.

Picked A: the user wants to search by name and download, and picking files matters because of multi-quantization repos.

## Design

### Where it lives

A fourth Downloads section, **Models**, as a toolbar icon next to Recent, Files and Settings (symbol: `cube` or similar, builder's call). The user shared a reference dialog from another download manager; the layout follows its structure, in Rays' own look:

```
[ 🔍 qwen3 27b gguf   (name, org/repo, or a huggingface.co link) ]
┌────────────────────────────────────────────────────────────┐
│ lmstudio-community/Qwen3-27B-GGUF              16.5 GB     │
│ GGUF  ↓ 1.1M  Open on Hugging Face          412 GB free    │
└────────────────────────────────────────────────────────────┘
Version   [Q4_K_M ★ 15.7 GB] [Q6_K 20.9 GB] [Q8_0 27.1 GB]
Files  2 of 6 selected           Recommended · Select all · None
  ☐ .gitattributes                                  1.7 KB
  ☑ mmproj-Qwen3-27B-BF16.gguf                       888 MB
  ☑ Qwen3-27B-Q4_K_M.gguf                           15.7 GB
  ☐ Qwen3-27B-Q6_K.gguf                             20.9 GB
  ☐ Qwen3-27B-Q8_0.gguf                             27.1 GB
  ☐ README.md                                        2.1 KB
Save to  [~/Downloads/AI Models/lmstudio-community/Qwen3-27B-GGUF] [Choose…]
         Save into LM Studio's models folder
                                         [Cancel] [Download 16.5 GB]
```

- The search field takes a name (results list below it), an exact `org/repo`, or a pasted `huggingface.co/...` link (opens that model directly).
- Header: repo id, format tag, downloads, a link to the model page, total selected size, free space on the destination volume.

### Search and file list

- Search: Hugging Face's public models API, by name, sorted by downloads, ~30 results; debounce typing. Each result: repo id, downloads, likes, a lock when gated.
- Opening a model fetches its file list with sizes and the current commit SHA. Downloads use that commit, so all files come from one revision.
- **Version chips (GGUF repos):** files are grouped by quantization (`Q4_K_M`, `Q6_K`, `Q8_0`, …, parsed from the file name, including split files like `-00001-of-00003`). Picking a chip ticks that version's files. Default and ★ Recommended: `Q4_K_M` if present, else the closest smaller-or-equal quant the builder picks by a simple order. A vision projector (`mmproj-*.gguf`) is ticked along with the chosen version.
- **Recommended (non-GGUF repos):** weights in one format (prefer `.safetensors`; skip duplicate `.bin`/`.pt` copies and `onnx/`, `coreml/` subfolders unless they are the only weights) plus configs, tokenizer and generation files beside them. Docs and `.gitattributes` start unticked.
- **Recommended / Select all / None** buttons over the list; a "N of M selected" count. The Download button shows the total size.
- Before starting, check free space on the destination volume; refuse with a clear message if the total doesn't fit.

### Downloading

- Each ticked file becomes one engine job for `https://huggingface.co/<repo>/resolve/<sha>/<path>`.
- Destination: **Save to** defaults to `<AI Models>/<org>/<model>/`, files keep their path inside the repo. `<AI Models>` is the sorter's AI Models destination for the Downloads folder if one is configured in `sorter.json`, else `~/Downloads/AI Models`. **Choose…** picks any folder. **Save into LM Studio's models folder** sets it to `~/.lmstudio/models/<org>/<model>/` (shown only when `~/.lmstudio` exists).
- **Verify:** for files Hugging Face stores in LFS/Xet, its file list gives a SHA-256. After a file finishes, Rays checks it; a mismatch fails the job with "Checksum didn't match" and keeps the file for a retry. Files without a published hash are not checked.
- Engine change: `add` accepts an optional destination directory per job, and keeps the given file name instead of deriving one from `Content-Disposition`. Existing callers are unchanged.
- A ticked file already at its destination with the right size (and hash, when published) is skipped, not duplicated as `name (1).gguf`. The panel marks it "Already downloaded".

### Same-name setting

Settings > Downloads gets **If a file with the same name exists**, applying to every download, not only models:

- **Keep both** (default, today's behaviour): the new file is saved as `name (1).ext`.
- **Replace**: the existing file goes to the Trash when the download starts, and the new one takes its name.

With Keep both, the Models panel notes on affected rows that some apps (LM Studio, llama.cpp split files) expect exact file names.

### Gated models and the token

- Settings gets an optional Hugging Face access token, stored in Keychain alongside the cloud keys.
- The engine sends `Authorization: Bearer <token>` only on requests to `huggingface.co`, and never to the CDN host it redirects to. Every request (including resumes and extra connections) starts from the `huggingface.co/…/resolve/…` link, so an expired CDN link is never reused.
- Gated model and no token: the model shows a lock and the panel says to add a token in Settings. Token but license not accepted (HTTP 403): the job fails with "Accept this model's license on huggingface.co", linking to the model page.

### Sorter: AI Models category

- New category **AI Models** ("machine-learning model weights and checkpoints"), listed under Where files go so users can send it elsewhere like other categories.
- `rule()` sends model-weight files there by extension, with one subfolder per format: `gguf` → `GGUF`, `safetensors` → `Safetensors`, `onnx` → `ONNX`, `mlmodel` → `Core ML`, `tflite` → `TFLite`, `ckpt`/`pt`/`pth` → `PyTorch`. `.bin` stays unmatched (too generic).
- Model files skip the duplicate check: the rule is applied first for these extensions, so nothing hashes a multi-GB file.
- Folders are still left alone, so a model folder Rays downloaded is never split.

## Decided by the user

- Approach A: search by name, pick files, download.
- A setting for same-name files: replace (old file to Trash) or keep both with a number.
- Follow the reference dialog: version chips, Recommended/Select all/None, Save to with a model-app shortcut, files already present skipped.
- Sorter gets a separate AI Models folder so models are easy to find.

## Calls made in this doc (user can override)

- Models is a section in the Downloads window, not a separate sidebar item.
- Default folder `~/Downloads/AI Models/<org>/<model>/`.
- Token is optional, in Settings, in Keychain.
- GGUF repos default to `Q4_K_M` (+ `mmproj`); other repos to one weights format plus configs and tokenizer.
- SHA-256 check against Hugging Face's published hash.
- Same-name setting applies to all downloads and defaults to Keep both, so nothing changes for people who don't touch it.
- LM Studio shortcut; no Download later, no mirrors yet.
- Downloads pin the commit SHA shown when the model was opened.
- Sorter extension list and per-format subfolders above.

## Answers to the builder check

- **Fresh CDN links.** No `SignUrl`. Every request the engine makes for an `hf` job (first request, each extra connection, each resume or retry) goes to the `huggingface.co/<repo>/resolve/<sha>/<path>` link and follows the 302 itself. Rays' connections are long ranged reads, not small chunks, so this costs one extra Hugging Face round trip per connection or retry, which is fine. reqwest 0.13 drops `Authorization` when a redirect changes host, which keeps the token off the CDN; add a test that proves it.
- **File already at the destination.** Same size and matching hash (or same size when no hash is published): skip and mark "Already downloaded". A Rays partial for the same file: resume it, as the engine does today. Any other file with that name: follows the new **If a file with the same name exists** setting (below). The row says "Replaces the file there" or "Saves as name (1)" accordingly. A different commit SHA changes nothing here: the check is on the file itself.
- **Where `<AI Models>` comes from.** The app already reads `~/Library/Application Support/Rays/sorter.json` (`SorterModel.swift`, `SorterConfigFile`). Use the AI Models destination recorded for the Downloads folder if it is an absolute path; otherwise `~/Downloads/AI Models`. The sorter never moves folders except code projects, and it skips its own category folders, so `AI Models/<org>/<model>/` stays whole.
- **Sorter rule scope.** The AI Models rule and the skipped hash apply in every watched folder, and files go to the AI Models destination whether default or remapped, like every other rule.
- **Token storage.** The engine keeps the token in Keychain the way it keeps bucket secrets (`store.rs`); the app sets and clears it through an engine call. Resumed jobs after a restart read it from there.
- **Persistence.** The per-job destination folder is stored with the job in the engine's job store, with a migration that leaves existing jobs on the default folder. The token rule is by host (`huggingface.co`), so no per-job flag is stored.

## Left to the builder

- Exact Hugging Face API endpoints and fields (verify against current docs: search, model info with file sizes, gated flag, commit SHA).
- How the engine injects the token (per-host header from the store vs. a per-job header), within the rule above.
- Debounce timing, result count, empty and error states, icon choice.
- Tests: engine per-job destination and kept file name; token only sent to `huggingface.co`; sorter rule for each extension and that model files skip hashing.
