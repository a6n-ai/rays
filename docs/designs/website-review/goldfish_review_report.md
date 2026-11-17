# Goldfish Annotated Review Report

**Target:** `docs/designs/website.md` (full file; Stage 7 range 1-273, plus
Stage 5 and 6 findings that point into lines 274-361)

Sources: `zoom_out_report.md` (Z#), `comprehension_report.md` (U#),
`critic_report.md` (C#).

## Escalations (need the author's knowledge)

### [E1] [`zoom-out`, `inventive-catalyst`, `comprehension`] - Severity: Major
*   **Affected Scope:** Open Questions; Detailed Implementation preamble and one-time setup
*   **Discrepancy Description:** The deploy uses a GitHub Action with a long-lived Cloudflare token, and the doc suggests sharing realm's token. Pages Git integration needs no token at all. A "Direct Upload" project cannot be switched to Git integration later. (Z2, U6, C11)
*   **Rationale:** A shared Pages-edit token can change every Pages project on the account. The chosen option was not one of the two listed in the doc.
*   ***AI Suggestion:*** ESCALATE
*   ***Justification:*** The author chose the Action to match realm's deploy pattern; that decision was made in chat, not recorded in the doc. Only the author can say whether to keep it.
*   ***Proposed Edit (if kept):*** Record the reason ("same pattern as the a6n realm workflows: checks run in GitHub before deploy"). Use a **separate** token scoped to Pages edit on the one account, not realm's. Note that Direct Upload is a one-way choice.

### [E2] [`style`] - Severity: Nit
*   **Affected Scope:** Overview, line 11 ("free, open-source")
*   **Discrepancy Description:** No licence is named. (C27)
*   **Rationale:** The repo has no `LICENSE` file (checked: none at the repo root). A public repo without a licence is not open source in the legal sense.
*   ***AI Suggestion:*** ESCALATE
*   ***Justification:*** Choosing a licence (for example MIT or Apache-2.0) is the author's call. Until a licence exists, the page must say "source available on GitHub", not "open source".

## Proposed fixes

### [F1] [`design`, `structural`] - Blocker: no Risks & Mitigations (C1)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add `## Risks & Mitigations` before Detailed Implementation, listing:
    *   the `Rays.dmg` asset name (`release.yml` line 55) is a contract, so a comment is added there;
    *   Gatekeeper friction (DMG-only note plus a published SHA-256);
    *   browsers without `animation-timeline` (still gradient);
    *   zone ownership not yet confirmed (setup step 1 is blocked until it is);
    *   a jury target that may not be reached (capped rounds);
    *   token scope (E1).

### [F2] [`design`, `structural`, `style`] - Blocker: "Rejected by author" with no reasons (C2)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add one line under Alternatives: "The author (lawbringr) made the direction and placement decisions." Replace each "Rejected by author:" with "Rejected:" plus a concrete trade-off:
    *   Direction C: a drag toy needs about 8 KB of JS, three input paths (pointer, touch, keyboard) and its own LCP and a11y testing. The text-led page needs about 1 KB.
    *   Nav and bottom install: two more places to keep in sync and two more calls to action competing with the hero. Upgrade and uninstall are rare tasks that already live in the README.

### [F3] [`design`, `style`] - Blocker: claims a DMG user may not get (C3)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Justification:*** Sorting does ship: `scripts/bundle-app.sh` lines 33-36 bundle `sorter` and `extract` into Rays.app, so the README line about `~/local-scripts/sorter/bin/sorter` is stale. The extension (README line 59: Developer mode, Load unpacked) and `dl` (Homebrew only) are not available to every visitor.
*   ***Proposed Edit:*** Overview cites `bundle-app.sh` for the bundled sorter. The Anywhere passage says "`dl` in Terminal comes with the Homebrew install" and "a browser extension for Chrome and Firefox (developer install for now)". The README edit row also fixes the sorter path.

### [F4] [all Stage 5, `design`, `style`, `comprehension`] - Major: stale version label (Z1, U3, C4)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Drop the version label. The hero bar reads "Rays for macOS 26" with a "Release notes" link to `releases/latest`, and the footer drops the version. Delete `release.ts` and `release.test.ts` from the Files table, and with them the `node --test` step and the build-time network call. "A new release needs no site change" then holds as written.

### [F5] [`zoom-out`, `comprehension`] - Major: hand-written CSP breaks inline styles (Z4, U2)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** The `_headers` row keeps `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin` and immutable cache for `/_astro/*`, and has no CSP. Add one Non-Goal: "No CSP header: the page has no input, cookies or third-party scripts."

### [F6] [`zoom-out`, `inventive-catalyst`] - Major: uncapped jury loop (Z3)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** At most 3 jury rounds. After each round, re-run sloplint and Lighthouse, and reject any jury fix that breaks a performance or a11y gate. If the score is still under 8.0 after round 3, record it and stop.

### [F7] [`design`, `style`, `structural`] - Major: Gatekeeper note scope and README mismatch (C5)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** The note reads: "DMG: on first open, go to System Settings, Privacy & Security, Open Anyway. Homebrew installs skip this." The README edit row adds the same Gatekeeper text and removes the right-click advice.

### [F8] [`design`] - Major: drum fails WCAG 2.2.2 (C6)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** The drum turns through the list once (8 steps, about 14 s) and stops on the first phrase. It does not loop, so no pause control is needed. Build it with CSS `@keyframes` (Z11); it plays once and is off under reduced motion.

### [F9] [`design`] - Major: panel repaints on every scroll frame (C7)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** The gradient sits on a layer 3x the panel height inside the panel (`overflow: clip`). The scroll timeline animates `transform: translateY` on that layer. The grain is a static pre-rendered 256 px tile (`public/grain.png`), not live `feTurbulence`.

### [F10] [`design`] - Major: no integrity check for the DMG (C8)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add a `release.yml` change to the Files table: compute the DMG's SHA-256 and put it in the release notes. The page's "Release notes" link (F4) leads to it.

### [F11] [`design`] - Major: only a subjective metric (C9)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add a goal: record `Rays.dmg` `download_count` from the GitHub releases API on launch day as the baseline, and compare after 30 days. This needs no tracking on the site.

### [F12] [`design`] - Major: missing alternatives (C10)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add two alternatives:
    *   GitHub Pages. Rejected: the subdomain lives in the a6n.ai Cloudflare zone next to the other a6n apps; GitHub Pages would need a CNAME pointing out of Cloudflare and separate TLS.
    *   README only. Rejected: a README cannot hold the visual first impression or a one-click download for non-developers.

### [F13] [`design`, `structural`, `style`, `comprehension`] - Major: stale open questions (C11)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Remove the "Deploy trigger" question, since it is decided (see E1). Restate Domain as "Confirm which Cloudflare account owns the a6n.ai zone; setup step 1 runs there."

### [F14] [`style`] - Major: two a11y gates, undefined throttling (C12)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** One definition, used in both Goals and Quality gates:
    *   Lighthouse mobile preset (Moto G Power emulation, slow 4G throttling), median of 3 runs: LCP < 2.0 s, CLS < 0.05, Accessibility 100;
    *   axe with zero serious or critical issues;
    *   both checked in the dark and light themes.

### [F15] [`style`] - Major: "No front door" overstated (C13)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Heading becomes "No download page". The text says the README has a Download link, but a visitor must find the GitHub repo and read a developer README to reach it.

### [F16] [`comprehension`] - Major: existing scaffold not described (U4)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add an Overview line: "`site/` already holds an unbuilt, never-deployed Astro 7.4.12 scaffold made while drafting this design (package.json, astro.config.mjs, .gitignore, the app icon and the Sorter screenshot)."

### [F17] [`comprehension`, `design`, `style`] - Major: skills and tools undefined (U1, C15)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Add a short "Tools" glossary: each skill is a local Claude Code skill at `~/.claude/skills/<name>/SKILL.md`, with one line on what it checks. Jury's blind critic scores 0-10 on Design, Usability, Creativity and Content. sloplint is hallmark's linter: `node ~/.claude/skills/hallmark/scripts/sloplint.mjs <file> --render`.

### [F18] [`zoom-out`] - Nit: `npm run check` dependencies (Z5, U7)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** The package.json row adds devDependencies `@astrojs/check` and `typescript`, and `check` runs `astro check`.

### [F19] [`inventive-catalyst`, `comprehension`] - Nit: og.png missing on the first deploy (Z12, U9)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Capture `og.png` from `astro preview` locally (agent-browser, a headless browser CLI, at 1200x630) before the first deploy.

### [F20] [`style`, `structural`] - Nits: wording, diagram, labels, tokens (C16-C20, U10)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Slogan headings become literal; drop "calm" and "mixing them weakens both"; "scores low" becomes "expected to score low"; drop "two to three times". Realign the diagram row and use `vX.Y.Z`. Remove the A/B/C letters. Exact tokens: passage 20 px / 1.45, measure 60 ch, hero 32 px. Palette from `scripts/dmg/draw-background.swift` lines 14-15: #FFEDCC, #FFDBD6, #EDE0FA, #D6EBFF; grain at 0.08 opacity. On mobile the band sits above the hero text, not behind it.

### [F21] [`design`] - Nits: phone visitors, hero screen-reader text, image sizes (C21, C22, C24)
*   ***AI Suggestion:*** PROPOSE FIX
*   ***Proposed Edit:*** Under 900 px, a line under the actions reads "Rays runs on Macs with macOS 26." The hero sentence is one element with `aria-label`, and the drum is `aria-hidden`. `width` and `height` are set on both images; the icon gets `fetchpriority="high"`.

## Contested

### [X1] [`design`] - Major: Sorter screenshot may show a home path (C14)
*   ***AI Suggestion:*** CONTEST
*   ***Justification:*** `site/public/sorter.png` shows only the On-device AI row, the wait-time picker, the rename toggle and the folders "Documents" and "Downloads". It shows no path and no account name. Readable evidence: the image file itself.

### [X2] [`design`] - Nit: no clipboard fallback (C23)
*   ***AI Suggestion:*** CONTEST
*   ***Justification:*** The Detailed Implementation `copy.ts` row (outside the reviewer's range) already says: "if the clipboard is blocked, selects the command text instead."

## Declined (recorded, not fixed)

*   Z6/U5: realm undefined. Covered by E1's edit.
*   Z7: move the Skill roles table. F17 explains it instead.
*   Z8: move the screenshot-leak bullet to Goals. It stays as the reason behind the Goals rule.
*   Z10: demo screenshots of the Downloads UI. Skipped unless the jury asks for product proof.
*   U8: exit 0 when the secret is missing. It mirrors the existing cask step in `release.yml`.
*   C25: the Astro pin matches `site/package-lock.json`.
