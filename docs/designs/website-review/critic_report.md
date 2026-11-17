# Stage 7: Critic Review

Target: `docs/designs/website.md` FeatureRange (lines 1-273). Reviewers
(fresh context each, all completed): egm-design (feature-spec standard),
egm-structural (feature-spec standard), egm-style. GoldfishContext:
`README.md`, `.github/workflows/release.yml`.

Raw totals: design 3 Blocker / 9 Major / 7 Nit; structural 1 Blocker /
2 Major / 5 Nit; style 0 Blocker / 6 Major / 15 Nit. The tables below merge
duplicates.

## Blockers

| ID | Finding | Raised by | Elephant note |
|---|---|---|---|
| C1 | No Risks & Mitigations section. The feature-spec standard requires one. Candidate risks: stale or missing version label, dependence on the `Rays.dmg` asset name, Gatekeeper friction, browsers without `animation-timeline`, unconfirmed zone ownership, a jury target that may never be reached. | design B2, structural 1 | Valid. |
| C2 | Alternatives say "Rejected by author" with no link. The Direction C and "install in nav" rejections give no concrete trade-off. | design B1, structural 2-3, style 20 | Valid. Replace with technical reasons. |
| C3 | The core claims may be false for a DMG user. The README says the sorter is external at `~/local-scripts/sorter/bin/sorter`. The browser extension needs Developer mode and a repo checkout, and `dl` is on PATH only with Homebrew. | design B3, style 3-4 | Partly valid. Verified: `scripts/bundle-app.sh` lines 33-36 bundle `sorter` and `extract` inside Rays.app, so sorting does ship and the README is stale. The browser extension still needs Load unpacked (README line 59), and `dl` comes with Homebrew only. The "Anywhere" passage must be qualified. |

## Majors

| ID | Finding | Raised by |
|---|---|---|
| C4 | The version label goes stale after each release and the GitHub API is rate-limited. This contradicts "needs no site change". | design M1, style 6 (also Stage 5 #1) |
| C5 | Gatekeeper steps disagree with the README, and the note reads as if it applies to brew too. Scope it to the DMG and fix the README. | design M2, style 2, structural 8 |
| C6 | The drum auto-advances forever, which fails WCAG 2.2.2 (Pause, Stop, Hide). Reduced motion does not cover it. Stop after one cycle or add a pause control. | design M4 |
| C7 | `background-position` on a full-height panel with SVG `feTurbulence` repaints on every scroll frame. Use a `transform` on an oversized layer and a static grain image. | design M5 |
| C8 | The page asks users to bypass Gatekeeper but offers no integrity check. `release.yml` hashes only the zip. Publish the DMG's SHA-256. | design M6 |
| C9 | The only success metric is a subjective LLM score. Add a baseline and target for `Rays.dmg` download counts from the GitHub release API. | design M7 |
| C10 | Missing alternatives: GitHub Pages hosting, and a README-only baseline. | design M8 |
| C11 | Open questions (deploy trigger, zone ownership) are stale or still unresolved. | design M9, structural 4, style 12 |
| C12 | Two different a11y gates (axe "zero serious" vs Lighthouse "a11y 100"), and "throttled phone" is not defined. | style 5 |
| C13 | "No front door" overstates the gap: the README already has a bold Download link. Restate it as "a visitor must find and read a developer README". | style 1 |
| C14 | The "clean" Sorter screenshot may show a path under the user's home folder. | design M3 |

Elephant note on C14: the captured `site/public/sorter.png` shows only the
On-device AI row, wait time, rename toggle and the folders "Documents" and
"Downloads". It shows no path and no account name. Low risk; record it as
checked.

## Nits

| ID | Finding | Raised by |
|---|---|---|
| C15 | Skills and tools (hallmark, sloplint, jury, impeccable, etc.) are undefined, with no paths. | design N5, style 7 (also Stage 6 #1) |
| C16 | Slogan headings and subjective words ("No front door", "calm", "mixing them weakens both", "plain words"). | style 8-10, 17 |
| C17 | Unsupported numbers: "scores low on Creativity", "two to three times the build effort". | style 18-19 |
| C18 | The ASCII diagram's brew row breaks the border; the footer row has no label; the version is hard-coded (use `vX.Y.Z`). | structural 6-7, style 13-14 |
| C19 | Direction A/B/C labels have no context. | structural 5 |
| C20 | Vague tokens: "about 20 px", "about 60 ch", "low opacity"; the DMG palette has no source file or hex values. | style 15-16 (also Stage 6 #10) |
| C21 | Phone and non-macOS-26 visitors have no path (they cannot install a Mac app from a phone). | design N1 |
| C22 | The screen reader may read the hero line twice. | design N2 |
| C23 | No fallback when the clipboard is blocked. | design N3 |
| C24 | No `width`/`height` on images (CLS); the icon may become the LCP element. | design N4 |
| C25 | The reason for pinning Astro 7.4.12 is not stated. | design N6 |
| C26 | Gates do not say whether both themes are contrast-checked. | design N7 |
| C27 | No licence named for "open source". | style 21 |
