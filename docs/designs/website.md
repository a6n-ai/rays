# Rays website (rays.a6n.ai)

*   **Author:** lawbringr
*   **Status:** Proposed
*   **Date:** 2026-11-17

--------------------------------------------------------------------------------

## Overview

Rays is a free, open-source download manager for macOS 26. It downloads each
file in several parts at once, and its sorter moves every new file in
Downloads (and any folder the user adds) into a folder that fits, using
Apple's on-device model. It ships as a DMG on GitHub releases and as a
Homebrew cask (`a6n-ai/tap/rays`).

Today the only public face of Rays is the GitHub README. This design adds a
one-page static website at `rays.a6n.ai`, built with Astro and served from
Cloudflare Pages. The page says what Rays does in a few short passages of
text, and its first screen gets the visitor to download the DMG or copy the
Homebrew command. The design target is a page that could be submitted to
Awwwards and scored with the jury skill.

Layout reference (chosen by author): superlogical.com. A dark page with one
text column on the left, a sticky grainy-gradient panel on the right whose
colour shifts as the page scrolls, and a 3D word drum in the hero. We borrow
that structure and motion, not its words, logo or exact colours.

## The Problem

*   **No front door.** A visitor who hears about Rays lands on a GitHub
    README. It lists commands, but a person who does not use GitHub has no
    clear "Download" button.
*   **Install has a trust step.** Rays is not notarized. A DMG download is
    blocked by Gatekeeper on first open until the user approves it in System
    Settings. If the page does not say this, the first experience is an error
    dialog.
*   **Real screenshots leak private data.** The Downloads and Recent screens
    on the author's Mac show real work file names (VPN profiles, DR
    documents). Only the Sorter setup screen is clean today.

Proposed solution: a calm, text-led single page. The hero names the kinds of
files Rays sorts on a rolling word drum and holds the only two install
actions: Download for Mac and the Homebrew command. Below it, short passages
explain downloading, sorting, privacy and the browser and Terminal tools.

## Goals

*   **One job, one place:** the hero holds both install actions and nothing
    else on the page repeats them. Stable targets:
    `https://github.com/a6n-ai/rays/releases/latest/download/Rays.dmg` and
    `brew install --cask a6n-ai/tap/rays` (one click to copy). A one-line
    note under them covers the Gatekeeper step.
*   **Truthful content only:** no invented numbers, users, quotes or logos.
    Every claim maps to a shipped feature. Every file name on the page is
    invented demo text.
*   **Fast and accessible:** static HTML with no server code. Targets: LCP
    under 2.0 s on a throttled phone, CLS under 0.05, axe with zero serious
    issues, keyboard path to both install actions, and a
    `prefers-reduced-motion` version where the drum and the panel stay still.
*   **Jury score:** the `jury` skill's blind critic scores the deployed page
    at 8.0 or higher overall before any Awwwards submission is considered.

## Non-Goals

*   No Worker, server code, analytics, cookies or forms (the reference's
    waitlist form is not copied). Cloudflare Pages static files only.
*   No nav bar download button and no bottom install section; install lives
    in the hero only (author decision). Upgrade and uninstall commands stay
    in the README.
*   No interactive demo or sorting toy (author decision).
*   No blog, docs site, changelog page or pricing.
*   No change to the a6n.ai site (aether); this page links to a6n.ai once,
    in the footer.
*   No Windows or Linux downloads; Rays is macOS 26 only.
*   No paid Awwwards submission as part of this work.
*   No notarization work.

## Open Questions

*   **Domain:** `rays.a6n.ai` is assumed. The logged-in wrangler account has
    to be checked against the Cloudflare account that owns the a6n.ai zone.
*   **Deploy trigger:** manual `npm run deploy` from the laptop, or
    Cloudflare Pages' Git integration (builds on push, no API token stored
    anywhere). Decided in Detailed Implementation.

## Critical User Journeys (CUJs)

### CUJ 1: First-time visitor downloads Rays

*   **Given**: A Mac user on macOS 26 opens `rays.a6n.ai`.
*   **When**: The hero loads with the word drum rolling; they click
    "Download for Mac".
*   **Then**: The browser downloads `Rays.dmg` from the stable GitHub link.
    The note under the button says to drag Rays to Applications and, on first
    open, approve it in System Settings, Privacy and Security, Open Anyway.

### CUJ 2: Developer installs with Homebrew

*   **Given**: The visitor uses Homebrew.
*   **When**: They press the copy button on
    `brew install --cask a6n-ai/tap/rays` in the hero.
*   **Then**: The command is on the clipboard and the button reads "Copied"
    for two seconds; a polite live region says the same.

### CUJ 3: Visitor reads before deciding

