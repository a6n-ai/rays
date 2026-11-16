import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension SorterFolder {
    /// An agent copy other than the bundled sorter, left behind by an older install.
    var needsUpdate: Bool {
        guard let agent = agentBinary else { return false }
        return URL(filePath: agent).resolvingSymlinksInPath() != URL(filePath: Sorter.defaultPath).resolvingSymlinksInPath()
    }
}

struct SorterView: View {
    @State private var model: SorterModel

    @MainActor init(model: SorterModel? = nil) {
        _model = State(initialValue: model ?? SorterModel())
    }

    private var watchedCount: Int { model.status?.folders.filter(\.watching).count ?? 0 }

    var body: some View {
        NavigationStack {
            Form {
                if let error = model.error {
                    Section { ErrorLine(text: error) }
                }
                if model.loadFailed {
                    Section { ErrorLine(text: SorterModel.unavailableMessage) }
                }

                Section("On-device AI") {
                    AIStatusRow()
                }

                Section {
                    ForEach(model.status?.folders ?? []) { folder in
                        NavigationLink(value: folder.path) {
                            FolderRow(folder: folder)
                        }
                    }
                    if model.status?.folders.isEmpty == true {
                        Text("No folders yet.").foregroundStyle(.secondary)
                    }
                    Button(action: chooseFolder) {
                        Label("Add Folder…", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(model.busy || model.loadFailed)
                    ForEach(quickFolders, id: \.self) { url in
                        Button { Task { await model.addFolder(url.path(percentEncoded: false)) } } label: {
                            Label("Add \(url.lastPathComponent)", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .disabled(model.busy)
                    }
                } header: {
                    Text("Folders")
                } footer: {
                    Text("Rays files new items into folders like Work and Personal. It runs on your Mac; nothing is uploaded.")
                }

                Section("Recent activity") {
                    let moves = model.status?.recent ?? []
                    if moves.isEmpty {
                        Text("Nothing sorted yet.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(moves.prefix(10).enumerated()), id: \.offset) { _, move in
                        MoveRow(move: move)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Sorter")
        .toolbar { ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() } }
            .navigationSubtitle(watchedCount == 1 ? "1 folder watched" : "\(watchedCount) folders watched")
            .navigationDestination(for: String.self) { path in
                SorterFolderPage(model: model, path: path)
            }
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(10))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refresh() }
            }
        }
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
}

private struct FolderRow: View {
    let folder: SorterFolder

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(folder.name)
                if folder.needsUpdate {
                    Label("Old copy — needs update", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Text(folder.watching ? "Sorting new files" : "Paused")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct MoveRow: View {
    let move: SorterMove

    var body: some View {
        HStack(spacing: 12) {
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
            Spacer(minLength: 8)
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
