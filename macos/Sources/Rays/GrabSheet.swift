import SwiftUI

/// Files found on a web page, with checkboxes, a type filter and buttons to download now or add to a queue.
struct GrabSheet: View {
    @Environment(EngineModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let page: String

    private enum Phase { case loading, failed(String), found([GrabbedLink]) }
    @State private var phase = Phase.loading
    @State private var unchecked = Set<String>()
    @State private var kind = FileKind.all
    @State private var linkPage = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize

    private var shown: [GrabbedLink] {
        guard case .found(let links) = phase else { return [] }
        return links.filter { kind.matches($0.name) }
    }

    private var picked: [GrabbedLink] { shown.filter { !unchecked.contains($0.url) } }

    var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            Text("Links on this page").font(.headline)
            Text(page).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            content
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if case .found(let links) = phase, !links.isEmpty { actions }
            }
        }
        .padding(LayoutMetrics.margin)
        .frame(width: 520, height: 440)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView("Reading page").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Can't read this page", systemImage: "exclamationmark.triangle", description: Text(message))
        case .found(let links) where links.isEmpty:
            ContentUnavailableView("No downloadable files found on this page", systemImage: "doc.questionmark")
        case .found:
            HStack {
                Picker("Type", selection: $kind) {
                    ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                .onChange(of: kind) { _, _ in linkPage = 0 }
                Spacer()
                Text("\(picked.count) of \(shown.count) selected").foregroundStyle(.secondary).monospacedDigit()
            }
            List(ListControls.page(shown, linkPage, pageSize), id: \.url) { link in
                Toggle(isOn: Binding(
                    get: { !unchecked.contains(link.url) },
                    set: { if $0 { unchecked.remove(link.url) } else { unchecked.insert(link.url) } }
                )) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(link.name).lineLimit(1).truncationMode(.middle)
                        Text(link.url).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
            PageBar(count: shown.count, page: $linkPage, padded: true)
        }
    }

    private var actions: some View {
        HStack {
            Menu("Add to queue") {
                ForEach(model.sortedQueues) { queue in
                    Button(queue.config.name) { add(to: queue.id) }
                }
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(picked.isEmpty)
            Button("Download now") { add(to: 0) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(picked.isEmpty)
        }
    }

    private func add(to queue: UInt64) {
        model.add(picked.map(\.url).joined(separator: "\n"), queue: queue)
        dismiss()
    }

    private func load() async {
        do {
            phase = .found(try await model.grabLinks(page))
        } catch EngineError.InvalidUrl(let msg), EngineError.Io(let msg) {
            phase = .failed(msg)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}