*   **Given**: The visitor scrolls past the hero.
*   **When**: They read the passages.
*   **Then**: The right panel's colour shifts with scroll position, the
    passages explain each feature in plain words, and the clean Sorter
    screenshot shows the real settings. Scrolling back to the top returns to
    the install actions.

## Technical Plan (Architecture)

### Skill roles

| Skill | Role in this build |
|---|---|
| hallmark | The floor: tokens, focus, reduced motion, no invented proof, `sloplint --render` before hand-back |
| ui-ux-pro-max, impeccable | Type scale, measure, contrast and copy review; impeccable audit pass |
| apple-design | Material and depth of the sticky panel, typography tracking at display sizes |
| stageshow, awwwards | The two signature moments only: the word drum and the scroll-linked panel |
| animate | Builds each animation in order: whether, purpose, properties, curve, duration |
| jury | Scores the deployed URL; the score gates any submission |

### Stack

*   Astro 7.4.12, static output (`dist/`), one page plus a 404.
*   No UI framework and no animation library. One small vanilla TypeScript
    module (target under 3 KB gzipped) for the word drum and the copy button.
    The panel's scroll colour uses CSS scroll-driven animation
    (`animation-timeline: scroll()`); browsers without it show a still
    gradient.
*   Fonts: the system stack for text (matches the app), plus one mono for
    the footer and the command chip (`ui-monospace`). No font download.
*   Hosting: Cloudflare Pages, static files only.

### Page structure (desktop, 1440 wide)

```
+------------------------------------------+  +----------------+
| [icon] Rays                              |  |                |
|                                          |  |  sticky panel  |
| Rays sorts your   installers.            |  |  grainy        |
|                   invoices.   <- drum    |  |  gradient,     |
|                   screenshots.           |  |  colour moves  |
|                                          |  |  with scroll   |
| +--------------------------------------+ |  |                |
| | [icon] Rays 0.1.4 for macOS 26       | |  |                |
| |                   Download for Mac   | |  |                |
| +--------------------------------------+ |  |                |
| $ brew install --cask a6n-ai/tap/rays [copy]|                |
| First open: System Settings, Privacy &   |  |                |
| Security, Open Anyway.                   |  |                |
+------------------------------------------+  |                |
| Downloads      passage                   |  |                |
| Sorting        passage + Sorter shot     |  |                |
| Private        passage                   |  |                |
| Anywhere       passage (paste, browser,  |  |                |
|                `dl` in Terminal)         |  |                |
| Made by a6n    one line                  |  |                |
| GitHub ---------------- a6n.ai  v0.1.4   |  |                |
+------------------------------------------+  +----------------+
```

Below 900 px the panel becomes a 30 vh band behind the hero only, and the
column takes the full width.

### Word drum

