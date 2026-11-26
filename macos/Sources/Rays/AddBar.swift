import SwiftUI

struct AddBar: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var fieldFocused: Bool
    @State private var input = ""
    /// A queue picked from the menu for the next paste only; submitting clears it.
    @State private var chosen: UInt64?
    @State private var grabPage: String?
    @State private var extra: LinkExtra?
    /// Shown as the placeholder after a menu action asks for something the field lacks.
    @State private var prompt: String?
    @Namespace private var glass
    let isTargeted: Bool
    /// The queue a paste goes to unless the menu picks another: the page's queue, or 0 for a direct download.
    let defaultQueue: UInt64

    /// The chosen queue while it still exists; a deleted choice falls back to the default.
    private var target: UInt64 {
        if let chosen, chosen == 0 || model.queues.contains(where: { $0.id == chosen }) { return chosen }
        return defaultQueue
    }

    private var isBlank: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isExpanded: Bool { fieldFocused || !isBlank }

    /// Web links found in what was typed or pasted; text around them is ignored, as on submit.
    private var split: (urls: [String], mirrors: [[String]]) { isBlank ? ([], []) : Links.split(input) }
    private var links: [String] { split.urls }
    private var linkCount: String {
        let base = links.count == 1 ? "1 link" : "\(links.count) links"
        let extra = split.mirrors.joined().count
        return extra == 0 ? base : base + (extra == 1 ? ", 1 mirror" : ", \(extra) mirrors")
    }

    /// What the field holds, as symbol and label pairs; empty counts are left out.
    private var detected: [(symbol: String, text: String)] {
        guard !links.isEmpty else { return [] }
        let sums = Links.checksums(in: input, for: links).compactMap { $0 }.count
        let mirrors = split.mirrors.joined().count
        let cloud = links.filter { $0.lowercased().hasPrefix("s3://") }.count
        let hugging = links.filter { URL(string: $0)?.host()?.lowercased().hasSuffix("huggingface.co") == true }.count
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? "1 \(one)" : "\(n) \(many)" }
        return [(links.count, "link", plural(links.count, "link", "links")),
                (sums, "checkmark.shield", plural(sums, "checksum", "checksums")),
                (mirrors, "square.on.square", plural(mirrors, "mirror", "mirrors")),
                (cloud, "cloud", plural(cloud, "cloud link", "cloud links")),
                (hugging, "cube", plural(hugging, "Hugging Face link", "Hugging Face links"))]
            .filter { $0.0 > 0 }
            .map { ($0.1, $0.2) }
    }

    var body: some View {
        GlassEffectContainer(spacing: LayoutMetrics.gap) {
            HStack(spacing: LayoutMetrics.gap) {
                addButton
                field
                downloadButton
            }
            // An overlay takes no layout space, so the bar does not move when a notice appears.
            .overlay(alignment: .top) {
                if model.notice == nil, !detected.isEmpty {
                    detectionLine
                        .alignmentGuide(.top) { d in d[.top] }
                        .offset(y: -(LayoutMetrics.barHeight / 2 + 22))
                }
            }
        }
        .frame(maxWidth: LayoutMetrics.barMaxWidth)
        // Outside the GlassEffectContainer: inside it, the notice's glass merged into the bar's and was hidden behind it.
        .overlay(alignment: .top) {
            if let notice = model.notice {
                noticeCapsule(notice)
                    .alignmentGuide(.top) { d in d[.top] }
                    .offset(y: -(LayoutMetrics.barHeight / 2 + 26))
                    .transition(.opacity)
            }
        }
        .background {
            // Zero-size, invisible button: exists only to own the ⌘L shortcut.
            Button("Add link") { fieldFocused = true }
                .keyboardShortcut("l", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .sheet(isPresented: Binding(get: { grabPage != nil }, set: { if !$0 { grabPage = nil } })) {
            if let grabPage { GrabSheet(page: grabPage) }
        }
        .sheet(item: $extra) { kind in
            LinkExtraSheet(kind: kind, link: links.first ?? "", saveHeaders: { link, headers in model.linkHeaders[link] = headers }) { line, replacing in
                var lines = input.split(whereSeparator: \.isNewline).map(String.init).filter { $0.trimmingCharacters(in: .whitespaces) != replacing }
                lines.append(line)
                input = lines.joined(separator: "\n")
                fieldFocused = true
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: isTargeted)
        .animation(reduceMotion ? nil : .smooth, value: model.notice)
        .animation(reduceMotion ? nil : .smooth, value: isExpanded)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, LayoutMetrics.margin)
        .padding(.bottom, LayoutMetrics.margin)
        // Clearing the field after a submit must keep the notice that submit just produced.
        .onChange(of: input) { _, new in if !new.isEmpty { model.clearNotice(); prompt = nil } }
        .onChange(of: model.pendingAdd, initial: true) { _, pending in
            guard let pending else { return }
            input = isBlank ? pending : input + "\n" + pending
            model.pendingAdd = nil
            fieldFocused = true
        }
        .onChange(of: model.requestedGrab, initial: true) { _, page in
            guard let page else { return }
            grabPage = page
            model.requestedGrab = nil
        }
        .onChange(of: model.requestedExtra, initial: true) { _, kind in
            guard let kind else { return }
            extra = kind
            model.requestedExtra = nil
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            model.clearNotice()
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "link").foregroundStyle(.secondary)
            TextField(isTargeted ? "Drop to download" : prompt ?? "Paste links, a page to scan, or a link with its SHA-256", text: $input, axis: .horizontal)
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                .onReceive(NotificationCenter.default.publisher(for: .focusAddBar)) { _ in fieldFocused = true }
                .onSubmit(submit)
            if !isBlank {
                Group {
                    if links.isEmpty {
                        Label("No link found", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    }
                }
                .font(.callout)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .transition(.opacity)
                .accessibilityLabel(links.isEmpty ? "No link found" : "\(linkCount) ready")
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: LayoutMetrics.barHeight, maxHeight: LayoutMetrics.barHeight)
        .glassEffect(isTargeted && !reduceTransparency ? .regular.tint(.accentColor) : .regular, in: .capsule)
    }

    private var detectionLine: some View {
        HStack(spacing: 10) {
            ForEach(detected, id: \.text) { item in
                Label(item.text, systemImage: item.symbol).labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(detected.map(\.text).joined(separator: ", ") + " ready")
    }

    /// What can be added, as a menu; the queue choices stay on the Download button.
    private var addButton: some View {
        Menu {
            Section("Add") {
                Button("Paste links", systemImage: "link") { fieldFocused = true }
                Button("Find links on a page…", systemImage: "doc.text.magnifyingglass") {
                    if links.count == 1, split.mirrors.joined().isEmpty {
                        grabPage = links.first
                    } else {
                        prompt = "Paste the page link here"
                        fieldFocused = true
                    }
                }
                Button("From a cloud bucket…", systemImage: "cloud") { model.requestedDestination = .cloud }
                Button("Hugging Face model…", systemImage: "cube") { model.requestedDestination = .models }
            }
            Section("With the link") {
                Button("Add a checksum…", systemImage: "checkmark.shield") { extra = .checksum }
                Button("Add a mirror…", systemImage: "square.on.square") { extra = .mirror }
                Button("Add headers…", systemImage: "key") { extra = .headers }
            }
        } label: {
            Label("Add", systemImage: "plus.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: LayoutMetrics.barHeight, height: LayoutMetrics.barHeight)
                .glassEffect(.regular.interactive(), in: .circle)
                .glassEffectID("add", in: glass)
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.4)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Add")
        .help("Paste links, find links on a page, add a checksum, a mirror or headers")
    }

    /// Plain style with an explicit glass shape: the glass button styles pad the label, so the frame could not pin the height.
    @ViewBuilder private var downloadButton: some View {
        let ready = !links.isEmpty
        let dimmed = !isEnabled || !ready
        // Always the round icon; a pasted link fills it with the accent colour instead of growing a label.
        Menu {
            Picker("Queue", selection: Binding(get: { target }, set: { chosen = $0 })) {
                Label("Download now", systemImage: "arrow.down.circle").tag(UInt64(0))
                ForEach(model.sortedQueues) { option in
                    Label(option.config.name, systemImage: QueueAppearances.shared.appearance(for: option).symbol).tag(option.id)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button {
                submitAtBestTime()
            } label: {
                Label(bestTimeTitle, systemImage: "moon.stars")
            }
            Button {
                grabPage = links.first
            } label: {
                Label("Find links on a page…", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(links.count != 1 || !split.mirrors.joined().isEmpty)
        } label: {
            HStack(spacing: 6) {
                Label("Download", systemImage: "arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ready ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor)) : AnyShapeStyle(.tint))
                    .frame(width: LayoutMetrics.barHeight, height: LayoutMetrics.barHeight)
                    .glassEffect(ready ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: .circle)
                    .glassEffectID("download", in: glass)
                    .contentShape(Circle())
                    .opacity(dimmed ? 0.4 : 1)
                if target != defaultQueue, let name = target == 0 ? "Now" : model.queues.first(where: { $0.id == target })?.config.name {
                    Text(name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } primaryAction: {
            submit()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!ready)
        .accessibilityHint("Choose a queue")
        .help(links.isEmpty ? "Paste a link that starts with http:// or https://" : "Download \(linkCount)")
    }

    private func noticeCapsule(_ text: String) -> some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: LayoutMetrics.barMaxWidth)
        .glassEffect(reduceTransparency ? .regular : .regular.tint(Color.red.opacity(0.2)), in: .capsule)
    }

    private var bestTimeTitle: String {
        guard let best = model.bestTime else { return "At best time" }
        return "At best time (\(best.windowText)\(best.hasWindow ? "" : ", default"))"
    }

    private func submitAtBestTime() {
        guard !isBlank else { return }
        let text = input
        input = ""
        chosen = nil
        model.addAtBestTime(text)
    }

    private func submit() {
        guard !isBlank else { return }
        model.add(input, queue: target)
        input = ""
        chosen = nil
    }
}

enum LinkExtra: String, Identifiable {
    case checksum, mirror, headers
    var id: String { rawValue }
}

/// One `Name: value` per line; a line without a colon is an error the sheet shows.
enum HeaderLines {
    static func parse(_ text: String) -> (headers: [HttpHeader], badLine: Int?) {
        var headers: [HttpHeader] = []
        for (i, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            // Smart quotes and dashes from a paste or autocorrect would make a header name or value invalid.
            let line = String(raw.map { ch -> Character in
                switch ch {
                case "\u{201C}", "\u{201D}": "\""
                case "\u{2018}", "\u{2019}": "'"
                case "\u{2013}", "\u{2014}": "-"
                default: ch
                }
            }).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { return ([], i + 1) }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            if name.isEmpty { return ([], i + 1) }
            headers.append(HttpHeader(name: name, value: line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)))
        }
        return (headers, nil)
    }
}

/// Builds the text the add bar's parser reads: "link sha256" or "link mirror1 mirror2". `onConfirm` gets the line and the bare link line it replaces.
/// Headers cannot ride in that text, so `saveHeaders` hands them to the model, which sends them with the next add.
struct LinkExtraSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: LinkExtra
    let saveHeaders: (String, [HttpHeader]) -> Void
    let onConfirm: (String, String) -> Void
    @State private var link: String
    @State private var value = ""

    init(kind: LinkExtra, link: String, saveHeaders: @escaping (String, [HttpHeader]) -> Void, onConfirm: @escaping (String, String) -> Void) {
        self.kind = kind
        self.saveHeaders = saveHeaders
        self.onConfirm = onConfirm
        _link = State(initialValue: link)
    }

    private var cleanLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var cleanValue: String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedHeaders: (headers: [HttpHeader], badLine: Int?) { HeaderLines.parse(value) }
    private var valid: Bool {
        guard !Links.inText(cleanLink).isEmpty else { return false }
        switch kind {
        case .checksum: return cleanValue.count == 64 && cleanValue.allSatisfy(\.isHexDigit)
        case .mirror: return !Links.inText(cleanValue).isEmpty
        case .headers: return !parsedHeaders.headers.isEmpty && parsedHeaders.badLine == nil
        }
    }

    private var title: String {
        switch kind {
        case .checksum: "Add a checksum"
        case .mirror: "Add a mirror"
        case .headers: "Add headers"
        }
    }

    private var summary: String {
        switch kind {
        case .checksum: "Rays checks the file against this SHA-256 when it finishes."
        case .mirror: "Mirrors must serve the same file under the same name on other hosts. Rays uses the fastest."
        case .headers: "Rays sends these headers with every request for this link and keeps them in its database on this Mac."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            Text(title).font(.headline)
            Text(summary).font(.callout).foregroundStyle(.secondary)
            Form {
                TextField("Link", text: $link, prompt: Text("https://example.com/file.iso"))
                switch kind {
                case .checksum:
                    TextField("SHA-256", text: $value, prompt: Text("64 hex characters"))
                        .font(.body.monospaced())
                case .mirror:
                    TextField("Mirror links", text: $value, prompt: Text("One or more links, separated by spaces"), axis: .vertical)
                        .lineLimit(2...4)
                case .headers:
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Headers")
                        TextEditor(text: $value)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .scrollContentBackground(.hidden)
                            .padding(4)
                            .frame(height: 84)
                            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
                        if let bad = parsedHeaders.badLine {
                            Label("Line \(bad) needs a colon, like Name: value", systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(.red)
                        } else {
                            Text("For links that need a login, for example Cookie: session=\u{2026} Sent only to this link's site.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.columns)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(kind == .headers ? "Save" : "Add to field") {
                    if kind == .headers {
                        let url = Links.inText(cleanLink)[0]
                        saveHeaders(url, parsedHeaders.headers)
                        onConfirm(url, cleanLink)
                    } else {
                        let extras = kind == .checksum ? cleanValue : Links.inText(cleanValue).joined(separator: " ")
                        onConfirm("\(Links.inText(cleanLink)[0]) \(extras)", cleanLink)
                    }
                    dismiss()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(LayoutMetrics.margin)
        .frame(width: 440)
    }
}
