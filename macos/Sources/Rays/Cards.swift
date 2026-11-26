import SwiftUI

/// Leading 28pt tile, semibold title, a description of up to two lines with an optional inline "Learn more…"
/// link, optional trailing accessory (a Toggle or Button).
/// `.centered` puts a 64pt tile above a centred title, like System Settings General.
/// `.home` is the Home page's hero: the Rays app icon at 64pt, a title2 bold title, a centred description.
struct HeroCard<Accessory: View>: View {
    enum Style { case compact, centered, home }

    let tile: Tile
    let title: String
    let subtitle: String
    let caption: String?
    let learnMore: URL?
    let style: Style
    let accessory: Accessory

    init(_ tile: Tile, title: String, subtitle: String, caption: String? = nil, learnMore: URL? = nil,
         style: Style = .compact, @ViewBuilder accessory: () -> Accessory) {
        self.tile = tile
        self.title = title
        self.subtitle = subtitle
        self.caption = caption
        self.learnMore = learnMore
        self.style = style
        self.accessory = accessory()
    }

    var body: some View {
        switch style {
        case .compact:
            HStack(spacing: LayoutMetrics.gap) {
                IconTile(tile, size: TileSize.hero)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    texts(alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                accessory
            }
            .padding(.vertical, 10)
        case .centered, .home:
            VStack(spacing: 6) {
                if style == .home {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: TileSize.heroLarge, height: TileSize.heroLarge)
                        .accessibilityHidden(true)
                } else {
                    IconTile(tile, size: TileSize.heroLarge)
                }
                Text(title).font(.title2.bold())
                texts(alignment: .center).multilineTextAlignment(.center)
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }

    private var description: Text {
        var text = AttributedString(subtitle)
        text.foregroundColor = .secondary
        if let learnMore {
            var link = AttributedString("Learn more…")
            link.link = learnMore
            link.foregroundColor = .accentColor
            text += AttributedString(" ") + link
        }
        return Text(text)
    }

    private func texts(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            description.font(.callout).lineLimit(2)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

extension HeroCard where Accessory == EmptyView {
    init(_ tile: Tile, title: String, subtitle: String, caption: String? = nil, learnMore: URL? = nil,
         style: Style = .compact) {
        self.init(tile, title: title, subtitle: subtitle, caption: caption, learnMore: learnMore, style: style) { EmptyView() }
    }
}

/// The first row of the settings card: a gray gear tile, "Settings", a one-line summary and a chevron that turns
/// when open. Collapsed by default; the state persists in @AppStorage("settingsCard.<page>"). Its content rows follow
/// in the same card (`.middle` and `.last` in a List; a Form draws its own card). Toggling never animates.
struct CollapsibleSettingsCard<Content: View>: View {
    @AppStorage private var expanded: Bool
    private let summary: String?
    private let inForm: Bool
    private let content: Content

    init(page: String, summary: String? = nil, startsOpen: Bool = false, inForm: Bool = false,
         @ViewBuilder content: () -> Content) {
        _expanded = AppStorage(wrappedValue: startsOpen, "settingsCard.\(page)")
        self.summary = summary
        self.inForm = inForm
        self.content = content()
    }

    var body: some View {
        Section {
            if inForm { header } else { header.cardRow(expanded ? .first : .only, separatorInset: TileSize.row + 10) }
            if expanded { content }
        }
        .transaction { $0.animation = nil }
    }

    private var header: some View {
        Button {
            withTransaction(Transaction(animation: nil)) { expanded.toggle() }
        } label: {
            HStack(spacing: 10) {
                IconTile(.general, size: TileSize.row)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Settings")
                    if let summary { Text(summary).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .frame(minHeight: summary == nil ? LayoutMetrics.cardRowMinHeight : LayoutMetrics.cardListRowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "Expanded" : "Collapsed")
    }
}

/// The card fill for a List row: rounded top on the first row, rounded bottom on the last, hover and
/// selection drawn inside it. A plain shape, never glass. Replaces RowHighlight in card Lists.
struct CardRowBackground: View {
    enum Position { case only, first, middle, last }

    let position: Position
    let selected: Bool
    let hovered: Bool

    init(_ position: Position, selected: Bool = false, hovered: Bool = false) {
        self.position = position
        self.selected = selected
        self.hovered = hovered
    }

    static func position(_ index: Int, of count: Int) -> Position {
        switch (index == 0, index == count - 1) {
        case (true, true): .only
        case (true, false): .first
        case (false, true): .last
        case (false, false): .middle
        }
    }

    private var shape: UnevenRoundedRectangle {
        let r: CGFloat = 10
        let top = position == .only || position == .first ? r : 0
        let bottom = position == .only || position == .last ? r : 0
        return UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: bottom,
                                      bottomTrailingRadius: bottom, topTrailingRadius: top, style: .continuous)
    }

    var body: some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay {
                if selected {
                    shape.fill(Color.accentColor.opacity(0.18))
                } else if hovered {
                    shape.fill(Color.primary.opacity(0.06))
                }
            }
            .padding(.horizontal, LayoutMetrics.margin)
    }
}

/// The one List row of every card list (Downloads, queues, buckets, models, recent moves), after System
/// Settings > Notifications > "Application Notifications": 32pt leading icon, body title, secondary one-line
/// subtitle (optional status dot), trailing chevron or controls, about 52pt tall. The separator starts at the title.
struct CardRow<Leading: View, Trailing: View>: View {
    let title: String
    let subtitle: String?
    let status: StatusDot.Kind?
    let leading: Leading
    let trailing: Trailing

    init(title: String, subtitle: String? = nil, status: StatusDot.Kind? = nil,
         @ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.status = status
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            leading.frame(width: TileSize.list, height: TileSize.list)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    HStack(spacing: 6) {
                        if let status { StatusDot(status) }
                        Text(subtitle).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 8)
            trailing
        }
        .frame(minHeight: subtitle == nil ? LayoutMetrics.cardRowMinHeight : LayoutMetrics.cardListRowHeight)
        .contentShape(.rect)
    }
}

extension CardRow where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, status: StatusDot.Kind? = nil, @ViewBuilder leading: () -> Leading) {
        self.init(title: title, subtitle: subtitle, status: status, leading: leading) { EmptyView() }
    }
}

/// The drill-in chevron for a CardRow's trailing slot.
struct CardChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
    }
}

