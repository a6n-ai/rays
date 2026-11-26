# System Settings Style Revamp: Design

**Goal:** "make app like apple setting". Every sidebar page reads like System Settings > Notifications: a hero card, a collapsible Settings card holding that page's own settings, then the page's content in cards. Small coloured tiles everywhere, one tile per concept, calm charts. The Settings window keeps only app-wide items. Behaviour, copy and features stay; settings move but keep their controls and words.

**Inputs:** screenshots in the session scratchpad `revamp/` (downloads, models, sorter, cloud, queues, schedules). `speed.png`, `stats.png` and `shortcuts.png` captured the terminal, not Rays, and `settings-full.png` shows another app's settings, so those pages are specified from code (SpeedPage.swift, StatsPage.swift, ShortcutsPage.swift, SettingsView.swift).

## Hard rules

- Never put `.glassEffect(.regular.interactive())` inside a List row or a Form row. It crashed AppKit row reuse. Non-interactive `.glassEffect(.regular, in: .circle)` on row buttons stays as is.
- Never animate List row diffs (no `withAnimation` around list data, no `.animation(_:value:)` on a List).
- Tiles use `TilePalette` colours only (TilePalette.swift). Never raw `.yellow`, `.cyan`, `.mint`, `.brown` or `Color(nsColor: .darkGray)` for a tile. A white glyph must stay readable on every tile in light and dark mode; TilePalette is chosen for that.
- Native SwiftUI, no new dependencies. Copy keeps its current words; any new string uses no em dashes and no exclamation marks.
- Colour lives in tiles, status dots and chart marks. Titles stay `.primary`, secondary lines `.secondary`.

## Tokens

All go in `LayoutMetrics` (Layout.swift) or `TileSize` (new, Tiles.swift).

| Token | Value |
|---|---|
| `TileSize.sidebar` | 20 |
| `TileSize.menu` | 18 (menu bar panel rows) |
| `TileSize.row` | 22 (card rows, Settings rows) |
| `TileSize.list` | 32 (List rows; equals `LayoutMetrics.iconSize`) |
| `TileSize.hero` | 40 (compact hero) |
| `TileSize.heroLarge` | 64 (centred hero) |
| Tile corner radius | `size * 0.225`, `.continuous` (20 gives 4.5, 22 gives 5, 64 gives 14.4) |
| Tile glyph | `.system(size: (size * 0.44).rounded(), weight: .semibold)`, white, fill `color.gradient`. Sidebar 20 gives 9, row 22 gives 10, list 32 gives 14, hero 40 gives 18, large hero 64 gives 28. Never larger: glyphs need air from the tile edge |
| Card | native `Form` + `.formStyle(.grouped)` sections (radius and padding come from the system) |
| `LayoutMetrics.cardRowMinHeight` | 36 for one line, rows grow for a second line |
| Tile to text gap | 10 |
| Separator inset | starts at the title, past the tile: `.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }` on the title stack |
| Section header | the Form section header (`Section("Title")`), which renders as System Settings' bold header. On List pages: `Text(title).font(.headline)` with `.padding(.top, 4)` |
| `LayoutMetrics.chartHeight` | 160 |
| Content width | Form and List pages fill the pane like System Settings, cards inset by `LayoutMetrics.margin` |

Status dots: `StatusDot` is an 8pt circle before the secondary line.

| Status | Colour |
|---|---|
| `.ok` (done, connected, running, ready) | `TilePalette.green` |
| `.active` (downloading, scheduled soon) | `TilePalette.blue` |
| `.warning` (paused, needs an update, unsaved) | `TilePalette.orange` |
| `.error` (failed, missing, not connected) | `TilePalette.red` |
| `.off` (not scheduled, disabled) | `TilePalette.gray` |

## The concept map: `Tile`

One shared map, in Tiles.swift. Every place that shows a concept uses its `Tile`: sidebar, page hero, Settings rows, menu bar panel rows and Shortcuts rows.

