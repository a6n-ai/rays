import SwiftUI

/// Finds Hugging Face models, lists the ones already downloaded, and holds the model settings.
struct ModelsView: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("modelsSection") private var section = ModelsSection.search
    @State private var sorter = SorterModel()
    @State private var query = ""
    @State private var results: [HfModel] = []
    @State private var repo: HfRepo?
    @State private var error: String?
    @State private var loading = false
    /// Bumped by every search and open; a reply is used only if no newer request started meanwhile.
    @State private var request = 0

    enum ModelsSection: String { case search, downloaded, settings }

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var folder: URL {
        AIModelsFolder.base(downloadsDir: EngineModel.downloadsURL, destinations: sorter.destinations)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch section {
                case .search:
                    VStack(spacing: 0) {
                        searchField
                        content
                    }
                case .downloaded:
                    DownloadedModelsView(folder: folder)
                case .settings:
                    ModelSettingsView(folder: folder)
                }
            }
            .navigationTitle("Models")
            .navigationDestination(item: $repo) { repo in
                ModelDetailView(repo: repo, destinations: sorter.destinations).id(repo.id)
            }
        }
        .toolbar { toolbar }
        .task { await sorter.refresh() }
        .task(id: query) { await search() }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ToolbarIconGroup {
                ForEach([(ModelsSection.search, "magnifyingglass", "Search Hugging Face"),
                         (ModelsSection.downloaded, "shippingbox", "Downloaded models"),
                         (ModelsSection.settings, "slider.horizontal.3", "Model settings")], id: \.0) { item in
                    Button {
                        section = item.0
                        repo = nil
                    } label: {
                        ToolbarIcon(symbol: item.1, title: item.2, selected: section == item.0)
                    }
                    .buttonStyle(.plain)
                    .help(item.2)
                    .accessibilityAddTraits(section == item.0 ? .isSelected : [])
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            ToolbarIconGroup {
                Button { AIModelsFolder.reveal(folder) } label: {
                    ToolbarIcon(symbol: "folder", title: "Open AI Models folder", tint: .blue)
                }
                .buttonStyle(.plain)
                .help("Open the AI Models folder in Finder")
                if let repo, let url = URL(string: "https://huggingface.co/\(repo.id)") {
                    Button { NSWorkspace.shared.open(url) } label: {
                        ToolbarIcon(symbol: "globe", title: "Open on Hugging Face", tint: .teal)
                    }
                    .buttonStyle(.plain)
                    .help("Open \(repo.id) on Hugging Face")
                }
            }
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
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
        if let error {
            ContentUnavailableView {
                Label("Couldn't load models", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { Task { await search() } }
            }
        } else if results.isEmpty {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !text.isEmpty {
                EmptyState(symbol: "tray", title: "No models match")
            } else {
                EmptyState(symbol: "cube", title: "No trending models")
            }
        } else {
            ModelResultsList(hits: results, header: text.isEmpty ? "Trending on Hugging Face" : nil) { id in
                Task { await open(id) }
            }
        }
    }

    /// Runs after each pause in typing. A pasted link or org/repo opens its model directly.
    private func search() async {
        request += 1
        let token = request
        // An empty field lists what's trending; typing searches after a pause.
        if text.isEmpty {
            repo = nil
            await load(token)
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
            error = nil
            return
        }
        repo = nil
        await load(token)
    }

    private func load(_ token: Int) async {
        loading = true
        defer { if token == request { loading = false } }
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

    private func open(_ id: String) async {
        request += 1
        let token = request
        do {
            let found = try await model.hfModel(id)
            guard token == request, !Task.isCancelled else { return }
            repo = found
            error = nil
        } catch {
            guard token == request, !Task.isCancelled else { return }
            repo = nil
            self.error = EngineModel.message(for: error)
        }
    }
}
