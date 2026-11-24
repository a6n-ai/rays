import SwiftUI

/// Finds Hugging Face models by name, or opens one directly from an org/repo or a huggingface.co link.
struct ModelsView: View {
    @Environment(EngineModel.self) private var model
    @State private var sorter = SorterModel()
    @State private var query = ""
    @State private var results: [HfModel] = []
    @State private var repo: HfRepo?
    @State private var error: String?

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            content
        }
        .navigationTitle("Models")
        .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
        .task { await sorter.refresh() }
        .task(id: query) { await search() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Name, org/repo, or huggingface.co link", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary, in: .rect(cornerRadius: 8))
        .padding(LayoutMetrics.margin)
    }

    @ViewBuilder private var content: some View {
        if let repo {
            ModelDetailView(repo: repo, destinations: sorter.destinations).id(repo.id)
        } else if let error {
            EmptyState(symbol: "exclamationmark.triangle", title: "Couldn't load models", message: error)
        } else if text.isEmpty {
            EmptyState(symbol: "cube", title: "Search Hugging Face models")
        } else if results.isEmpty {
            EmptyState(symbol: "tray", title: "No models match")
        } else {
            List(results, id: \.id) { resultRow($0) }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
        }
    }

    private func resultRow(_ hit: HfModel) -> some View {
        Button { Task { await open(hit.id) } } label: {
            HStack(spacing: 12) {
                Text(hit.id).lineLimit(1).truncationMode(.middle)
                Spacer()
                Label(hit.downloads.formatted(.number.notation(.compactName)), systemImage: "arrow.down.circle")
                Label(hit.likes.formatted(.number.notation(.compactName)), systemImage: "heart")
                if hit.gated && !model.hasHFToken {
                    Image(systemName: "lock.fill").accessibilityLabel("Gated")
                }
            }
            .foregroundStyle(.primary)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Runs after each pause in typing. A pasted link or org/repo opens its model directly.
    private func search() async {
        guard !text.isEmpty else {
            repo = nil
            results = []
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled else { return }
        if let id = hfRepoFromInput(input: text) {
            await open(id)
            return
        }
        repo = nil
        do {
            let found = try await model.hfSearch(text)
            guard !Task.isCancelled else { return }
            results = found
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            results = []
            self.error = error.localizedDescription
        }
    }

    private func open(_ id: String) async {
        do {
            repo = try await model.hfModel(id)
            error = nil
        } catch {
            repo = nil
            self.error = error.localizedDescription
        }
    }
}