```swift
struct Tile: Hashable { let symbol: String; let color: Color }
extension Tile {
    // Pages (sidebar = hero = menu bar = Shortcuts)
    static let downloads   = Tile(symbol: "arrow.down", color: TilePalette.blue)
    static let models      = Tile(symbol: "cube.fill", color: TilePalette.purple)
    static let sorter      = Tile(symbol: "sparkles", color: TilePalette.pink)
    static let cloud       = Tile(symbol: "cloud.fill", color: TilePalette.sky)
    static let queues      = Tile(symbol: "list.bullet", color: TilePalette.orange)
    static let schedules   = Tile(symbol: "calendar", color: TilePalette.orange)
    static let speed       = Tile(symbol: "gauge.with.dots.needle.67percent", color: TilePalette.teal)
    static let stats       = Tile(symbol: "chart.bar.fill", color: TilePalette.green)
    static let shortcuts   = Tile(symbol: "square.2.layers.3d.fill", color: TilePalette.indigo)
    static let general     = Tile(symbol: "gearshape.fill", color: TilePalette.gray)
    static let browsers    = Tile(symbol: "puzzlepiece.extension.fill", color: TilePalette.indigo)
    // Settings concepts
    static let appearance  = Tile(symbol: "circle.lefthalf.filled", color: TilePalette.gray)
    static let folder      = Tile(symbol: "folder.fill", color: TilePalette.blue)
    static let menuBar     = Tile(symbol: "menubar.arrow.down.rectangle", color: TilePalette.indigo)
    static let clipboard   = Tile(symbol: "doc.on.clipboard", color: TilePalette.teal)
    static let notifications = Tile(symbol: "bell.badge.fill", color: TilePalette.red)
    static let concurrency = Tile(symbol: "square.stack.3d.down.right.fill", color: TilePalette.green)
    static let parts       = Tile(symbol: "point.3.connected.trianglepath.dotted", color: TilePalette.purple)
    static let speedLimit  = Tile(symbol: "hare.fill", color: TilePalette.teal)
    static let duplicates  = Tile(symbol: "doc.on.doc.fill", color: TilePalette.blue)
    static let modelsFolder = Tile(symbol: "shippingbox.fill", color: TilePalette.purple)
    static let commandLine = Tile(symbol: "terminal.fill", color: TilePalette.gray)
    static let updates     = Tile(symbol: "arrow.triangle.2.circlepath", color: TilePalette.blue)
    static let unpack      = Tile(symbol: "archivebox.fill", color: TilePalette.orange)
    static let trash       = Tile(symbol: "trash.fill", color: TilePalette.gray)
    static let wake        = Tile(symbol: "alarm.fill", color: TilePalette.orange)
    static let sortDelay   = Tile(symbol: "timer", color: TilePalette.pink)
    static let rename      = Tile(symbol: "character.cursor.ibeam", color: TilePalette.pink)
    static let watchedFolders = Tile(symbol: "folder.badge.gearshape", color: TilePalette.pink)
    static let warning     = Tile(symbol: "exclamationmark.triangle.fill", color: TilePalette.orange)
    static let localModel  = Tile(symbol: "shippingbox.fill", color: TilePalette.gray)
}
```

Rules: families share a colour (every Sorter setting is pink, every speed concept teal, Queues, Schedules and wake share orange, as in the sidebar since d09587e). `ModelKind.tile`, `QueueAppearance` and `AIReadiness` keep their own data but resolve to TilePalette colours.

### Call sites to sweep (symbol or colour changes)

