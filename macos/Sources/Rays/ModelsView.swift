import SwiftUI

/// Finds Hugging Face models by name, or opens one directly from an org/repo or a huggingface.co link.
struct ModelsView: View {
    @Environment(EngineModel.self) private var model
    @State private var sorter = SorterModel()
    @State private var query = ""
    @State private var results: [HfModel] = []
    @State private var repo: HfRepo?
    @State private var openedFromResults = false
    @State private var error: String?
    /// Bumped by every search and open; a reply is used only if no newer request started meanwhile.
    @State private var request = 0

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
            VStack(spacing: 0) {
                if openedFromResults {
                    HStack {
                        Button { self.repo = nil; openedFromResults = false } label: {
                            Label("Results", systemImage: "chevron.backward")
                        }
                        .help("Back to results")
                        .accessibilityLabel("Back to results")
                        Spacer()
                    }
                    .padding(.horizontal, LayoutMetrics.margin)
                }
                ModelDetailView(repo: repo, destinations: sorter.destinations).id(repo.id)
            }
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
        Button { Task { await open(hit.id, fromResults: true) } } label: {
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
        request += 1
        let token = request
        guard !text.isEmpty else {
            repo = nil
            openedFromResults = false
            results = []
            error = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(300))
        guard token == request, !Task.isCancelled else { return }
        // A bare org/repo is searched like any text (it may be half typed); only a pasted link opens directly.
        // A link that finds no model, like a half-typed one, falls through to a search of the same text.
        if text.localizedCaseInsensitiveContains("huggingface.co") || text.localizedCaseInsensitiveContains("hf.co"),
           let id = hfRepoFromInput(input: text), let found = try? await model.hfModel(id) {
            guard token == request, !Task.isCancelled else { return }
            repo = found
            openedFromResults = false
            error = nil
            return
        }
        repo = nil
        openedFromResults = false
        do {
            let found = try await model.hfSearch(text)
            guard token == request, !Task.isCancelled else { return }
            results = found
            error = nil
        } catch {
            guard token == request, !Task.isCancelled else { return }
            results = []
            self.error = EngineModel.message(for: error)
        }
    }

    private func open(_ id: String, fromResults: Bool) async {
        request += 1
        let token = request
        do {
            let found = try await model.hfModel(id)
            guard token == request, !Task.isCancelled else { return }
            repo = found
            openedFromResults = fromResults
            error = nil
        } catch {
            guard token == request, !Task.isCancelled else { return }
            repo = nil
            openedFromResults = false
            self.error = EngineModel.message(for: error)
        }
    }
}
