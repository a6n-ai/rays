# System Settings Revamp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** "make app like apple setting". Each sidebar page is a hero card, a collapsible Settings card with that page's own settings, then its content in cards. The Settings window keeps only app-wide items. One concept map of tiles everywhere.

**Spec:** `docs/superpowers/specs/2026-11-26-system-settings-revamp-design.md`. Read all of it before any task, especially Hard rules, "Scrolling without nesting a List" and "Where every setting goes".

**Tech stack:** SwiftUI on macOS 26, Swift Charts. App code in `macos/Sources/Rays`.

## Global constraints

- Never use `.glassEffect(.regular.interactive())` inside a List or Form row. Never animate List row diffs; the settings card toggles under `withTransaction(Transaction(animation: nil))`.
- Never put a List inside a ScrollView or Form. One scroll container per page: hero and settings are List sections on List pages, Form sections on Form pages.
- Tiles use `TilePalette` colours only, through the `Tile` map. Glyph size is 44% of the tile size, semibold, white.
- Moved settings keep their controls, bindings, `@AppStorage` keys and copy. New strings use no em dashes and no exclamation marks.
- No new dependencies. Reuse `SettingRow`, `IconTile`, `HeroCard`, `CollapsibleSettingsCard`, `CardRowBackground`, `ChartCard` and `StatusDot`. Do not write per-page copies.
- Verify each task: `swift build --package-path macos` prints Build complete!, then launch the app and check every page the task touched in light and dark mode, with the settings card collapsed and expanded, and after a relaunch (state persists). Run tests only if a task changes logic. None should.
- A page task moves its settings in. Task 7 removes the moved rows from the Settings window, so until then a setting may show in both places.
- Tasks 2 to 6 touch disjoint files and can run in parallel after Task 1. Task 7 runs last.

## Task 1: Foundation

Files: create `Tiles.swift` and `Cards.swift`. Modify `Layout.swift`, `RaysApp.swift` (defaultSize, `sizeWindowOnce`), `ContentView.swift:81`, `ModelKind.swift`, `SettingsView.swift` (`SettingIcon` and `SettingRow` definitions plus the `SettingRow(` call lines), `Sidebar.swift`, `SpeedCard.swift`, `MenuBar.swift`, `QueueAppearance.swift`, `ProviderIcon.swift`, `AIStatus.swift`, `HelperExplainer.swift`, `BrowsersSettings.swift`, `CommandLineTool.swift`, `Updater.swift`, `Unpacker.swift`, `SortingSettings.swift`, `ModelSettingsView.swift`. Also change these single lines: `SorterView.swift:591`, `SorterFolderPage.swift:147`, `DownloadedModelsView.swift:268`, `ActivityTab.swift:86`, `ModelCard.swift:16`, `ModelDetailParts.swift:30`, `ModelResultsList.swift:106`, `SpeedPage.swift:109,247`, `StatsPage.swift:50`, `ShortcutsPage.swift:83`.

- [ ] Add `Tile` (with Schedules and wake orange), `TileSize`, `IconTile` and `StatusDot` to `Tiles.swift`. Add `HeroCard`, `CollapsibleSettingsCard`, `CardRowBackground`, `ChartCard` and `SettingRow` (moved from SettingsView.swift and rebuilt on an `HStack`) to `Cards.swift`. Use the signatures in the spec.
- [ ] Extract settings rows so page tasks only reference them and never edit SettingsView.swift. Give each row in `GeneralTab` and `DownloadsTab` its own non-private struct, keeping its bindings, for example `SaveFolderRow`, `CopiedLinksRow`, `NotifyRow`, `MaxRunningRow`, `PartsRow` and `SpeedLimitRow`. Make `WakePermissionRow` non-private. The tabs compose the new structs, so the Settings window looks the same apart from tiles.
- [ ] Add `cardRowMinHeight = 36` and `chartHeight = 160` to `LayoutMetrics`.
- [ ] Window: set the default size to 760x720 and the minimum height to 560. `sizeWindowOnce` uses the key `windowSized760x720` and clamps to the screen's `visibleFrame`.
- [ ] Delete `SettingIcon` and `ModelTile`. Change `SidebarLabel` to `(_ title:, tile:)`. Add `ModelKind.tile`, and make `color` return `tile.color`. `QueueAppearances.color(named:)` returns TilePalette colours: `"yellow"` becomes `"sky"` in `cycle`, and a stored `"yellow"` renders as sky. `MenuItem` gains `tile: Tile?` for its seven navigation items.
- [ ] Sweep every row of the spec's "Call sites to sweep" table. The hero lines in SpeedPage, StatsPage and ShortcutsPage become `IconTile(..., size: TileSize.hero)` until their page task.
- [ ] ProviderIcon: draw with `IconTile`, and darken the light brand colours (decision 1).
- [ ] Spike, then report the result in the task notes. Build a throwaway Downloads `List` with a hero section, a `CollapsibleSettingsCard` and 50 rows on `CardRowBackground`. Scroll it fast, toggle the card 20 times, and check there is no crash, no row animation and no hover glitch. Delete the spike.
- [ ] Check: `rg -n "ModelTile|SettingIcon|\.mint|\.yellow|\.cyan|\.brown|darkGray" macos/Sources/Rays` finds no tile use. Build.

