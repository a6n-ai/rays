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

/// The menu bar icon: a filled arrow while downloading, with the overall percent when sizes are known.
struct MenuBarLabel: View {
    @Environment(EngineModel.self) private var model

    var body: some View {
        if model.activeJobs.isEmpty {
            Image(systemName: "arrow.down.circle")
        } else {
            HStack(spacing: 3) {
                Image(systemName: "arrow.down.circle.fill")
                if let progress = model.overallProgress {
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                }
            }
        }
    }
}

/// The menu bar panel: what is downloading, quick actions, and a way back to the window.
struct MenuBarPanel: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var recent: [JobView] {
        let active = model.activeJobs
        let rest = model.jobs.filter { !$0.isActive }.suffix(max(0, 5 - active.count))
        return Array(active.prefix(8)) + rest.reversed()
    }
    private var clipboardLinks: [String] { Links.inText(NSPasteboard.general.string(forType: .string) ?? "") }
    private var paused: [JobView] { model.jobs.filter { $0.state == .paused } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Rays").font(.headline)
                Spacer()
                if !model.activeJobs.isEmpty {
                    Text("\(model.activeJobs.count) downloading · \(byteText(model.totalSpeed))/s")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if recent.isEmpty {
                Text("No downloads yet.").foregroundStyle(.secondary)
            }
            ForEach(recent, id: \.id) { job in MenuBarRow(job: job) }
            Divider()
            if !clipboardLinks.isEmpty {
                Button {
                    model.add(clipboardLinks.joined(separator: "\n"))
                } label: {
                    Label(clipboardLinks.count == 1 ? "Download Link from Clipboard" : "Download \(clipboardLinks.count) Links from Clipboard",
                          systemImage: "doc.on.clipboard")
                }
            }
            if !model.activeJobs.isEmpty {
                // Non-resumable downloads would lose their progress, so Pause All leaves them running.
                Button { model.activeJobs.filter(\.resumable).forEach { model.pause($0.id) } } label: {
                    Label("Pause All", systemImage: "pause.circle")
                }
            } else if !paused.isEmpty {
                Button { paused.forEach { model.resume($0.id) } } label: {
                    Label("Resume All", systemImage: "play.circle")
                }
            }
            Button {
                openWindow(id: "main")
                NSApp.activate()
            } label: {
                Label("Open Rays", systemImage: "macwindow")
            }
            Button { NSApp.terminate(nil) } label: { Label("Quit Rays", systemImage: "power") }
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 320)
    }
}

private struct MenuBarRow: View {
    @Environment(EngineModel.self) private var model
    let job: JobView

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
