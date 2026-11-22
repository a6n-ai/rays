---
title: Privacy policy
description: How Rays, the Rays browser extension and rays.a6n.ai handle your data. Rays runs on your Mac and collects nothing.
---

Last updated: 22 November 2026

Rays is made by a6n. This policy covers the Rays app for Mac, the `dl` command, the Rays browser extension for Chrome, Brave, Edge, Firefox and Zen, and this website.

**The short version: Rays collects no personal data. Your downloads, files and settings stay on your Mac.**

## The Rays app and `dl`

- Downloads go straight from the server you chose to your Mac. They do not pass through a6n.
- File sorting and renaming run on your Mac with Apple's on-device model. File contents and names are never uploaded.
- Settings, download history and sorter rules are stored only on your Mac.
- Rays has no analytics, tracking, advertising or crash reporting.
- To check for updates, Rays asks GitHub for the latest release (`api.github.com`). GitHub sees your IP address, as with any web request. See [GitHub's privacy statement](https://docs.github.com/site-policy/privacy-policies/github-general-privacy-statement).
- If you add a cloud bucket in Settings > Cloud, Rays sends files to the S3-compatible service you configured. That service's own privacy policy applies. Your keys are stored in the macOS Keychain on your Mac.

## The browser extension

- When you choose **Download with Rays**, or turn on **Send all browser downloads to Rays**, the extension passes the link to the Rays app on your Mac through the browser's native messaging. That is the only place links go.
- The extension does not read pages, collect browsing history or send anything to a6n or any other server.
- It stores one setting, **Send all browser downloads to Rays**, in the browser's local extension storage.
- Permissions: `contextMenus` adds the menu item, `nativeMessaging` talks to the Rays app, `downloads` hands browser downloads to Rays when you turn that on, and `storage` saves your setting.

The extension's use of data complies with the [Chrome Web Store User Data Policy](https://developer.chrome.com/docs/webstore/program-policies/user-data-faq), including the Limited Use requirements.

## This website

- rays.a6n.ai has no analytics or tracking cookies.
- It is hosted on Cloudflare, which processes standard request data such as IP addresses to serve and protect the site. See [Cloudflare's privacy policy](https://www.cloudflare.com/privacypolicy/).
- The update sign-up opens your own mail app with a message to hi@a6n.ai. If you send it, we keep your email address only to tell you about new versions. Ask us and we will delete it.

## Email

If you email us, we use your message only to reply. We do not sell or share it.

## Children

Rays is not directed at children under 13 and collects no data from anyone.

## Changes

If this policy changes, the new version will be posted here with a new date.

## Contact

Questions about privacy: [hi@a6n.ai](mailto:hi@a6n.ai).
