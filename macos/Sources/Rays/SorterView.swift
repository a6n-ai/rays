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

    @State private var confirmRemoveAll = false
    @State private var removing: SorterFolder?
    private var outdated: [SorterFolder] { (model.status?.folders ?? []).filter(\.needsUpdate) }

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

                if !outdated.isEmpty {
                    Section {
                        UpdateAllRow(count: outdated.count, busy: model.busy) {
                            Task { for folder in outdated { await model.update(folder) } }
                        }
                    }
                }
                Section {
                    ForEach(model.status?.folders ?? []) { folder in
                        NavigationLink(value: folder.path) {
                            HStack {
                                FolderRow(folder: folder)
                                Spacer(minLength: 8)
                                rowIcon("wand.and.stars", "Sort \(folderName(folder)) now",
                                        tint: AIReadinessStore.shared.value.isReady ? .purple : .secondary) {
                                    Task { await model.sortNow(folder) }
                                }
                                .disabled(model.busy || !AIReadinessStore.shared.value.isReady)
                                rowIcon("folder", "Show \(folderName(folder)) in Finder", tint: .blue) {
                                    NSWorkspace.shared.open(URL(filePath: folder.path))
                                }
                                rowIcon("trash", "Remove \(folderName(folder)) from the sorter", tint: .red) {
                                    removing = folder
                                }
                            }
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
                if !(model.status?.folders ?? []).isEmpty {
                    Section {
                        Button(role: .destructive) { confirmRemoveAll = true } label: {
                            Text("Remove Sorter…").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red)
                        .disabled(model.busy)
                        .confirmationDialog("Remove the sorter from all folders?", isPresented: $confirmRemoveAll,
                                            titleVisibility: .visible) {
                            Button("Remove Sorter", role: .destructive) {
                                Task { for folder in model.status?.folders ?? [] { await model.remove(folder) } }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Files already sorted stay where they are.")
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .confirmationDialog("Remove \(removing.map { URL(filePath: $0.path).lastPathComponent } ?? "this folder") from the sorter?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove Folder", role: .destructive) {
                    if let folder = removing { Task { await model.remove(folder) } }
                    removing = nil
                }
                Button("Cancel", role: .cancel) { removing = nil }
            } message: {
                Text("Files already sorted stay where they are.")
            }
            .scrollContentBackground(.hidden)
            // Same title and toolbar skeleton as Downloads, so switching pages doesn't jump.
            .navigationTitle("Rays")
            .navigationSubtitle(watchedCount == 1 ? "Sorter: 1 folder watched" : "Sorter: \(watchedCount) folders watched")
            .toolbar {
                ToolbarItem(placement: .principal) {
                    ToolbarIconGroup {
                        Button(action: chooseFolder) {
                            ToolbarIcon(symbol: "folder.badge.plus", title: "Add folder")
                        }
                        .buttonStyle(.plain)
                        .help("Add a folder to sort")
                        Button { Task { await sortAll() } } label: {
                            ToolbarIcon(symbol: "wand.and.stars", title: "Sort all now",
                                        tint: AIReadinessStore.shared.value.isReady ? .purple : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.busy || !AIReadinessStore.shared.value.isReady)
                        .help(AIReadinessStore.shared.value.isReady ? "Sort new files in every watched folder now" : AIReadinessStore.shared.value.title)
                        Button { Task { await model.refresh() } } label: {
                            ToolbarIcon(symbol: "arrow.clockwise", title: "Refresh")
                        }
                        .buttonStyle(.plain)
                        .help("Check folders and recent activity again")
                    }
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { ToolbarActions() }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .primaryAction) { SettingsToolbarButton() }
            }
            .navigationDestination(for: String.self) { path in
                SorterFolderPage(model: model, path: path)
            }
            .task {
                while !Task.isCancelled {
                    await model.refresh()
                    try? await Task.sleep(for: .seconds(30))
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

    private func folderName(_ folder: SorterFolder) -> String { URL(filePath: folder.path).lastPathComponent }

    /// Small borderless icon button inside a list row; borderless so the click doesn't open the row.
    private func rowIcon(_ symbol: String, _ label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }

    private func sortAll() async {
        for folder in model.status?.folders ?? [] where folder.watching {
            await model.sortNow(folder)
        }
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


/// Explains what "old copy" means and switches every outdated folder to the bundled sorter at once.
private struct UpdateAllRow: View {
    let count: Int
    let busy: Bool
    let updateAll: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            SettingIcon(symbol: "exclamationmark.triangle.fill", color: .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(count == 1 ? "1 folder needs an update" : "\(count) folders need an update")
                    .font(.callout.weight(.semibold))
                Text("Switch to the sorter built into Rays. Nothing is moved.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("Update All", action: updateAll)
                .buttonStyle(.glassProminent)
                .disabled(busy)
        }
        .accessibilityElement(children: .combine)
    }
}
