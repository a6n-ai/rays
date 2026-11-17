# Stage 6: Comprehension Test

Target: `docs/designs/website.md`. FeatureRange 1-273, DetailedRange 274-361.
Reviewer: egm-comprehension (fresh context, document only).

## What this proposes

The design adds a one-page static marketing site for Rays at `rays.a6n.ai`,
built with Astro and served from Cloudflare Pages. The page is dark, with a
single text column on the left. A sticky grainy-gradient panel on the right
changes colour as the page scrolls; the layout copies superlogical.com. The
hero has a rotating 3D "word drum" that names the kinds of files Rays sorts.
It is the only place with the two install actions: the GitHub `latest` DMG
link and a copyable `brew install --cask` command, plus a one-line
Gatekeeper note. Four short passages follow (Downloads, Sorting, Private,
Anywhere), then a footer. A GitHub Action deploys `site/dist` to a Direct
Upload Pages project with wrangler, using a Cloudflare API token stored as a
GitHub secret. The page must pass sloplint, an impeccable audit, Lighthouse
and a jury score of 8.0 or higher before any Awwwards submission.

## How the existing system works, per this document

Rays is a free, open-source macOS 26 download manager. It downloads each
file in several parts at once. Its sorter uses Apple's on-device model to
move new files from Downloads (and any folder the user adds) into fitting
folders. It also has a browser extension and a `dl` Terminal command. It
ships as an unnotarized DMG on GitHub releases and as a Homebrew cask, so
opening the DMG the first time triggers a Gatekeeper block. Today its only
public page is the GitHub README. Real screenshots leak private file names;
only the Sorter setup screen is clean. A separate agency site, a6n.ai
("aether"), already exists. The Files table shows that a `site/` scaffold
already exists (`package.json` with a `deploy` script, `astro.config.mjs`,
`.gitignore`, images), but the prose never says so.

## Findings

| # | Severity | Scope | Finding |
|---|---|---|---|
| 1 | Major | Skill roles, Goals, Quality gates, Order of work | The skills and tools named (`hallmark`, `ui-ux-pro-max`, `impeccable`, `apple-design`, `stageshow`, `awwwards`, `animate`, `jury`, `sloplint.mjs`, "blind critic") are never defined or linked. "Jury 8.0" gives no scale and no owner. A new reader cannot tell what each gate checks or how it passes. |
| 2 | Major | `inlineStylesheets: 'always'` vs `_headers` CSP; Panel CSS | The `style-src` and `script-src` policy is not spelled out, and it is not said how the script hashes get into a static `_headers` file. A reader cannot tell whether the page will render. |
| 3 | Major | Build and deploy flow vs `site.yml` trigger | The doc says a "new release needs no site change", but the version label goes stale until someone rebuilds. Who triggers the rebuild, or whether the stale label is accepted, is not stated. What the bar shows when the label is left out is also not stated. |
| 4 | Major | Overview vs Files table | The existing `site/` scaffold is never described in the prose; a reader finds it only in the table. |
| 5 | Nit | Setup step 4 | "realm" is undefined, and it is unclear whether sharing its token is safe. |
| 6 | Nit | Open Questions vs Detailed Implementation | The chosen deploy option (Action plus token) is not among the two options listed, and no reason is given. The Domain question refers to a laptop login that no longer matters. |
| 7 | Nit | `release.test.ts`, `node --test`, `check` | Not stated: how Node 22 runs `.ts` tests, how a failed fetch is simulated, and what `check` runs. |
| 8 | Nit | `site.yml` | When the secret is missing, the job "exits 0", which makes a skipped deploy look green. No reason is given. |
| 9 | Nit | `og.png` vs Order of work | The first deploy references an `og.png` that does not exist yet. `agent-browser` is undefined. |
| 10 | Nit | Sticky panel, mobile layout | "DMG palette" has no hex values or source file. It is not said how hero text stays readable over the 30 vh mobile band. |
