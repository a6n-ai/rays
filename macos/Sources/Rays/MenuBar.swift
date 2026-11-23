import AppKit
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
    private var shown: (Int, Int)?
    private var activity: NSObjectProtocol?
    private lazy var view = NSHostingView(rootView: DockTile(progress: nil))

    init(model: EngineModel) {
        self.model = model
        track()
    }

    /// Re-arms on every change it reads, so the Dock updates only when the job list changes (no timer).
    private func track() {
        withObservationTracking {
            update()
        } onChange: {
            Task { @MainActor [weak self] in self?.track() }
        }
    }

    private func update() {
        let count = model.activeJobs.count
        let progress = model.overallProgress
        if count > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Downloading files")
        } else if count == 0, let running = activity {
            ProcessInfo.processInfo.endActivity(running)
            activity = nil
        }
        // Redrawing the Dock costs a little, so only whole-percent changes do.
        let key = (count, progress.map { Int($0 * 100) } ?? -1)
        guard shown.map({ $0 != key }) ?? true else { return }
        shown = key
        let tile = NSApp.dockTile
        tile.badgeLabel = count > 0 ? "\(count)" : nil
        if count > 0 {
            view.rootView = DockTile(progress: progress)
            tile.contentView = view
        } else {
            tile.contentView = nil
        }
        tile.display()
    }
}

private struct DockTile: View {
    let progress: Double?

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: NSApp.applicationIconImage).resizable()
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

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: Self.icon)
            if !model.activeJobs.isEmpty, let progress = model.overallProgress {
                Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
            }
        }
        .accessibilityLabel(model.activeJobs.isEmpty ? "Rays" : "Rays, \(model.activeJobs.count) downloading")
    }

    /// The app icon at menu bar size. A copy: resizing NSApp's own image would also shrink the Dock icon.
    static let icon: NSImage = {
        let image = (NSApp.applicationIconImage.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}

/// The menu bar panel: add a download, what is downloading, and the rest of Rays one click away.
struct MenuBarPanel: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var link = ""

    private var recent: [JobView] {
        let active = model.activeJobs
        let rest = model.jobs.filter { !$0.isActive }.suffix(max(0, 4 - active.count))
        return Array(active.prefix(6)) + rest.reversed()
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
                    // Non-resumable downloads would lose their progress, so Pause All leaves them running.
                    MenuItem("Pause All", symbol: "pause.circle") { model.activeJobs.filter(\.resumable).forEach { model.pause($0.id) } }
                } else if !paused.isEmpty {
                    MenuItem("Resume All", symbol: "play.circle") { paused.forEach { model.resume($0.id) } }
                }
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                MenuItem("Downloads", symbol: "arrow.down.circle") { show(.openDownloads) }
                MenuItem("Sorter", symbol: "wand.and.stars") { show(.openSorter) }
                MenuItem("Cloud", symbol: "cloud") { show(.openCloud) }
            }
            .padding(6)
            Divider()
            VStack(spacing: 0) {
                MenuItem("Open Rays", symbol: "macwindow") { show(nil) }
                MenuItem("Settings…", symbol: "gearshape") {
                    AppDelegate.showInDock()
                    openSettings()
                }
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
    var shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(hovering ? .white : .secondary)
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
                if job.isActive, let total = job.total, total > 0 {
                    ProgressView(value: Double(min(job.done, total)), total: Double(total))
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
                Text(status).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            Group {
                if job.isActive && job.resumable {
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
    }

    private var status: String {
        switch job.state {
        case .running, .retrying: job.bytesPerSec > 0 ? "\(job.sizeText) · \(byteText(job.bytesPerSec))/s" : job.sizeText
        case .paused: "Paused · \(job.sizeText)"
        case .queued: "Waiting"
        case .done: "Done · \(byteText(job.total ?? job.done))"
        case .failed: "Failed"
        }
    }
}
