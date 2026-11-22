---
title: "Browser extension for Chrome and Firefox"
description: "Send links and downloads from Chrome, Brave, Edge, Firefox and Zen to Rays with a right-click, or hand every browser download to Rays."
---

The extension adds **Download with Rays** to the menu when you right-click a link. It talks to Rays through a small helper that Rays installs for each browser.

[**Get Rays for Chrome**](https://chromewebstore.google.com/detail/mgepiogdappnhmohefhalmeppkfciail) from the Chrome Web Store. It also works in Brave and Edge.

## Add it

1. Open **Rays > Settings > Browsers**. Rays lists the browsers it found.
2. Click **Install All Helpers**, or install the helper for one browser.
3. Add the extension:
   - **Chrome, Brave, Edge:** open [Rays in the Chrome Web Store](https://chromewebstore.google.com/detail/mgepiogdappnhmohefhalmeppkfciail) and click **Add to Chrome**. In Edge, first allow extensions from other stores when it asks.
   - **Firefox, Zen:** the extension is not on addons.mozilla.org yet. In Rays, click **Show Extension Folder**, open `about:debugging`, click **This Firefox > Load Temporary Add-on**, and choose `manifest.json` in the extension folder. Temporary add-ons last until the browser restarts.
4. The browser's row in Settings shows **Connected to Rays**.

## Use it

- Right-click a link and choose **Download with Rays**. The toolbar badge shows `+N` when Rays accepted it and `!` on an error.
- In the extension's options, **Send all browser downloads to Rays** hands every browser download to Rays. The browser's own copy is cancelled only after Rays accepts the link.

## Remove it

Remove the extension in the browser, then click **Remove Helper** for that browser in **Settings > Browsers**, or **Remove All Helpers**.