A vertical list of phrases on a 3D cylinder (`rotateX` per item,
`perspective` on the parent). Phrases are kinds of files Rays sorts, all
generic: installers, invoices, screenshots, podcasts, passport scans, zip
files, design docs, photos. The drum turns one step every 1.8 s with an
ease-out settle; the front phrase is full opacity and the rest fade with
distance. Screen readers get one static sentence ("Rays sorts your
downloads into folders.") and the drum is `aria-hidden`. Reduced motion:
the drum does not turn and shows the first phrase only. It pauses when the
tab is hidden or the hero is off screen.

### Sticky panel

A rounded rectangle, `position: sticky`, full viewport height minus a
margin. Fill: a linear gradient using the Rays DMG palette (cream, rose,
lilac, sky) extended with one deep tone for the bottom of the page. An SVG
`feTurbulence` noise layer at low opacity gives the grain. A scroll-driven
animation moves `background-position` from top to bottom over the page's
scroll length, so the colour changes as the reader moves down. Only
`background-position` and `opacity` animate. It is decorative and
`aria-hidden`.

### Visual system

*   Dark page by default (near-black ground, off-white text, one warm accent
    for links and the Download action), with a light theme under
    `prefers-color-scheme: light`. Tokens on `:root`.
*   Type: one size for passages (about 20 px, line height 1.45, measure
    about 60 ch), the hero sentence larger (about 32 px), section labels in
    the text face at a smaller size, muted, sentence case.
*   Pictures: the real app icon (`public/icon.png`) in the hero bar and the
    one clean Sorter screenshot (`public/sorter.png`) in the Sorting passage.

### Build and deploy flow

```
site/ (Astro) --npm run build--> site/dist/ --deploy--> Cloudflare Pages "rays"
                                                         custom domain rays.a6n.ai
```

The download link points at the GitHub `latest` asset, so a new Rays
release needs no site change. The version label in the hero bar and footer
is read at build time from the GitHub releases API (`/releases/latest`); if
the call fails the label is left out.

### Quality gates

1.  `hallmark` `sloplint.mjs --render` on the built page: zero FAIL.
2.  `impeccable` audit: fix every high-severity item.
3.  Lighthouse on a throttled phone: LCP < 2.0 s, CLS < 0.05, a11y 100.
4.  `jury` on the deployed URL: overall 8.0 or higher; otherwise fix the
    ranked list and run again.

## Alternatives Considered

### A page inside the a6n.ai site (aether, `a6n.ai/rays`)

*   **Mechanism:** add `src/pages/rays.astro` to the existing a6n Astro site
    and reuse its layout, fresco palette and GSAP setup.
*   **Rejected by author:** a6n.ai speaks to small-business owners with a
    Michelangelo fresco theme and a "book a call" goal. Rays needs its own
    look and an install goal; mixing them weakens both. A push to aether's
    main also deploys the whole agency site.

### A Cloudflare Worker serving the page

*   **Mechanism:** a Worker script (or Worker with static assets) answers
    requests.
*   **Rejected by author:** the page has no dynamic part. Pages serves the
    same static files with no code to run or maintain.

### Direction A: native restraint (Apple product page style)

*   **Mechanism:** light sunlit gradient, glass panels, an HTML copy of the
    Rays window sorting a demo file.
*   **Rejected by author:** fastest and safest, but reads as one more
    Apple-style page and scores low on Creativity.

### Direction B: scroll-driven story

*   **Mechanism:** pinned hero; scroll moves one file from the browser into
    Rays and into a folder, with GSAP ScrollTrigger and Lenis.
*   **Rejected by author:** highest risk to load speed, accessibility and
    the download button's visibility; two to three times the build effort.

### Direction C: interactive sorting toy

*   **Mechanism:** the visitor drags demo files from a messy Downloads
    folder onto Rays and watches them get renamed and filed; autoplay when
    idle.
*   **Rejected by author:** replaced by the superlogical.com layout
    reference. A calm text-led page with two signature motions (word drum,
    scroll-linked panel) was preferred over an interactive demo.

### Install actions in the nav and a bottom install section

*   **Mechanism:** a Download button in a sticky nav plus a full install
    section (DMG steps, Gatekeeper, brew install, upgrade, uninstall).
*   **Rejected by author:** install lives in the hero only. Upgrade and
    uninstall stay in the README; the Gatekeeper step is one line under the
    hero actions.

## Detailed Implementation

Deploy trigger (chosen by author): a GitHub Action with a Cloudflare API
token stored as a GitHub secret. The token is created in the Cloudflare
dashboard in the browser and pasted into GitHub's secret page; it never
lands on the laptop.

All paths are relative to the repository root (`rays/`).

### One-time setup (by the author, in the browser)

1.  Cloudflare dashboard, on the account that owns the `a6n.ai` zone:
    Workers & Pages, Create, Pages, "Direct Upload", project name `rays`,
    production branch `main`.
2.  Same project, Custom domains, add `rays.a6n.ai` (Cloudflare adds the
    CNAME record in the a6n.ai zone).
3.  My Profile, API Tokens, Create Token, Custom: permission
    `Account / Cloudflare Pages / Edit`, limited to that one account, with
    an expiry date. Copy it.
4.  GitHub `a6n-ai/rays`, Settings, Secrets and variables, Actions: add
    `CLOUDFLARE_API_TOKEN` (the token) and `CLOUDFLARE_ACCOUNT_ID` (the
    account ID from the dashboard sidebar). Same secret names as the realm
    deploy workflows; the token value can be shared with realm's if it has
    Pages edit on the a6n.ai account. Hosting stays Cloudflare Pages, not
    Workers (author decision).

### Files

| File | Change | Why |
|---|---|---|
| `site/package.json` | Edit (exists) | Scripts `dev`, `build`, `check`; dependency `astro` 7.4.12 pinned. Drop the local `deploy` script so deploys only come from CI. |
| `site/package-lock.json` | Create (by npm) | Reproducible `npm ci` in CI. |
| `site/astro.config.mjs` | Edit (exists) | `site: 'https://rays.a6n.ai'`, static output, `build.inlineStylesheets: 'always'` so the first paint needs no extra CSS request. |
| `site/.gitignore` | Exists | Ignores `node_modules/`, `dist/`, `.astro/`, `.wrangler/`. |
| `site/src/layouts/Base.astro` | Create | `<html>`, meta description, canonical, Open Graph and Twitter tags, favicon links, `color-scheme`, imports the two CSS files, skip link. |
| `site/src/styles/tokens.css` | Create | All colours, the gradient stops, type sizes, spacing and radii as custom properties on `:root`; light theme overrides under `prefers-color-scheme: light`. |
| `site/src/styles/base.css` | Create | Reset, `overflow-x: clip` on `html` and `body`, `:focus-visible` ring, reduced-motion rules, two-column grid (text column plus sticky panel) and the under-900 px single-column layout. |
| `site/src/pages/index.astro` | Create | Composes Hero, the four passages, the a6n line and Footer inside the grid, plus the Panel. Fetches the version through `release.ts`. |
| `site/src/pages/404.astro` | Create | Same layout, one line and a link home. |
| `site/src/components/Hero.astro` | Create | Icon and wordmark, the sentence "Rays sorts your" plus WordDrum (and a screen-reader sentence), then InstallBar. |
| `site/src/components/WordDrum.astro` | Create | The phrase list as `aria-hidden` markup with per-item 3D transforms; loads `drum.ts`. |
| `site/src/components/InstallBar.astro` | Create | The two install actions: the bar with icon, "Rays {version} for macOS 26" and the Download for Mac link; the brew command chip with a copy button and live region; the Gatekeeper note. |
| `site/src/components/Passage.astro` | Create | One labelled section: muted label, paragraph slot, optional figure. Used four times. |
| `site/src/components/Panel.astro` | Create | The sticky gradient panel with the inline SVG noise layer; scroll-driven animation in its scoped CSS. |
| `site/src/components/Footer.astro` | Create | Mono row: GitHub link, thin rule, `a6n.ai` link, version. |
| `site/src/scripts/drum.ts` | Create | Steps the drum every 1.8 s; stops when `document.hidden`, when the hero leaves the viewport (`IntersectionObserver`), or under reduced motion. |
| `site/src/scripts/copy.ts` | Create | Copy button: `navigator.clipboard.writeText`, label to "Copied" for 2 s, text into the live region; if the clipboard is blocked, selects the command text instead. |
| `site/src/lib/release.ts` | Create | Build-time `fetch` of `https://api.github.com/repos/a6n-ai/rays/releases/latest`; returns the tag without the leading `v`, or `null` on any error so the build never fails because of it. |
| `site/src/lib/release.test.ts` | Create | Assert-based self-check run with `node --test`: tag `v0.1.4` gives `0.1.4`; a failed or malformed response gives `null`. |
| `site/public/icon.png` | Exists | App icon, 512 px, used in the hero bar. |
| `site/public/sorter.png` | Exists | Clean Sorter setup screenshot (no personal file names), used in the Sorting passage. |
| `site/public/apple-touch-icon.png` | Exists | 180 px icon. |
| `site/public/favicon.png` | Create | 32 px from `icon.png` with `sips`. |
| `site/public/og.png` | Create | 1200 by 630 social image: a screenshot of the built hero taken with `agent-browser` at that viewport, committed. |
| `site/public/robots.txt` | Create | Allow all, sitemap line omitted (one page). |
| `site/public/_headers` | Create | Cloudflare Pages headers: a strict Content-Security-Policy (self only, no inline scripts beyond Astro's hashed ones), `X-Content-Type-Options`, `Referrer-Policy`, long cache for `/_astro/*`. |
| `.github/workflows/site.yml` | Create | On push to `main` touching `site/**` and on manual run: checkout and setup-node pinned by commit SHA, Node 22, `npm ci`, `npm run check`, `node --test`, `npm run build`, then `npx wrangler@4.161.0 pages deploy dist --project-name rays --branch main` with the two secrets as env. If the token secret is missing, the job prints a notice and exits 0. |
| `README.md` | Edit | Add the website link at the top of the Install section. |
| `docs/designs/website.md` | Exists | This design document. |

### Copy (plain words, every claim backed by a shipped feature)

*   Hero sentence: "Rays sorts your" plus the drum (installers, invoices,
    screenshots, podcasts, passport scans, zip files, design docs, photos).
*   Downloads: each file comes down in several parts at once; pause and
    resume; paste links in any format (lines, commas, CSV).
*   Sorting: watches Downloads and any folder you add; waits a few seconds
    (you choose how long), then moves each new file into a folder that fits;
    can rename files from their content, or keep original names.
*   Private: sorting runs on your Mac with Apple's on-device model; nothing
    is uploaded; no account.
*   Anywhere: the browser extension sends downloads to Rays; the `dl`
    command does the same from Terminal; Rays tells you when an update is
    ready.
*   Requirement line: macOS 26 or later. Free and open source.

### Order of work

1.  Tokens, base CSS and Base layout; Hero and InstallBar with no motion.
    Run `sloplint --render --stage hero` and fix.
2.  Passages, Panel (still), Footer, 404.
3.  Motion: drum, then the scroll-linked panel, each built with the
    `animate` skill; reduced-motion versions checked.
4.  `release.ts` plus its test; `copy.ts`.
5.  Full `sloplint --render`, `impeccable` audit, Lighthouse.
6.  `site.yml`; the author completes the one-time setup; first deploy.
7.  `og.png` from the deployed hero; `jury` on `https://rays.a6n.ai`;
    fix the ranked list until 8.0 or higher.