extension View {
    /// Puts a List row in the shared card: fill and corners from `CardRowBackground`, and a hairline drawn inside
    /// the row (the system separator ignores the card edge), inset past the 32pt icon, none under the last row.
    /// Never glass, never per-row.
    func cardRow(_ position: CardRowBackground.Position, selected: Bool = false, hovered: Bool = false,
                 separatorInset: CGFloat = TileSize.list + 10) -> some View {
        let last = position == .last || position == .only
        return self
            .overlay(alignment: .bottom) {
                if !last {
                    Rectangle().fill(.separator).frame(height: 1 / 2)
                        .padding(.leading, separatorInset).padding(.trailing, -12)
                }
            }
            .listRowBackground(CardRowBackground(position, selected: selected, hovered: hovered))
            // The inset list style adds 16pt a side, so this puts content 12pt inside the card edge.
            .listRowInsets(EdgeInsets(top: 0, leading: LayoutMetrics.margin - 4, bottom: 0, trailing: LayoutMetrics.margin - 4))
            .listRowSeparator(.hidden)
    }
}

/// A chart inside a card: optional full-width segmented range control, a bold title, the chart.
struct ChartCard<Range: Hashable, Content: View>: View {
    let title: String
    let range: Binding<Range>?
    let ranges: [(Range, String)]
    let chart: Content

    init(_ title: String, range: Binding<Range>? = nil, ranges: [(Range, String)] = [],
         @ViewBuilder chart: () -> Content) {
        self.title = title
        self.range = range
        self.ranges = ranges
        self.chart = chart()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let range {
                Picker(title, selection: range) {
                    ForEach(ranges, id: \.0) { Text($0.1).tag($0.0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            Text(title).font(.headline)
            chart.frame(height: LayoutMetrics.chartHeight)
        }
        .padding(.vertical, 4)
    }
}

/// One settings row: optional tile, title, optional secondary line (with a status dot), trailing control.
/// An HStack, not LabeledContent, so it lays out the same inside a Form and a List.
struct SettingRow<Control: View>: View {
    let tile: Tile?
    let title: String
    let hint: String?
    let status: StatusDot.Kind?
    let control: Control

    /// Plain settings rows have no tile; only rows that stand for a thing pass one.
    init(_ tile: Tile? = nil, title: String, hint: String? = nil, status: StatusDot.Kind? = nil,
         @ViewBuilder control: () -> Control) {
        self.tile = tile
        self.title = title
        self.hint = hint
        self.status = status
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 10) {
            if let tile { IconTile(tile, size: TileSize.row) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let hint {
                    HStack(spacing: 6) {
                        if let status { StatusDot(status) }
                        Text(hint)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: LayoutMetrics.gap)
            control
                .controlSize(.small)
                .toggleStyle(SettingSwitchStyle())
        }
        .frame(minHeight: LayoutMetrics.cardRowMinHeight)
    }
}
