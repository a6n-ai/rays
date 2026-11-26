# Task 6: Speed, Stats and Shortcuts pages

Files: macos/Sources/Rays/SpeedPage.swift, StatsPage.swift, ShortcutsPage.swift.

- Speed: Settings segment removed (SpeedSection is overview, history; a stored "settings" falls back to overview). Overview is a grouped Form: hero section (HeroCard .speed, live subtitle, "Automatic test" caption, progress bar row), CollapsibleSettingsCard(page: "speed") with new SpeedSettingsRows (replaces SpeedSettingsTab; same bindings, copy, confirmation dialog; tiles speed, schedules, trash), unsaved/error rows with StatusDot, live chart and Best time in ChartCards. History rows already used IconTile 32.
- Stats: grouped Form, hero, figures section, ChartCard("Downloaded per day") with 7/30/90 range (always shown so the range can change on an empty range), Top sites section. No settings card. .task(id: days) kept.
- Shortcuts: grouped Form, hero, Actions section of SettingRows (map tiles, phrase trailing), steps, ways. The two tint glyph call sites (lines 99, 120) now use IconTile.
- Charts: one TilePalette colour (Stats green; Speed teal, area 0.15, hourly bars outside best window teal at 0.3), trailing Y axis with hairline grid and caption secondary labels via shared `trailingAxis` helper (in SpeedPage.swift), bars cornerRadius(2), no legends, animation off. Stats chart gained accessibilityLabel "Downloaded per day".

Deviations:
- Worktree was at an older commit; fast-forwarded it to v0127 before starting.
- Shortcuts hero subtitle shortened to "Start downloads and queues from Shortcuts and Siri." so the two-line hero keeps the Learn more link.
- Shortcuts tiles reuse existing map tiles (downloads, queues, speed, clipboard; ways use shortcuts, downloads, browsers, commandLine). No new tiles.
- Steps and ways are plain Form rows (ways use IconTile at 22), not CardRow, since CardRow is List-oriented (lineLimit 1).
- Speed chart Y axis label "Mb/s" moved to the trailing side.

Not done: not launched (per rules); light/dark and relaunch checks left to the reviewer. Build: swift build --package-path macos prints Build complete!.