## Task 2: Downloads page

Files: `DownloadsView.swift`, `JobRow.swift`, `FolderView.swift` (Files segment untouched apart from tiles).

- [ ] Remove the Settings segment from `DownloadsSection`. If `@AppStorage` holds `settings`, it falls back to `recent`.
- [ ] Recent segment: one `List`, laid out as hero `.downloads` (subtitle = current subtitle), then `CollapsibleSettingsCard(page: "downloads")`, then the jobs card.
- [ ] The settings card holds the row structs Task 1 extracted, plus `UnpackSettingsRows` and `ReplaceExistingRow`. Reference them. Do not copy them.
- [ ] JobRow: `CardRowBackground` replaces `RowHighlight` in this list. Add a `StatusDot` per the spec. Keep the file icon, selection, keys and context menu.
- [ ] Scroll 500 jobs over 10 pages. Toggle the card with a selection active.

## Task 3: Sorter and Cloud pages

Files: `SorterView.swift` (excluding line 591), `SortingSettings.swift`, `SorterFolderPage.swift` (tiles only), `CloudSettings.swift`, `BucketView.swift`.

- [ ] Sorter: remove the Setup segment. The Recent segment becomes one List: hero `.sorter`, then `CollapsibleSettingsCard(page: "sorter")` with AIStatusRow, Sort new files after, Rename files from their content and the wait setting, then the watched folders card (with its update warning row), then the recent moves card.
- [ ] Cloud: remove the Buckets segment. The Browse segment's first view becomes one List: hero `.cloud`, then `CollapsibleSettingsCard(page: "cloud")` with the add-bucket form, AWS profiles and Cloudflare R2 rows, then the buckets card. The R2 spinner sits inside a row. If keeping the Browse Table means it cannot share this List, the hero, settings and buckets go in a Form above it as the default view, and Browse stays a segment. Say which one you chose.
- [ ] Check text fields in List rows (bucket name, keys) for focus and typing.

## Task 4: Queues and Schedules pages

Files: `QueuesPage.swift`, `QueueListTab.swift`, `QueueSettingsTab.swift`, `SchedulesPage.swift`, `ScheduleTab.swift`, `QueuePage.swift`, `QueueHeader.swift`, `ActivityTab.swift` (excluding line 86).

- [ ] Queues: remove the Settings segment. The Queues segment becomes one List: hero `.queues`, then `CollapsibleSettingsCard(page: "queues")` with the `QueueSettingsTab` rows (wake setup, default speed limit, When finished), then the queues card. Rows show `QueueTile` at 32 and a `StatusDot`.
- [ ] Schedules: one List, laid out as hero `.schedules`, then `CollapsibleSettingsCard(page: "schedules")` with `WakePermissionRow`, then the Upcoming, Paused and Not scheduled cards. When the list is empty, the empty-state copy is the hero subtitle.
- [ ] Queue drill-in pages keep their Options, and get a compact hero with the queue's tile.

## Task 5: Models page

Files: `ModelsView.swift`, `ModelResultsList.swift` (excluding line 106), `ModelCard.swift` (excluding line 16), `ModelDetailView.swift`, `ModelDetailParts.swift` (excluding line 30), `DownloadedModelsView.swift` (excluding line 268), `ModelSettingsView.swift`, `SearchView.swift`.

- [ ] Remove the Settings segment. The Search segment becomes one List: hero `.models` with the search field and chips, then `CollapsibleSettingsCard(page: "models")` with AI Models folder and `HuggingFaceTokenSection`'s rows, then Top models (grid row) and More trending (card of rows with `IconTile(kind.tile, size: TileSize.list)` and a chevron).
- [ ] Model detail: a compact `HeroCard(kind.tile, ...)` replaces the 56pt tile row.
- [ ] Check that the search field keeps focus while results reload, and that the list does not animate.

