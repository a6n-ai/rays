import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SorterView: View {
    @State private var model: SorterModel
    @State private var removing: SorterFolder?

    @MainActor init(model: SorterModel? = nil) {
        _model = State(initialValue: model ?? SorterModel())
    }

    private var watchedCount: Int { model.status?.folders.filter(\.watching).count ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            explainer
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.top, LayoutMetrics.gap)
            if let error = model.error {
                ErrorLine(text: error)
                    .padding(.horizontal, LayoutMetrics.margin)
            }
            List {
                if model.loadFailed {
                    ErrorLine(text: SorterModel.unavailableMessage)
                }
                if let status = model.status {
                    if status.folders.isEmpty {
                        Text("No folders yet. Add one above to start sorting.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(status.folders) { folder in
                        FolderSection(model: model, folder: folder, categories: status.categories) {
                            removing = folder
                        }
                    }
                    recentSection(status.recent)
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .all)
        }
        .navigationTitle("Sorter")
        .navigationSubtitle(watchedCount == 1 ? "1 folder watched" : "\(watchedCount) folders watched")
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
        .confirmationDialog(
            "Stop sorting \(removing?.name ?? "this folder")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove Folder", role: .destructive) {
                if let folder = removing { Task { await model.remove(folder) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Rays stops sorting this folder. Files already sorted stay where they are.")
        }
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.gap) {
            HStack(spacing: 10) {
                SettingIcon(symbol: "sparkles", color: .pink)
                Text("Sort with AI").font(.headline)
            }
            Text("Rays files new downloads and documents into folders like Work and Personal. It runs on your Mac; nothing is uploaded.")
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: chooseFolder) {
                    Label("Add Folder…", systemImage: "plus")
                }
                .buttonStyle(.glassProminent)
                .disabled(model.busy || model.loadFailed)
                ForEach(quickFolders, id: \.self) { url in
                    Button { Task { await model.addFolder(url.path(percentEncoded: false)) } } label: {
                        Label(url.lastPathComponent, systemImage: "plus")
                    }
                    .buttonStyle(.glass)
                    .disabled(model.busy)
                }
                if model.busy {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(LayoutMetrics.margin)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// Desktop, Documents and Downloads, minus any already in the list.
    private var quickFolders: [URL] {
        guard let folders = model.status?.folders else { return [] }
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Compare plain paths: a directory URL's trailing slash would otherwise make equal folders differ.
        func key(_ url: URL) -> String {
            let path = url.standardizedFileURL.path(percentEncoded: false)
            return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        }
        let watched = Set(folders.map { key(URL(filePath: $0.path)) })
        return [home.appending(path: "Desktop"), home.appending(path: "Documents"), EngineModel.downloadsURL]
            .filter { !watched.contains(key($0)) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Add Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.addFolder(url.path(percentEncoded: false)) }
    }

    @ViewBuilder private func recentSection(_ moves: [SorterMove]) -> some View {
        Section("Recent activity") {
            if moves.isEmpty {
                Text("Nothing sorted yet.").foregroundStyle(.secondary)
            }
            ForEach(Array(moves.prefix(20).enumerated()), id: \.offset) { _, move in
                MoveRow(move: move)
            }
        }
    }
}

private struct FolderSection: View {
    let model: SorterModel
    let folder: SorterFolder
    let categories: [SorterCategory]
    let onRemove: () -> Void
    @State private var showsDestinations = false

    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    var body: some View {
        Section {
            Toggle("Watching", isOn: Binding(
                get: { folder.watching },
                set: { on in Task { await model.setWatching(folder, on: on) } }))
                .toggleStyle(.switch)
                .disabled(model.busy || model.loadFailed)

            if let agent = folder.agentBinary, !isBundled(agent) {
                HStack {
                    Label("Using an old copy of the sorter", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Update") { Task { await model.update(folder) } }
                        .buttonStyle(.glass)
                        .disabled(model.busy)
                }
            }

            HStack(spacing: LayoutMetrics.gap) {
                Button("Sort Now") { Task { await model.sortNow(folder) } }
                    .buttonStyle(.glass)
                    .disabled(model.busy || model.loadFailed)
                if let result = model.sortResults[folder.path] {
                    Text(result).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            DisclosureGroup("Where files go", isExpanded: $showsDestinations) {
                ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                    CategoryRow(model: model, folder: folder, category: category,
                                color: Self.colors[index % Self.colors.count])
                }
            }

            Button(role: .destructive, action: onRemove) {
                Label("Remove Folder", systemImage: "trash")
            }
            .disabled(model.busy)
        } header: {
            HStack(spacing: 6) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(URL(filePath: folder.path).tildePath)
            }
        }
    }

    private func isBundled(_ path: String) -> Bool {
        URL(filePath: path).resolvingSymlinksInPath() == URL(filePath: Sorter.defaultPath).resolvingSymlinksInPath()
    }
}

private struct CategoryRow: View {
    let model: SorterModel
    let folder: SorterFolder
    let category: SorterCategory
    let color: Color

    var body: some View {
        let custom = model.destination(for: folder, category: category.name)
        LabeledContent {
            HStack(spacing: 8) {
                Text(custom.map { URL(filePath: $0).tildePath } ?? "Inside \(folder.name)")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(custom ?? folder.path)
                Button("Change…", action: chooseDestination)
                    .buttonStyle(.glass)
                    .disabled(model.busy)
                if custom != nil {
                    Button("Reset") { Task { await model.resetDestination(folder, category: category.name) } }
                        .buttonStyle(.glass)
                        .disabled(model.busy)
                }
            }
        } label: {
            HStack(spacing: 10) {
                SettingIcon(symbol: "folder.fill", color: color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                    Text(category.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Use Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.setDestination(folder, category: category.name, path: url.path(percentEncoded: false)) }
    }
}

private struct MoveRow: View {
    let move: SorterMove

    var body: some View {
        HStack(spacing: LayoutMetrics.gap) {
            Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: URL(filePath: move.file).pathExtension) ?? .data))
                .resizable()
                .frame(width: 20, height: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(move.file)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("→ \(placeText)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: LayoutMetrics.gap)
            Text(Date(timeIntervalSince1970: move.time), style: .relative)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: reveal)
        .help("Double-click to show in Finder")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Show in Finder", reveal)
    }

    /// "Work › Invoices" when the file went inside the folder it came from, otherwise the full path.
    private var placeText: String {
        let base = move.from.hasSuffix("/") ? move.from : move.from + "/"
        guard move.to.hasPrefix(base) else { return URL(filePath: move.to).tildePath }
        return move.to.dropFirst(base.count).split(separator: "/").joined(separator: " › ")
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: move.to).appending(path: move.file)])
    }
}

#if DEBUG
private let sorterFixture = """
{
  "folders": [
    { "path": "/Users/me/Downloads", "watching": true, "label": "local.sorter",
      "agent_binary": "/Applications/Rays.app/Contents/MacOS/sorter" },
    { "path": "/Users/me/Desktop", "watching": false, "label": "local.sorter.desktop", "agent_binary": null }
  ],
  "categories": [
    { "name": "Work", "description": "Invoices, reports and contracts." },
    { "name": "Personal", "description": "Photos, receipts and travel." }
  ],
  "recent": [
    { "time": 1763300000, "file": "report.pdf", "from": "/Users/me/Downloads", "to": "/Users/me/Downloads/Work/Invoices" }
  ]
}
"""

#Preview {
    SorterView(model: .preview(sorterFixture))
        .frame(width: 640, height: 480)
}
#endif
