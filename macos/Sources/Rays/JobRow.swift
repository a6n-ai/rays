import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobRow: View {
    @Environment(EngineModel.self) private var model
    let job: JobView
    var isSelected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmStop = false
    @State private var confirmRemove = false
    @State private var isHovered = false

    private enum Primary {
        case pause, stop, resume, retry, reveal, removeFromList

        var title: String {
            switch self {
            case .pause: "Pause"
            case .stop: "Stop"
            case .resume: "Resume"
            case .retry: "Retry"
            case .reveal: "Show in Finder"
            case .removeFromList: "Remove from List"
            }
        }

        var symbol: String {
            switch self {
            case .pause: "pause.fill"
            case .stop: "stop.fill"
            case .resume: "play.fill"
            case .retry: "arrow.clockwise"
            case .reveal: "folder.fill"
            case .removeFromList: "xmark"
            }
        }

        var tint: Color {
            switch self {
            case .pause: .orange
            case .stop: .red
            case .resume, .retry, .reveal: .blue
            case .removeFromList: .secondary
            }
        }
    }

    private struct Part {
        var text: String
        var symbol: String?
        var tint: Color = .secondary

        init(_ text: String, symbol: String? = nil, tint: Color = .secondary) {
            self.text = text
            self.symbol = symbol
            self.tint = tint
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: LayoutMetrics.gap) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(job.name)
                if !job.isFinished { progress }
                status
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.isDone, let url = model.locate(job) {
                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Share or AirDrop \(job.name)")
                .accessibilityLabel("Share \(job.name)")
            }
            moreButton
            if let primary { primaryButton(primary) }
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        // In the row background, so hover fills the same full-width cell as the selection.
        .listRowBackground(RowHighlight(selected: isSelected, hovered: isHovered))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
        .dragOut(model.locate(job))
        .contextMenu { menu }
        // Simultaneous, so the parent's single-click selection still fires.
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            if job.isDone { model.open(job) }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([job.name] + statusParts.map(\.text)).joined(separator: ", "))
        .accessibilityActions { if let primary { Button(primary.title) { perform(primary) } } }
        .confirmationDialog(
            "Stopping loses \(byteText(job.done)) of progress. Stop anyway?",
            isPresented: $confirmStop, titleVisibility: .visible
        ) {
            Button("Stop", role: .destructive) { model.pause(job.id) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Remove \(job.name)?", isPresented: $confirmRemove, titleVisibility: .visible
        ) {
            Button("Remove and Delete Partial File", role: .destructive) {
                model.remove(job.id, deletePartial: true)
            }
            Button("Remove and Keep Partial File") { model.remove(job.id, deletePartial: false) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var icon: some View {
        let type = UTType(filenameExtension: URL(filePath: job.name).pathExtension) ?? .data
        return Image(nsImage: NSWorkspace.shared.icon(for: type))
            .resizable()
            .frame(width: LayoutMetrics.iconSize, height: LayoutMetrics.iconSize)
            .overlay(alignment: .bottomTrailing) { badge }
    }

    @ViewBuilder private var badge: some View {
        switch job.state {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .green)
                .font(.system(size: 14))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .font(.system(size: 14))
        default:
            EmptyView()
        }
    }

    private var progress: some View {
        Group {
            if job.state == .verifying {
                ProgressView()
            } else if let total = job.total, total > 0, job.parts.count > 1 {
                SegmentedProgressBar(parts: job.parts, total: total, tint: progressTint)
            } else if let total = job.total, total > 0 {
                ProgressView(value: Double(min(job.done, total)), total: Double(total))
            } else if job.state == .running {
                ProgressView()
            } else {
                ProgressView(value: 0, total: 1)
            }
        }
        .progressViewStyle(.linear)
        .controlSize(.small)
        .tint(progressTint)
    }

    private var progressTint: Color {
        switch job.state {
        case .queued, .paused: .secondary
        default: .accentColor
        }
    }

    private var status: some View {
        HStack(spacing: 12) {
            ForEach(Array(statusParts.enumerated()), id: \.offset) { _, part in
                if let symbol = part.symbol {
                    HStack(spacing: 4) {
                        Image(systemName: symbol).font(.system(size: 12))
                        Text(part.text)
                    }
                    .foregroundStyle(part.tint)
                } else {
                    Text(Links.clickable(part.text)).foregroundStyle(part.tint)
                }
            }
        }
        .font(.callout)
        .monospacedDigit()
        .lineLimit(1)
    }

    private var statusParts: [Part] {
        var parts: [Part]
        switch job.state {
        case .queued:
            // The engine gives a reason only for queued jobs, e.g. "Queue stopped".
            parts = job.waiting.map { [Part($0, symbol: "clock")] } ?? [Part("Waiting")]
        case .running:
            parts = [Part(job.sizeText)]
            if job.bytesPerSec > 0 { parts.append(Part(byteText(job.bytesPerSec) + "/s")) }
            if let eta = etaText { parts.append(Part(eta)) }
        case .paused:
            parts = [Part("Paused"), Part(job.sizeText)]
        case .retrying(let attempt):
            parts = [Part("Reconnecting, try \(attempt) of 5")]
        case .verifying:
            parts = [Part("Verifying…")]
        case .done:
            // Read so the row redraws when the sorter moves its file.
            _ = model.folderRevision
            if let url = model.locate(job) {
                // Where the file is now matters more than when it finished, so the time is dropped here.
                parts = [Part(model.location(of: url, job: job), symbol: "folder"), Part(byteText(job.total ?? job.done))]
            } else {
                parts = model.isInTrash(job)
                    ? [Part("In the Trash", symbol: "trash")]
                    : [Part("Deleted or moved out of Downloads", symbol: "questionmark.folder")]
            }
        case .failed(let reason):
            parts = [Part(Self.humanFailure(reason))]
        }
        if !job.resumable && (job.isActive || job.state == .paused) {
            parts.append(Part("Can't resume", symbol: "exclamationmark.arrow.circlepath", tint: .orange))
        }
        if job.isActive && job.connections > 1 {
            parts.append(Part("\(job.connections)", symbol: "point.3.connected.trianglepath.dotted"))
        }
        return parts
    }

    /// Keeps the HTTP code in the text so the report can still be matched to the server log.
    private static func humanFailure(_ reason: String) -> String {
        if let range = reason.range(of: "HTTP "), let code = Int(reason[range.upperBound...].prefix(3)) {
            switch code {
            case 401: return "Needs a login (401)"
            case 403: return "Access denied (403)"
            case 404: return "Not found on the server (404)"
            case 410: return "No longer available (410)"
            case 429: return "The server is limiting requests (429)"
            case 500...599: return "Server error (\(code))"
            default: break
            }
        }
        if reason.hasPrefix("request:") || reason.hasPrefix("timeout") { return "Couldn't reach the server" }
        if reason.contains("size mismatch") { return "Download was incomplete" }
        return reason
    }

    private var etaText: String? {
        guard let total = job.total, job.bytesPerSec > 0, total > job.done else { return nil }
        let seconds = Double(total - job.done) / Double(job.bytesPerSec)
        let remaining = Duration.seconds(seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 1))
        return "\(remaining) left"
    }

    private func finishedText(_ url: URL) -> String? {
        guard let date = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
        else { return nil }
        return Calendar.current.isDateInToday(date)
            ? "Today, " + date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// A finished download whose file is neither at its saved path nor under the downloads folder.
    private var isMissing: Bool { job.isDone && model.locate(job) == nil }

    /// Nil while verifying: the hash cannot be paused or stopped.
    private var primary: Primary? {
        switch job.state {
        case .queued: .pause
        case .running, .retrying: job.resumable ? .pause : .stop
        case .verifying: nil
        case .paused: .resume
        case .failed: .retry
        case .done: isMissing ? .removeFromList : .reveal
        }
    }

    /// Plain style with an explicit glass circle, so the 28 pt glass is not padded by the glass button style.
    private func primaryButton(_ primary: Primary) -> some View {
        Button { perform(primary) } label: {
            Image(systemName: primary.symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(primary.tint)
                // play.fill is optically left-heavy inside a circle.
                .offset(x: primary == .resume ? 1 : 0)
                .frame(width: LayoutMetrics.rowAction, height: LayoutMetrics.rowAction)
                .glassEffect(.regular.interactive(), in: .circle)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("\(primary.title) \(job.name)")
        .accessibilityLabel("\(primary.title) \(job.name)")
    }

    /// The context menu, shown on hover so Remove and Move to Trash are found without right-clicking.
    private var moreButton: some View {
        Menu { menu } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: LayoutMetrics.rowHitArea, height: LayoutMetrics.rowHitArea)
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 1 : 0)
        .help("More actions")
        .accessibilityLabel("More actions for \(job.name)")
    }

    private func perform(_ action: Primary) {
        switch action {
        case .pause: model.pause(job.id)
        case .stop: confirmStop = true
        case .resume, .retry: model.resume(job.id)
        case .reveal: model.reveal(job)
        case .removeFromList: model.remove(job.id, deletePartial: false)
        }
    }

    @ViewBuilder private var menu: some View {
        if !job.isDone, let primary {
            Button { perform(primary) } label: { Label(primary.title, systemImage: primary.symbol) }
        } else if let url = model.locate(job) {
            Button { model.reveal(job) } label: { Label("Show in Finder", systemImage: "folder") }
            Button {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [url])
            } label: {
                Label("AirDrop", systemImage: "dot.radiowaves.up.forward")
            }
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url, forType: .string)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        Menu {
            ForEach(model.sortedQueues) { queue in
                Button {
                    model.moveToQueue(job: job.id, queue: queue.id)
                } label: {
                    if queue.id == job.queueId {
                        Label(queue.config.name, systemImage: "checkmark")
                    } else {
                        Text(queue.config.name)
                    }
                }
            }
        } label: {
            Label("Move to Queue", systemImage: "list.bullet")
        }
        Divider()
        Button(role: .destructive) {
            if job.hasPartial { confirmRemove = true } else { model.remove(job.id, deletePartial: false) }
        } label: {
            Label(job.hasPartial ? "Remove…" : "Remove from List", systemImage: "minus.circle")
        }
        if model.locate(job) != nil {
            Button(role: .destructive) { model.removeAndTrash([job]) } label: {
                Label("Remove and Move to Trash", systemImage: "trash")
            }
        }
    }
}

private extension View {
    @ViewBuilder func dragOut(_ url: URL?) -> some View {
        if let url { draggable(url) } else { self }
    }
}

/// Hover and selection share one grey rounded cell, selection a step darker. Replaces the blue system highlight.
struct RowHighlight: View {
    let selected: Bool
    let hovered: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(.primary.opacity(selected ? 0.14 : hovered ? 0.07 : 0))
            .padding(.horizontal, 10)
    }
}
