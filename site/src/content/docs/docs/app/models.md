---
title: "Download Hugging Face models"
description: "Search Hugging Face in Rays, pick the quantization or weights you need, and download them to your Mac or straight into LM Studio's models folder."
---

**Models** downloads model files from Hugging Face. Each file downloads as a normal Rays download, with pause, resume and the speed limit. In the sidebar, **Models** sits between **Sorter** and **Cloud**.

## Find a model

Type in the search box. It takes:

- **A name**, like `llama`.
- **A repo**, like `org/repo`. Typing it searches for that repo.
- **A link**, like `https://huggingface.co/org/repo`. Paste it and Rays opens that model directly.

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

- **Verifying.** A file being checked shows **Verifying…** until the check finishes.
- **Checksum.** Each file is checked against the SHA-256 that Hugging Face publishes. A mismatch fails with "Checksum didn't match". Click **Resume** to download it again.
- **Failed files.** Adding a model again resumes a file that failed earlier, if it is the same file and revision. Otherwise the download starts fresh.
- **Already there.** A file that is already in the folder with the right size is skipped ("Already downloaded"). A file that is already downloading shows "Already in Downloads".

## Verify a download

Open **Downloaded models** on the **Models** page, then hover a model or open its **⋯** menu and choose **Verify files**. Rays checks each file against the record it saved when the file downloaded: its size and SHA-256 checksum. The check runs on your Mac and doesn't go online.

The result is one of:

- **All N files match**, or **N files match** when other files have problems or were checked by size only.
- **N files checked by size only.** Hugging Face gave no checksum for those files.
- Per file: **Missing**, **Wrong size** or **Checksum didn't match**.

Click **Re-download N files** to queue only the files that failed. If **If a file with the same name exists** isn't set to **Replace**, Rays first moves the files with a wrong size or checksum to the Trash. Missing files are just queued.

With no record of the download, click **Look up on Hugging Face**. Rays checks the files against the latest revision, so a model that has changed on Hugging Face since you downloaded it can fail.

## Gated and private models

Some models need a Hugging Face access token. Add it in the **Settings** card at the top of the **Models** page, in **Hugging Face token**. The card also has **AI Models folder**, where model downloads go. It is stored in the macOS Keychain and sent only to huggingface.co. Where a message below says "Settings", it means this card.

- **Gated, no token:** "This model is gated: add your Hugging Face token in Settings".
- **Not found, no token:** "Couldn't find this model on Hugging Face. If it's private or gated, add your Hugging Face token in Settings." Hugging Face answers the same way for a repo that doesn't exist and a private one.
- **License not accepted:** "Accept this model's license at https://huggingface.co/<org>/<repo>". The link opens the model page.
- **Wrong token:** "Hugging Face rejected the saved token. Check it in Settings".