| File:line | Now | Becomes |
|---|---|---|
| Sidebar.swift:58-80 | `SidebarLabel(_, symbol:, color:)` (no section names, Schedules orange, since d09587e) | `SidebarLabel(_, tile: .downloads ...)`, icon drawn by `IconTile` |
| SpeedCard.swift:9 | SidebarLabel speed | `tile: .speed` |
| SpeedPage.swift:109 | ModelTile teal gauge, raw `.teal` | `HeroCard(.speed, ...)` |
| SpeedPage.swift:247 | ModelTile `.teal` / `.blue` | `IconTile(isTest ? .speed : .downloads, size: TileSize.list)` |
| StatsPage.swift:50 | `chart.bar.xaxis`, `.green` | `HeroCard(.stats, ...)` (symbol changes to `chart.bar.fill`) |
| ShortcutsPage.swift:83 | `square.2.layers.3d`, `.indigo` | `HeroCard(.shortcuts, ...)` (symbol gains `.fill`) |
| ShortcutsPage.swift:99, 120 | tint-coloured glyphs | `IconTile` of the concept the action names |
| MenuBar.swift:223-230 | plain secondary glyphs (`arrow.down.circle`, `wand.and.stars`, `cloud`, `list.bullet.rectangle`, `calendar.badge.clock`, `chart.bar.xaxis`, `square.2.layers.3d`) | `MenuItem(_, tile: .downloads ...)` with `IconTile(size: TileSize.menu)`. Command rows (Add, Pause, Resume, Open, Settings, Quit) keep plain glyphs |
| SettingsView.swift:90 | appearance, `systemGray` | `.appearance` |
| SettingsView.swift:100 | folder, `.blue` | `.folder` |
| SettingsView.swift:120 | menu bar, `.indigo` | `.menuBar` |
| SettingsView.swift:127 | clipboard, `.teal` | `.clipboard` |
| SettingsView.swift:135 | `bell.badge`, `.orange` | `.notifications` (red, `.fill`) |
| SettingsView.swift:199 | concurrency `.green` | `.concurrency` |
| SettingsView.swift:209 | parts `.purple` | `.parts` |
| SettingsView.swift:223 | hare `.orange` | `.speedLimit` (teal) |
| SettingsView.swift:307 | alarm `.red` | `.wake` (orange) |
| BrowsersSettings.swift:10 | puzzle `.indigo` | `.browsers` |
| BrowsersSettings.swift:192 | trash `.gray` | `.trash` |
| CommandLineTool.swift:93 | terminal `darkGray` | `.commandLine` |
| Updater.swift:242 | `.blue` | `.updates` |
| Unpacker.swift:69 | archivebox `.brown` | `.unpack` (orange) |
| Unpacker.swift:76 | trash `.orange` | `.trash` (gray) |
| SortingSettings.swift:18 | timer `.orange` | `.sortDelay` (pink) |
| SortingSettings.swift:33 | rename `.purple` | `.rename` (pink) |
| SortingSettings.swift:45 | `folder.badge.gearshape` `.blue` | `.watchedFolders` (pink) |
| ModelSettingsView.swift:9 | `doc.on.doc` `.blue` | `.duplicates` |
| ModelSettingsView.swift:75 | shippingbox `.indigo` | `.modelsFolder` (purple) |
| SorterView.swift:591 | SettingIcon warning `.orange` | `IconTile(.warning)` |
| SorterFolderPage.swift:147 | SettingIcon folder, category colour | `IconTile(Tile(symbol: "folder.fill", color: color))`, category colours mapped to TilePalette |
| DownloadedModelsView.swift:268 | ModelTile shippingbox `.gray` | `IconTile(.localModel, size: TileSize.list)` |
| ActivityTab.swift:86 | ModelTile `trash` `.gray` | `IconTile(.trash, size: TileSize.list)` |
| ModelCard.swift:16, ModelDetailParts.swift:30, ModelResultsList.swift:106 | `ModelTile(kind:)` | `IconTile(kind.tile, size:)` |
| ModelKind.swift:37-50 | `.mint` (audio), `.yellow` (visionTasks), raw system colours | TilePalette: text blue, vision purple, image pink, video orange, speech green, voice teal, audio sky, embeddings indigo, visionTasks red, other gray |
| QueueAppearance.swift:13, 34-45 | `color(named:)` returns system colours, cycle has `yellow` | returns TilePalette; `"yellow"` replaced by `"sky"` in `cycle`; a stored `"yellow"` renders as sky |
| HelperExplainer.swift:12-34 | raw `.green .blue .orange .gray .indigo .purple` | TilePalette equivalents; step "Rays" uses `.downloads`, "Extension" `.browsers`, "Easy to remove" `.trash` |
| AIStatus.swift:58-65, 95 | raw `.green .blue .red .orange` | TilePalette equivalents |
| ProviderIcon.swift:10 | brand hex colours | keeps brand colours (see Open decisions), drawn by `IconTile` |

