import AppKit
import UserNotifications
import Observation
import SwiftUI

extension EngineModel {
    var activeJobs: [JobView] { jobs.filter(\.isActive) }

    /// Bytes done over bytes expected across running downloads with a known size; nil when none has one.
    var overallProgress: Double? {
        let sized = activeJobs.compactMap { job in job.total.map { (job.done, $0) } }
        let total = sized.reduce(UInt64(0)) { $0 + $1.1 }
        guard total > 0 else { return nil }
        return Double(sized.reduce(UInt64(0)) { $0 + min($1.0, $1.1) }) / Double(total)
    }

    var totalSpeed: UInt64 { activeJobs.reduce(0) { $0 + $1.bytesPerSec } }
}

/// The Dock icon shows a progress bar and the number of running downloads while anything downloads.
/// The same signal holds a user-initiated activity: without it, App Nap throttles the engine's threads
/// once the window is hidden, and downloads slow down in the background.
@MainActor
final class DockProgress {
    private let model: EngineModel
    private var shown: (Int, Int, String)?
    private var askedBadge = false
    private var activity: NSObjectProtocol?
    private lazy var view = NSHostingView(rootView: DockTile(progress: nil, speed: nil))

    init(model: EngineModel) {
        self.model = model
        track()
    }

    /// Re-arms on every change it reads, so the Dock updates only when the job list changes (no timer).
    private func track() {
        withObservationTracking {
            update()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private func update() {
        let count = model.activeJobs.count
        let progress = model.overallProgress
        // macOS shows Dock badges only for apps allowed badges in Notifications settings; ask once.
        if count > 0, !askedBadge {
            askedBadge = true
            UNUserNotificationCenter.current().requestAuthorization(options: [.badge]) { _, _ in }
        }
        if count > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading files")
        } else if count == 0, let running = activity {
            ProcessInfo.processInfo.endActivity(running)
            activity = nil
        }
        // Redrawing the Dock costs a little, so only whole-percent changes do.
        let speed = count > 0 && model.totalSpeed > 0 ? "\(byteText(model.totalSpeed))/s" : ""
        let key = (count, progress.map { Int($0 * 100) } ?? -1, speed)
        guard shown.map({ $0 != key }) ?? true else { return }
        shown = key
        let tile = NSApp.dockTile
        tile.badgeLabel = count > 0 ? "\(count)" : nil
        if count > 0 {
            view.rootView = DockTile(progress: progress, speed: speed.isEmpty ? nil : speed)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

private struct DockTile: View {
    let progress: Double?
    let speed: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage).resizable()
            if let speed {
                // Above the progress bar: the Dock's own count badge takes the top right.
                Text(speed)
                    .font(.system(size: 16, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(.horizontal, 18)
                    .padding(.bottom, progress == nil ? 10 : 28)
            }
            if let progress {
                Capsule()
                    .fill(.black.opacity(0.55))
                    .frame(height: 14)
                    .overlay(alignment: .leading) {
                        GeometryReader { geo in
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: max(14, geo.size.width * progress))
                        }
                        .padding(2)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// The menu bar icon: Rays' own icon, with the overall percent while downloading when sizes are known.
struct MenuBarLabel: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            // Original, or the menu bar draws the badge as a template and the red is lost.
            Image(nsImage: model.activeJobs.isEmpty ? Self.icon : Self.icon(badge: model.activeJobs.count))
                .renderingMode(model.activeJobs.isEmpty ? .template : .original)
            if !model.activeJobs.isEmpty {
                if model.totalSpeed > 0 {
                    Text("\(byteText(model.totalSpeed))/s").monospacedDigit()
                } else if let progress = model.overallProgress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }
        }
        .accessibilityLabel(model.activeJobs.isEmpty ? "Rays" : "Rays, \(model.activeJobs.count) downloading")
        // The label outlives the window, so it can reopen it for a request that arrives while the window is closed.
        .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in openWindow(id: "main") }
    }

    /// The stacked pages from Rays' icon as a template image, so the menu bar draws it white or black to match.
    /// Same geometry as the icon's page SVGs (1024 space, pages at 416 to 608, scale 1.18), cropped to the stack.
    static let icon: NSImage = icon(badge: 0)

    /// With a count, a red badge with the number of downloads at the top right. A template image can't keep the red,
    /// so the pages are drawn in the menu bar's label color instead, read when the image is drawn.
    static func icon(badge: Int) -> NSImage {
        let box = CGRect(x: 216, y: 156, width: 592, height: 712)
        let height: CGFloat = 17
        let scale = height / box.height
        let label = badge > 9 ? "9+" : "\(badge)"
        let font = NSFont.systemFont(ofSize: 8, weight: .bold)
        let text = NSAttributedString(string: label, attributes: [.font: font, .foregroundColor: NSColor.white])
        let dot = NSSize(width: max(10, text.size().width + 5), height: 10)
        let pages = (box.width * scale).rounded(.up)
        let width = badge > 0 ? pages + dot.width / 2 : pages
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (offset, alpha) in [(416.0, 0.35), (480.0, 0.55), (544.0, 0.75), (608.0, 1.0)] {
                let page = NSBezierPath()
                page.move(to: NSPoint(x: -130, y: -220))
                page.line(to: NSPoint(x: 70, y: -220))
                page.line(to: NSPoint(x: 170, y: -120))
                page.line(to: NSPoint(x: 170, y: 190))
                page.curve(to: NSPoint(x: 140, y: 220), controlPoint1: NSPoint(x: 170, y: 207), controlPoint2: NSPoint(x: 157, y: 220))
                page.line(to: NSPoint(x: -130, y: 220))
                page.curve(to: NSPoint(x: -170, y: 190), controlPoint1: NSPoint(x: -152, y: 220), controlPoint2: NSPoint(x: -170, y: 207))
                page.line(to: NSPoint(x: -170, y: -190))
                page.curve(to: NSPoint(x: -130, y: -220), controlPoint1: NSPoint(x: -170, y: -207), controlPoint2: NSPoint(x: -152, y: -220))
                page.close()
                var transform = AffineTransform(scale: scale)
                transform.translate(x: offset - box.minX, y: offset - box.minY)
                transform.scale(1.18)
                page.transform(using: transform)
                (badge > 0 ? NSColor.labelColor : NSColor.black).withAlphaComponent(alpha).setFill()
                page.fill()
            }
            if badge > 0 {
                let rect = NSRect(x: width - dot.width, y: 0, width: dot.width, height: dot.height)
                NSColor.systemRed.setFill()
                NSBezierPath(roundedRect: rect, xRadius: dot.height / 2, yRadius: dot.height / 2).fill()
                let size = text.size()
                text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
            }
            return true
        }
        image.isTemplate = badge == 0
        image.accessibilityDescription = "Rays"
        return image
    }
}

/// The menu bar panel: add a download, what is downloading, and the rest of Rays one click away.
struct MenuBarPanel: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var link = ""
    /// Clear hides what is listed now from this panel only; ids grow, so newer downloads show again.
    @AppStorage("menuBarClearedID") private var clearedID = 0

    /// The latest four: running ones first, then the newest others not cleared.
    private var recent: [JobView] {
        let rest = model.jobs.filter { !$0.isActive && $0.id > UInt64(clearedID) }.reversed()
        return Array((model.activeJobs + rest).prefix(4))
    }
    private var paused: [JobView] { model.jobs.filter { $0.state == .paused } }
    private var typedLinks: [String] { Links.inText(link) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            addRow.padding(.horizontal, 14).padding(.bottom, 10)
            Divider()
            downloads.padding(.horizontal, 6).padding(.vertical, 6)
            Divider()
            VStack(spacing: 0) {
                MenuItem("Add Links from a File…", symbol: "doc.badge.plus", action: addFromFile)
                MenuItem("Download Link from Clipboard", symbol: "doc.on.clipboard", action: addFromClipboard)
                if !model.activeJobs.isEmpty {
                    MenuItem("Pause All", symbol: "pause.circle") { model.pauseAll() }
                } else if !paused.isEmpty {
                    MenuItem("Resume All", symbol: "play.circle") { model.resumeAll() }
                }
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                MenuItem("Downloads", tile: .downloads) { show(.openDownloads) }
                MenuItem("Sorter", tile: .sorter) { show(.openSorter) }
                MenuItem("Cloud", tile: .cloud) { show(.openCloud) }
                MenuItem("Queues", tile: .queues) { go(.queues) }
                MenuItem("Schedules", tile: .schedules) { go(.schedules) }
                MenuItem("Speed test", tile: .speed) { go(.speed) }
                MenuItem("Stats", tile: .stats) { go(.stats) }
                MenuItem("Shortcuts", tile: .shortcuts) { go(.shortcuts) }
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                MenuItem("Open Rays", symbol: "macwindow") { show(nil) }
                MenuItem("Settings…", symbol: "gearshape") { model.show(.general, openWindow: openWindow) }
                MenuItem("Quit Rays", symbol: "power", shortcut: "⌘Q") { NSApp.terminate(nil) }
            }
            .padding(6)
        }
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 22, height: 22).accessibilityHidden(true)
            Text("Rays").font(.headline)
            Spacer()
            if !model.activeJobs.isEmpty {
                Text("\(model.activeJobs.count) downloading · \(byteText(model.totalSpeed))/s")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var addRow: some View {
        HStack(spacing: 6) {
            addMenu
            TextField("Paste a link", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTyped)
            Button("Download", action: addTyped)
                .buttonStyle(.borderedProminent)
                .disabled(typedLinks.isEmpty)
        }
    }

    @ViewBuilder private var downloads: some View {
        if recent.isEmpty {
            Text("No downloads yet.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 0) {
                ForEach(recent, id: \.id) { job in MenuBarRow(job: job) }
            }
        }
        HStack {
            Button("See all in Rays") { show(.openDownloads) }
            Spacer()
            Button("Clear") { clearedID = Int(model.jobs.map(\.id).max() ?? 0) }
                .disabled(recent.allSatisfy(\.isActive))
                .help("Hide these downloads from this menu. They stay in Rays.")
        }
        .buttonStyle(.link)
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func addTyped() {
        guard !typedLinks.isEmpty else { return }
        model.add(typedLinks.joined(separator: "\n"))
        link = ""
    }

    // A click is a paste, so reading the clipboard here never shows macOS's paste alert.
    private func addFromClipboard() {
        let links = Links.inText(NSPasteboard.general.string(forType: .string) ?? "")
        if links.isEmpty { return NSSound.beep() }
        model.add(links.joined(separator: "\n"))
    }

    /// Text, CSV or .webloc files: every link in them is added.
    private func addFromFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .commaSeparatedText, .internetLocation, .url]
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        let links = panel.urls.flatMap { url -> [String] in
            if let one = Links.fromFile(url), url.pathExtension == "webloc" { return [one] }
            return Links.inText((try? String(contentsOf: url, encoding: .utf8)) ?? "")
        }
        if links.isEmpty { return NSSound.beep() }
        model.add(links.joined(separator: "\n"))
    }

