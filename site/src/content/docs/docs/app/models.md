---
title: "Download Hugging Face models"
description: "Search Hugging Face in Rays, pick the quantization or weights you need, and download them to your Mac or straight into LM Studio's models folder."
---

**Models** in the sidebar downloads model files from Hugging Face. Each file downloads as a normal Rays download, with pause, resume and the speed limit.

## Find a model

Type in the search box. It takes:

- **A name**, like `llama`.
- **A repo**, like `org/repo`.
- **A link**, like `https://huggingface.co/org/repo`. Rays opens that model directly.

Results show downloads and likes. A lock means the model is gated and you have no token saved.

## Choose files

Opening a model shows its repo, a **GGUF** tag if it has one, its downloads, and an **Open on Hugging Face** link. It also shows the selected total size and the free space on your disk.

- **GGUF repos** have a **Version** button for each quantization, like Q4_K_M, Q6_K and Q8_0. Q4_K_M is recommended (★). Its vision projector (`mmproj`) is ticked with it.
- **Other repos** recommend one weights format, safetensors first, plus the config and tokenizer files.

Use **Recommended**, **Select all** or **None** to change the selection. The count shows "N of M selected". **‹ Results** goes back to the search results.

## Save to

**Save to** defaults to `~/Downloads/AI Models/<org>/<model>/`. If you set an AI Models folder under the sorter, Rays uses that instead. Click **Choose…** to pick any folder.

If LM Studio is installed, **Save into LM Studio's models folder** appears too.

Files that already exist with the same name follow the **If a file with the same name exists** setting. See [Downloads](/docs/app/downloads/#how-rays-downloads).

## Checks

- **Checksum.** Each file is checked against the SHA-256 that Hugging Face publishes. A mismatch fails with "Checksum didn't match". Click **Resume** to download it again.
- **Already there.** A file that is already in the folder with the right size is skipped ("Already downloaded"). A file that is already downloading shows "Already in Downloads".

## Gated and private models

Some models need a Hugging Face access token. Add it under **Settings > Downloads > Hugging Face > Access token**. It is stored in the macOS Keychain and sent only to huggingface.co.

- **Gated, no token:** "This model is gated: add your Hugging Face token in Settings".
- **License not accepted:** "Accept this model's license on huggingface.co".