## Shared components (Task 1)

Files: new `Tiles.swift` (Tile, TileSize, IconTile, StatusDot) and new `Cards.swift` (HeroCard, CollapsibleSettingsCard, CardRowBackground, ChartCard). `ModelTile` and `SettingIcon` are deleted; their callers move to `IconTile`.

```swift
struct IconTile: View { init(_ tile: Tile, size: CGFloat = TileSize.row) }
struct StatusDot: View { enum Kind { case ok, active, warning, error, off }; init(_ kind: Kind) }
/// Leading tile, bold title, one or two lines of description, optional trailing accessory (a Toggle or Button).
/// `.centered` puts a 64pt tile above a centred title, like System Settings General.
struct HeroCard<Accessory: View>: View {
    enum Style { case compact, centered }
    init(_ tile: Tile, title: String, subtitle: String, caption: String? = nil,
         style: Style = .compact, @ViewBuilder accessory: () -> Accessory = { EmptyView() })
}
/// A Section whose header row is "Settings" plus a chevron. Collapsed by default; the state persists in
/// @AppStorage("settingsCard.<page>"). Toggling never animates (rows are inserted inside a List or Form).
struct CollapsibleSettingsCard<Content: View>: View {
    init(page: String, @ViewBuilder content: () -> Content)
}
/// The card fill for a List row: rounded top on the first row, rounded bottom on the last, hover and
/// selection drawn inside it. A plain shape, never glass. Replaces RowHighlight in card Lists.
struct CardRowBackground: View {
    enum Position { case only, first, middle, last }
    init(_ position: Position, selected: Bool = false, hovered: Bool = false)
    static func position(_ index: Int, of count: Int) -> Position
}
/// A chart inside a card: optional full-width segmented range control, a bold title, the chart.
struct ChartCard<Range: Hashable, Content: View>: View {
    init(_ title: String, range: Binding<Range>? = nil, ranges: [(Range, String)] = [],
         @ViewBuilder chart: () -> Content)
}
```

`SettingRow` (SettingsView.swift, move to Cards.swift) stays the one row component:

```swift
struct SettingRow<Control: View>: View {
    init(_ tile: Tile, title: String, hint: String? = nil, status: StatusDot.Kind? = nil,
         @ViewBuilder control: () -> Control)
}
```

It is an `HStack`, not `LabeledContent`, so it lays out the same inside a Form and a List: `IconTile` (22), title, optional secondary line with a leading `StatusDot`, `Spacer`, trailing control. Trailing controls are native: `Toggle`, `Picker` (menu, shows "Value ⌃⌄"), `Stepper`, a small `Button("Options…")`, a `chevron.right` for drill-in, or an `ellipsis` `Menu`. `SidebarLabel(_ title:, tile:)` draws its icon with `IconTile(tile, size: TileSize.sidebar)`.