    /// Opens the window, at a sidebar page when given, and puts Rays back in the Dock if it was hidden there.
    /// What the main add bar's + menu offers; each opens Rays with the typed link where it applies.
    private var addMenu: some View {
        Menu {
            Section("Add") {
                Button("Find links on a page…", systemImage: "doc.text.magnifyingglass") {
                    let page = typedLinks.count == 1 ? typedLinks[0] : nil
                    open { if let page { model.requestedGrab = page } }
                }
                Button("From a cloud bucket…", systemImage: "cloud") { go(.cloud) }
                Button("Hugging Face model…", systemImage: "cube") { go(.models) }
            }
            Section("With the link") {
                Button("Add a checksum…", systemImage: "checkmark.shield") { withLink(.checksum) }
                Button("Add a mirror…", systemImage: "square.on.square") { withLink(.mirror) }
                Button("Add headers…", systemImage: "key") { withLink(.headers) }
            }
        } label: {
            Image(systemName: "plus.circle").font(.system(size: 15, weight: .semibold)).foregroundStyle(.tint)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More ways to add")
        .accessibilityLabel("More ways to add")
    }

    private func withLink(_ kind: LinkExtra) {
        let typed = typedLinks.joined(separator: "\n")
        link = ""
        open {
            if !typed.isEmpty { model.pendingAdd = typed }
            model.requestedExtra = kind
        }
    }

    private func go(_ destination: Destination) { open { model.requestedDestination = destination } }

    /// Opens the main window on Downloads, then runs `then` once its views are listening.
    private func open(then: @escaping () -> Void) {
        show(.openDownloads)
        DispatchQueue.main.async { DispatchQueue.main.async(execute: then) }
    }

    private func show(_ page: Notification.Name?) {
        AppDelegate.showInDock()
        openWindow(id: "main")
        if let page {
            // After the window exists, so its view is listening.
            DispatchQueue.main.async { NotificationCenter.default.post(name: page, object: nil) }
        }
    }
}

/// A row that highlights on hover, like a menu item.
private struct MenuItem: View {
    let title: String
    let symbol: String
    var tile: Tile?
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    init(_ title: String, tile: Tile, action: @escaping () -> Void) {
        self.title = title
        self.symbol = tile.symbol
        self.tile = tile
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let tile {
                    IconTile(tile, size: TileSize.menu)
                } else {
                    Image(systemName: symbol).frame(width: 18).foregroundStyle(hovering ? .white : .secondary)
                }
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary) }
            }
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct MenuBarRow: View {
    @Environment(EngineModel.self) private var model
    let job: JobView
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).lineLimit(1).truncationMode(.middle)
                if job.state == .verifying {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                } else if job.isActive, let total = job.total, total > 0 {
                    ProgressView(value: Double(min(job.done, total)), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Group {
                if job.isActive && job.resumable && job.state != .verifying {
                    Button { model.pause(job.id) } label: { Image(systemName: "pause.fill") }
                        .help("Pause \(job.name)")
                } else if job.state == .paused {
                    Button { model.resume(job.id) } label: { Image(systemName: "play.fill") }
                        .help("Resume \(job.name)")
                } else if job.isDone {
                    Button { model.reveal(job) } label: { Image(systemName: "folder") }
                        .help("Show \(job.name) in Finder")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture { if job.isDone { model.open(job) } }
        .help(job.isDone ? "Open \(job.name)" : "")
        .contextMenu {
            if job.isDone {
                Button("Open") { model.open(job) }
                Button("Show in Finder") { model.reveal(job) }
                Divider()
            }
            Button("Remove from Rays") { model.remove(job.id, deletePartial: false) }
            if job.isDone, model.locate(job) != nil {
                Button("Move to Trash", role: .destructive) { model.removeAndTrash([job]) }
            }
        }
    }

    private var status: String {
        switch job.state {
        case .running, .retrying: job.bytesPerSec > 0 ? "\(job.sizeText) · \(byteText(job.bytesPerSec))/s" : job.sizeText
        case .verifying: "Verifying…"
        case .paused: "Paused · \(job.sizeText)"
        case .queued: "Waiting"
        case .done: "Done · \(byteText(job.total ?? job.done))"
        case .failed: "Failed"
        }
    }
}
