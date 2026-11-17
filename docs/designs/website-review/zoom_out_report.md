# Stage 5: Initial Zoom Out Review

Target: `docs/designs/website.md` (lines 1-361). Reviewers: egm-zoom-out,
egm-inventive-catalyst (fresh context each). GoldfishContext: `README.md`,
`.github/workflows/release.yml`.

## Combined findings (deduplicated)

| # | Severity | Finding | Raised by | Proposed fix |
|---|---|---|---|---|
| 1 | Major | The version label is fixed at build time, but `site.yml` never runs on a Rays release. The page shows an old version after every tag. The GitHub API call is unauthenticated, so it can be rate-limited and the label then silently disappears. | both | (a) Drop the label and link to `releases/latest` "Release notes"; this removes `release.ts` and its test. (b) Or add `on: workflow_run: [Release]` to `site.yml`, pass `GITHUB_TOKEN`, and fail the build on a fetch error. |
| 2 | Major | The deploy choice (GitHub Action plus a long-lived `Account / Pages / Edit` token, possibly shared with realm) contradicts the doc's own Open Question, which says Git integration needs no token. A shared token can edit every Pages project on the account. Setup step 1 creates a "Direct Upload" project, which cannot be switched to Git integration later. | both | Use Pages Git integration (root `site`, build `npm ci && npm run check && node --test && npm run build`, watch paths `site/**`). Or keep the Action with a separate, narrowly scoped token and state why in the doc. |
| 3 | Major / Nit | The jury gate serves an Awwwards submission that is a Non-Goal. The "fix until 8.0" loop has no cap, and the Lighthouse and a11y gates are not re-run after jury fixes. | both | Cap at 3 rounds or make it advisory. Re-run sloplint and Lighthouse after each jury round and reject fixes that break them. |
| 4 | Major | A hand-written strict CSP in `_headers` cannot know each build's script hashes, and it blocks the inline styles from `inlineStylesheets: 'always'` and the inline SVG. The result is a broken first deploy or a quietly loosened policy. | zoom-out | Drop the CSP and keep `X-Content-Type-Options`, `Referrer-Policy` and the cache rule. Or use Astro's built-in CSP, which hashes each build. |
| 5 | Nit | `npm run check` needs `@astrojs/check` and `typescript`, and neither is listed. | zoom-out | Add both as dev dependencies, or drop `check`. |
| 6 | Nit | The Domain open question is out of date under CI deploy. | zoom-out | Restate it as "confirm which account owns the a6n.ai zone". |
| 7 | Nit | The Skill roles table is process, not architecture. | zoom-out | Move it to Order of work or Quality gates. |
| 8 | Nit | "Screenshots leak private data" limits how the page can be built; it is not a problem the page solves. | zoom-out | Move it to Goals (Truthful content). |
| 9 | Nit | The README says "right-click, Open" for Gatekeeper, which does not work on current macOS; the site says Open Anyway. The README also points to an old sorter path. The Gatekeeper note should say it applies to the DMG only. | both | Fix both README lines in the planned README edit, and add "DMG only" to the hero note. |
| 10 | Nit | Only the Sorter screenshot is safe, so the Downloads UI never appears on a download-manager page. | catalyst | Optional: capture demo screenshots from a throwaway macOS user. Skip unless the page lacks proof. |
| 11 | Nit | The word drum uses JS (an interval, a visibility check and an IntersectionObserver), but the phrase list is fixed at 8. | catalyst | Use CSS `@keyframes` with `rotateX`, off under reduced motion; `copy.ts` is then the only script. |
| 12 | Nit | `og.png` comes from the deployed hero, so the first deploy ships without it and its version text goes stale. | catalyst | Capture it without the version, or after fix 1(a). |

## Verified by reviewers

Copy claims hold up against the code: the bundled sorter and on-device model
(`sorter/src/main.rs`, `AIStatus.swift`), the update notice
(`Updater.swift`), and the stable `Rays.dmg` asset (`release.yml` line 55).

## Not checked by reviewers

Realm's workflows (outside this repo); the claim that Direct Upload cannot be
converted to Git integration; Node 22 `node --test` running `.ts` files; how
the Homebrew cask handles quarantine.