Card patterns, all native:
- On Form pages a card is a `Form { Section { } }.formStyle(.grouped)` section. On List pages it is a `Section` whose rows carry `.listRowBackground(CardRowBackground(...))`.
- Footer buttons bottom-right: `Section { } footer: { HStack { Spacer(); Button("Options…") {} } }`.
- Description block with a button (Menu Bar's "Add Controls…"): a row with a `VStack` of text plus `Button`, an optional `IconTile(size: TileSize.hero)` leading.
- Checkbox rows: `Toggle` with `.toggleStyle(.checkbox)` inside a `SettingRow`, so the tile stays.

## Window

Main window height grows, width stays. `RaysApp.swift:16` `.defaultSize(width: 760, height: 720)`; `ContentView.swift:81` `.frame(minWidth: 640, idealWidth: 760, minHeight: 560, idealHeight: 720)`; `sizeWindowOnce` targets 760x720, clamped to the screen's `visibleFrame`, under a new key `windowSized760x720` so current users get the new height once.

## Page structure

Every sidebar page, top to bottom: (a) `HeroCard` with the page's tile (equal to its sidebar tile), (b) `CollapsibleSettingsCard` with that page's own settings, (c) the content in cards. The page's toolbar segment named Settings goes away, since its rows now live in the card. Other segments (Downloads Files, Queues Activity, Speed History, Models Downloaded, Cloud Browse and Downloads, Sorter Files) keep their full height and show no hero: they are alternate views of the page, and their Tables and folder browsers must not be nested.

### Scrolling without nesting a List

Never put a List inside a ScrollView or a Form. One scroll container per page:
- **List pages** (Downloads, Sorter recent, Queues, Schedules, Models search, Cloud buckets): one `List`, `.listStyle(.inset)`. Section 1 is the hero row (`.listRowBackground(Color.clear)`, separator hidden). Section 2 is `CollapsibleSettingsCard`, rows on `CardRowBackground`. Section 3 is the content, rows on `CardRowBackground` with the position from their index in the current page. Paging (`ListControls`, 50 per page) stays outside the List, so a card never holds more than one page of rows.
- **Form pages** (Speed overview, Stats, Shortcuts): one `Form` with `.formStyle(.grouped)`: hero section, settings card, content sections. Charts are fine inside Form rows.
- Collapsing inserts or removes rows, so it runs under `withTransaction(Transaction(animation: nil))`. No `.interactive()` glass anywhere in these rows; row buttons keep non-interactive `.glassEffect(.regular, in: .circle)`.
- Rows keep their hover and selection (now drawn by `CardRowBackground`), `onTapGesture` selection, key handling and context menus.

### Where every setting goes

| Current row (file) | New home |
|---|---|
| Appearance (SettingsView GeneralTab) | Settings window, General |
| Save downloads to (GeneralTab) | Downloads settings card |
| Show in menu bar (GeneralTab) | Settings window, General |
| Offer copied download links (GeneralTab) | Downloads settings card |
| Notify when downloads finish (GeneralTab) | Downloads settings card |
| Command line tool (CommandLineTool `CommandLineSection`) | Settings window, General |
| Updates (Updater `UpdateSettingsSection`) | Settings window, General |
| Uninstall Rays (Uninstaller `UninstallSection`) | Settings window, General, last card |
| Downloads at once, Parts per file, Speed limit (DownloadsTab) | Downloads settings card |
| Unpack archives, Move archive to Trash (Unpacker `UnpackSettingsRows`) | Downloads settings card |
| If a file with the same name exists (ModelSettingsView `ReplaceExistingRow`; hint "Applies to every download") | Downloads settings card |
| Wake permission (SettingsView `WakePermissionRow`) | Schedules settings card |
| Hugging Face token (ModelSettingsView `HuggingFaceTokenSection`, also in DownloadsTab) | Models settings card only |
| AI Models folder (ModelSettingsView) | Models settings card |
| On-device AI status (`AIStatusRow`, SortingTab and Sorter setup) | Settings window, AI card; Sorter settings card keeps a copy because Rename depends on it |
| Sort new files after, Rename files from their content (SortingTab) | Sorter settings card |
| N folders watched (SortingTab) | dropped: the Sorter page lists the folders itself |
| Sorter setup Form (SorterView `.setup`: AI, wait, folders, update rows) | Sorter: settings rows in the card, watched folders as the content card |
| Browser extension, HelperExplainer, per-browser rows, Remove all helpers (BrowsersSettings `BrowsersTab`) | Settings window, Browsers (app-wide: it feeds every download) |
| Add a bucket form, AWS profiles, Cloudflare R2 (CloudSettings `BucketsForm`, Cloud Buckets segment) | Cloud settings card; bucket list becomes the content card |
| Test automatically, data notes (SpeedPage `SpeedSettingsTab`) | Speed settings card |
| Wake setup, default speed limit, When finished (QueueSettingsTab) | Queues settings card |
| Per-queue Options (OptionsTab, QueuePage) | unchanged, on the queue's drill-in page |
| Per-folder Watching, destinations (SorterFolderPage) | unchanged, on the folder drill-in page |

Settings window after the move: `TabView` with General (Appearance, Show in menu bar, Command line tool, Updates, Uninstall), AI (AIStatusRow) and Browsers. General opens with `HeroCard(.general, style: .centered)`; the others with compact heroes. There is no launch at login setting today, so none is added.

### Per page

- **Downloads** (downloads.png): hero `.downloads`, subtitle is the toolbar's status ("All done"). Content card: JobRow keeps its file icon; the status line gains a `StatusDot` (done green, missing red, failed red, paused orange, running blue) in place of the `?` and folder glyphs.
- **Sorter** (sorter.png): hero `.sorter` with "N folders watched". Content: watched folders card, then recent moves card.
- **Models** (models.png): hero `.models`. Search field and chips sit in the hero section's row below the text. "Top models" stays a grid row of ModelCards (non-interactive tinted glass), "More trending" a card of rows with `IconTile(kind.tile, size: TileSize.list)` and chevrons.
- **Cloud** (cloud.png): hero `.cloud`, subtitle bucket count. Bucket rows use `ProviderIcon`, trailing folder and delete. The R2 spinner sits inside a row.
- **Queues** (queues.png): hero `.queues`. Rows: `QueueTile` at 32, `StatusDot(.off)` "Not scheduled", `.active` scheduled; toggle and play unchanged.
- **Schedules** (schedules.png): hero `.schedules`; the empty line becomes the hero subtitle when nothing is scheduled. Upcoming, Paused and Not scheduled are cards; not-scheduled tiles at full opacity with `StatusDot(.off)`.
- **Speed** (from code): hero `.speed` with the live subtitle and "Automatic test" caption; progress bar in the hero section; live chart and Best time in `ChartCard`s; unsaved and error lines as rows with `StatusDot`.
- **Stats** (from code): hero, figures card, `ChartCard("Downloaded per day", range: $days, ranges: [(7, "7 days"), (30, "30 days"), (90, "90 days")])`, Top sites card. No settings card (Stats has no settings).
- **Shortcuts** (from code): hero, Actions card of `SettingRow`s with map tiles and the phrase trailing, steps and ways as card rows. No settings card.
- **Sidebar and menu bar panel**: sidebar moves to `Tile`; the panel's navigation rows show 18pt tiles from the map.

## Chart rules (Speed and Stats)

- Each chart sits in a `ChartCard`: optional range `Picker` with `.pickerStyle(.segmented)`, `.labelsHidden()` and full card width, then the title in `.headline`, then the chart at `LayoutMetrics.chartHeight`.
- One strong colour per chart, the page's tile colour: Stats bars `TilePalette.green`; Speed live line and area `TilePalette.teal` (area at 0.15 opacity); Speed hourly bars `TilePalette.teal`, hours outside the best window the same colour at 0.3 opacity (replaces accent plus `.secondary`).
- Y axis on the trailing side: `AxisMarks(position: .trailing)`, hairline grid lines, labels `.caption .secondary`. Keep existing value formatting (bytes, Mb/s, `%02d` hours).
- Bars get `.cornerRadius(2)`. No legends; the title names the measure.
- No animated chart transitions when the range changes.
- Keep each chart's existing `accessibilityLabel`.

## Decisions

1. Provider brand colours: accepted. ProviderIcon keeps brand hex colours, darkening the light ones (Supabase `0x3ECF8E`, Wasabi `0x3CB04A`, AWS `0xFF9900`) until a white glyph is readable in both modes.
2. Every page gets a hero, including Downloads, Sorter, Queues and Schedules.