## Task 6: Speed, Stats and Shortcuts pages

Files: `SpeedPage.swift`, `StatsPage.swift`, `ShortcutsPage.swift`.

- [ ] Speed: remove the Settings segment. The Overview segment becomes a grouped Form: `HeroCard(.speed, ...)` with the progress bar, then `CollapsibleSettingsCard(page: "speed")` with the `SpeedSettingsTab` rows, then the live chart and Best time in `ChartCard`s. The History List rows get `IconTile` at 32.
- [ ] Stats: a grouped Form with a hero, a figures card, `ChartCard` with the 7, 30 and 90 day range, and a Top sites card. It has no settings card. Keep `.task(id: days)`.
- [ ] Shortcuts: a grouped Form with a hero, an Actions card of `SettingRow`s with map tiles and the phrase trailing, and the steps and ways as card rows. It has no settings card.
- [ ] Charts follow the spec's chart rules.

## Task 7: Remove the Settings window; app-wide settings become sidebar pages

Changed 2026-11-26: the user chose to remove the separate Settings window, the way System Settings keeps everything in one window.

- [ ] Add a last sidebar group, separated by spacing, with three pages built on HeroCard and cards:
  - **General** (`Tile.general`, gray, gearshape): appearance, menu bar, updates and the command-line tool.
  - **AI** (`Tile.ai`): AI status and the model settings that SettingsView's AI tab held.
  - **Browsers** (`Tile.browsers`): the BrowsersTab content.
  Add `Destination.general`, `.ai` and `.browsers`.
- [ ] Delete the `Settings { }` scene and SettingsView's TabView. ⌘, and the app menu's "Settings…" select `.general` in the main window, bringing it forward. Every `openSettings` call and every `SettingsToolbarButton` selects the matching page instead: `settingsTab = "browsers"` goes to `.browsers`, and so on. Grep `openSettings`, `settingsTab` and `SettingsToolbarButton`, and fix every caller, including `RaysApp.swift`'s `open urls` and the menu bar panel.
- [ ] The Home page card 4 "Settings" row becomes "General".
- [ ] Remove dead code: the TabView and any tab that is now empty. The rows extracted in Task 1 stay, because pages use them.
- [ ] **Theme, on the General page** (user 2026-11-26: "give option to change theme"), modelled on System Settings > Appearance:
  - Appearance: Auto, Light, Dark as three picture tiles in a row, each a small window thumbnail drawn in SwiftUI with a label under it and a selection ring. This reuses the existing `AppearanceChoice` and its `appearance` key.
  - Accent colour: a row of round swatches. "Multicolour" follows the system; the others are blue, purple, pink, red, orange, yellow, green and graphite, from `TilePalette` where it has the colour. Store the choice in `@AppStorage("accentChoice")` and apply it app-wide with `.tint()` on the main window's root and the menu bar panel. The selected swatch shows a ring, and its name appears under the row.
  - Sidebar icon size: Small, Medium, Large as an inline radio group, like System Settings. It scales `TileSize.sidebar` to 16, 20 or 24 and the sidebar text with it.
  - Tiles keep their own colours. The accent colour changes only controls, selection and links.
- [ ] `swift build`, then check by hand that ⌘, opens General and that the menu bar panel's settings link still works.

## Task 8: Home page (like System Settings > General)

Added 2026-11-26 from the user's General reference. Runs after Task 1, in parallel with Tasks 2 to 6.

Files: new `macos/Sources/Rays/HomePage.swift`; `ContentView.swift` (route `.home`, make it the default selection on first launch).

- [ ] The centred HeroCard: the Rays app icon at 64pt, "Rays", and "Downloads files fast, sorts them, and runs them on your schedule." with a Learn more… link to rays.a6n.ai/docs.
- [ ] Grouped cards of drill-in rows, each a 22pt tile from the `Tile` map, a title and a › chevron, that select the matching sidebar destination:
  - Card 1: Downloads, Models, Sorter, Cloud.
  - Card 2: Queues, Schedules.
  - Card 3: Speed test, Stats, Shortcuts.
  - Card 4: Settings, which opens the Settings window; About Rays, showing the version and an updates status line; Docs, which opens the website.
- [ ] Each row may show a secondary subtitle with live state, for example "3 downloading", "2 queues running", "Last test 79 Mb/s" or "Up to date".
- [ ] `swift build` passes; take a screenshot.
