---
title: "Organize your Downloads folder automatically"
description: "Rays sorts new files on your Mac into Work, Images, Installers and more with on-device AI, and can rename them from their content. Set it up in a minute."
---

The sorter watches the folders you choose. A few seconds after a new file arrives, it moves it into a folder that fits it, inside the watched folder:

| Folder | What goes there |
|---|---|
| Work | Anything about a business or job: invoices, orders, reports, specs, data exports |
| Personal | Your own documents: IDs, bank statements, receipts, medical, certificates |
| Images | Photos, screenshots, logos, wallpapers |
| Installers | Apps, disk images, packages, VPN profiles |
| Archives | Zip, tar, rar and other compressed files |
| Media | Audio and video |
| Code | Source code and scripts |
| AI Models | Loose model files: `.gguf`, `.safetensors`, `.onnx`, `.mlmodel`, `.tflite`, `.ckpt`, `.pt` and `.pth` |
| Other | Manuals, articles, ebooks, anything else |

Model files keep their names and are not checked for duplicates. Model folders, like one Rays downloaded from [Models](/docs/app/models/), are left alone.

Sorting runs on your Mac with Apple's on-device model. Nothing is uploaded.

![The Sorter Setup tab: on-device AI ready, sort new files after 10 seconds, rename files from their content, and the Documents and Downloads folders.](../../../../assets/sorter.png)

## Set up

Open **Sorter** in the sidebar. The **Setup** tab (the sliders icon in the toolbar) has:

- **On-device AI**: shows whether Apple Intelligence is ready.
- **Sort new files after**: how long Rays waits after a file arrives, so you can open or move it first. 10 seconds is recommended.
- **Rename files from their content**: gives files clear names from what is inside them. Turn it off to keep original names; files are still sorted.
- **Folders**: the folders Rays watches. Each row has icons to sort now, show in Finder, and stop watching. Use **Add Folder…** or **Add Desktop** to add more.
- **Remove Sorter…**: stops sorting every folder.

Files that were in a folder before you added it stay where they are. To sort those too, run `dl sort FOLDER --all`.

## Choose where a category goes

Click a folder row to open it. Under **Where files go**, pick a category to send it to another folder (for example Work to `~/Documents/Work`), use the default folder inside, or show it in Finder.

## Browse sorted files

- **Files** tab (the folder icon): your sorted folders as a Finder-style list or as icons. Double-click a folder to open it, or a file to open it in its app. Right-click for **Open**, **Show in Finder** and **Copy Path**.
- **Recent** tab (the clock icon): the latest moves. Double-click a row to open the file; the round folder button shows it in Finder. On hover, **Move Back** returns the file to the folder it came from, under its original name, and the sorter leaves it there. **⋯** adds AirDrop, Share and Copy Path.
- A file moved or deleted since it was sorted shows **Moved or deleted since**; its round button removes it from the list, and **Remove Missing** clears them all. This hides the row in Rays only.

## Update older sorter setups

If you used the sorter before it was built into Rays, the Setup tab shows **Update All**. It switches those folders to the sorter inside Rays. Nothing is moved.
