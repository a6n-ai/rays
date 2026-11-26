import SwiftUI

/// Finds Hugging Face models and lists the ones already downloaded. The model settings sit in the Search page's settings card.
struct ModelsView: View {
    @Environment(EngineModel.self) private var model
    @Environment(NavHistory.self) private var nav
    @State private var sorter = SorterModel()
    @State private var query = ""
    @State private var selection: String?
    @State private var page = 0
    @AppStorage(Paging.key) private var pageSize = Paging.defaultSize
    @State private var results: [HfModel] = []
    @State private var repo: HfRepo?
    @State private var error: String?
    @State private var loading = false
    @State private var filter = ModelFilter.all
    @State private var ggufOnly = false
    /// Bumped by every search and open; a reply is used only if no newer request started meanwhile.
    @State private var request = 0

    private var text: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var folder: URL {
        AIModelsFolder.base(downloadsDir: EngineModel.downloadsURL, destinations: sorter.destinations)
    }

    var body: some View {
        Group {
            if nav.sub == "repo", let repo {
                ModelDetailView(repo: repo, destinations: sorter.destinations).id(repo.id)
            } else if nav.sub == "downloaded" {
                DownloadedModelsView(folder: folder)
                    .navigationTitle("Downloaded Models")
            } else {
                searchList
                    .navigationTitle("Models")
            }
        }
        .task { await sorter.refresh() }
        .task(id: query) { await search() }
        .onChange(of: repo) { _, new in
            if new != nil && nav.sub != "repo" { nav.open("repo") }
            if new == nil && nav.sub == "repo" { nav.replaceSub(nil) }
        }
        .onChange(of: nav.sub) { _, new in if new != "repo" { repo = nil } }
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
    }

    private var shown: [HfModel] {
        results.filter { filter.matches(ModelKind(pipelineTag: $0.pipelineTag)) && (!ggufOnly || $0.gguf) }
    }

    private var cards: ArraySlice<HfModel> { ModelResultsList.cards(shown, featured: text.isEmpty) }
    private var rest: [HfModel] { Array(shown.dropFirst(cards.count)) }
    private var pageRows: ArraySlice<HfModel> { ListControls.page(rest, page, pageSize) }

    /// One List holds the hero (with the search field, so it keeps focus while results reload), the settings card and the results.
    private var searchList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HeroCard(.models, title: "Models",
                             subtitle: "Find models on Hugging Face and download them.",
                             learnMore: URL(string: "https://rays.a6n.ai/docs/app/models/")) {
                        HeroActions { Button("Open folder") { AIModelsFolder.reveal(folder) } }
                    }
                    HStack(spacing: 10) {
                        searchField
                        ModelFilterBar(filter: $filter, ggufOnly: $ggufOnly)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10, style: .continuous))
                .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            CollapsibleSettingsCard(page: "models", summary: "Models folder, Hugging Face token") {
                AIModelsFolderRow(folder: folder)
                    .cardRow(.middle, separatorInset: 0)
                HuggingFaceTokenRows(card: true)
                    .cardRow(.last, separatorInset: 0)
            }
            Section {
                DrillInRow(tile: .modelsFolder, title: "Downloaded models", subtitle: "Models already in your AI Models folder") {
                    nav.open("downloaded")
                }
                .cardRow(.only)
            }
            content
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .safeAreaInset(edge: .bottom, spacing: 0) { PageBar(count: rest.count, page: $page, padded: true) }
        .onChange(of: shown.map(\.id)) { _, _ in page = 0 }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
        .onKeyPress(.return) {
            guard let selection else { return .ignored }
            Task { await open(selection) }
            return .handled
        }
    }

    private func choose(_ id: String) {
        selection = id
        Task { await open(id) }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let visible = Array(cards) + pageRows
        guard !visible.isEmpty else { return .ignored }
        let current = visible.firstIndex { $0.id == selection }
        let next = current.map { min(max($0 + delta, 0), visible.count - 1) } ?? (delta > 0 ? 0 : visible.count - 1)
        selection = visible[next].id
        return .handled
    }

    private func stateRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Section {
            content()
                .frame(maxWidth: .infinity, minHeight: 160)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder private var content: some View {
        if let error {
            stateRow {
                ContentUnavailableView {
                    Label("Couldn't load models", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await search() } }
                }
            }
        } else if results.isEmpty {
            if loading {
                stateRow { ProgressView() }
            } else if !text.isEmpty {
                stateRow { EmptyState(symbol: "tray", title: "No models match") }
            } else {
                stateRow { EmptyState(symbol: "cube", title: "No trending models") }
            }
        } else if shown.isEmpty {
            let what = ggufOnly && filter == .all ? "GGUF" : filter.label
            stateRow { EmptyState(symbol: filter.representative.symbol, title: "No \(what) models in \(text.isEmpty ? "trending" : "results")") }
        } else {
            ModelResultsList(cards: cards, rows: pageRows, selection: selection, choose: choose)
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
