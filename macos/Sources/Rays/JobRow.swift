import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct JobRow: View {
    @Environment(EngineModel.self) private var model
    let job: JobView
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
            primaryButton
        }
        .frame(height: LayoutMetrics.rowHeight)
        .padding(.horizontal, LayoutMetrics.hoverInset)
        .background(.quaternary.opacity(isHovered ? 0.6 : 0), in: .rect(cornerRadius: 10))
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .smooth(duration: 0.15), value: isHovered)
        .dragOut(model.locate(job))
        .contextMenu { menu }
        .onTapGesture(count: 2) {
            if job.isDone { model.open(job) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([job.name] + statusParts.map(\.text)).joined(separator: ", "))
        .accessibilityAction(named: primary.title) { perform(primary) }
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
            if let total = job.total, total > 0, job.parts.count > 1 {
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
                    Text(part.text).foregroundStyle(part.tint)
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
            parts = [Part("Waiting")]
        case .running:
            parts = [Part(job.sizeText)]
            if job.bytesPerSec > 0 { parts.append(Part(byteText(job.bytesPerSec) + "/s")) }
            if let eta = etaText { parts.append(Part(eta)) }
        case .paused:
            parts = [Part("Paused"), Part(job.sizeText)]
        case .retrying(let attempt):
            parts = [Part("Reconnecting, try \(attempt) of 5")]
        case .done:
            if let url = model.locate(job) {
                // Where the file is now matters more than when it finished, so the time is dropped here.
                parts = [Part(model.location(of: url), symbol: "folder"), Part(byteText(job.total ?? job.done))]
            } else {
                parts = [Part("Moved or deleted", symbol: "questionmark.folder")]
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

    private var primary: Primary {
        switch job.state {
        case .queued: .pause
        case .running, .retrying: job.resumable ? .pause : .stop
        case .paused: .resume
        case .failed: .retry
        case .done: isMissing ? .removeFromList : .reveal
        }
    }

    /// Plain style with an explicit glass circle, so the 28 pt glass is not padded by the glass button style.
    private var primaryButton: some View {
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
        if !job.isDone {
            Button { perform(primary) } label: { Label(primary.title, systemImage: primary.symbol) }
        } else if !isMissing {
            Button { model.reveal(job) } label: { Label("Show in Finder", systemImage: "folder") }
        }
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(job.url, forType: .string)
        } label: {
            Label("Copy Link", systemImage: "link")
        }
        Divider()
        Button(role: .destructive) {
            if job.hasPartial { confirmRemove = true } else { model.remove(job.id, deletePartial: false) }
        } label: {
            Label("Remove…", systemImage: "trash")
        }
        if let url = model.locate(job) {
            Button(role: .destructive) {
                NSWorkspace.shared.recycle([url]) { _, _ in }
                model.remove(job.id, deletePartial: false)
            } label: {
                Label("Remove and Delete File", systemImage: "trash.fill")
            }
        }
    }
}

private extension View {
    @ViewBuilder func dragOut(_ url: URL?) -> some View {
        if let url { draggable(url) } else { self }
    }
}
