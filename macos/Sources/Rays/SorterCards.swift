import AppKit
import SwiftUI

let sorterCardShape = RoundedRectangle(cornerRadius: 12, style: .continuous)

struct FolderCard: View {
    let model: SorterModel
    let folder: SorterFolder
    let categories: [SorterCategory]
    let onRemove: () -> Void

    @State private var showsDestinations = false

    private static let colors: [Color] = [.blue, .green, .orange, .purple, .pink, .teal, .indigo]

    private var elsewhereCount: Int {
        categories.filter { model.destination(for: folder, category: $0.name) != nil }.count
    }

    var body: some View {
        let readiness = AIReadiness.current()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                    .resizable()
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(URL(filePath: folder.path).tildePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(
                    get: { folder.watching },
                    set: { on in Task { await model.setWatching(folder, on: on) } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .accessibilityLabel("Watching \(folder.name)")
                    .disabled(model.busy || model.loadFailed)
            }

            if folder.watching {
                Label {
                    Text("Sorting new files").font(.callout)
                } icon: {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
            } else {
                Label("Paused", systemImage: "pause.circle").font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let agent = folder.agentBinary, !isBundled(agent) {
                HStack(spacing: 8) {
                    Label {
                        Text("Old copy").font(.callout)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button("Update") { Task { await model.update(folder) } }
                        .controlSize(.small)
                        .buttonStyle(.glass)
                        .disabled(model.busy)
                }
            }

            Label {
                Text(destinationSummary)
            } icon: {
                Image(systemName: "arrow.triangle.branch")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Button("Sort Now") { Task { await model.sortNow(folder) } }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                    .disabled(model.busy || model.loadFailed || !readiness.isReady)
                    .help(readiness.isReady ? "Sort new files in this folder now" : readiness.title)
                Button("Destinations") { showsDestinations = true }
                    .controlSize(.small)
                    .buttonStyle(.glass)
                Spacer(minLength: 0)
                Menu {
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(filePath: folder.path)) }
                    Divider()
                    Button("Remove Folder…", role: .destructive, action: onRemove)
                        .disabled(model.busy)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("More actions for \(folder.name)")
                .help("More actions")
            }

            if let result = model.sortResults[folder.path] {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary, in: sorterCardShape)
        .overlay(sorterCardShape.strokeBorder(.separator, lineWidth: 1))
        .sheet(isPresented: $showsDestinations) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Where files from \(folder.name) go")
                    .font(.headline)
                Form {
                    ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                        CategoryRow(model: model, folder: folder, category: category,
                                    color: Self.colors[index % Self.colors.count])
                    }
                }
                .formStyle(.grouped)
                HStack {
                    Spacer()
                    Button("Done") { showsDestinations = false }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.glassProminent)
                }
            }
            .padding(LayoutMetrics.margin)
            .frame(width: 560)
        }
    }

    private var destinationSummary: String {
        switch elsewhereCount {
        case 0: "All topics stay inside \(folder.name)"
        case 1: "1 topic goes elsewhere"
        default: "\(elsewhereCount) topics go elsewhere"
        }
    }

    private func isBundled(_ path: String) -> Bool {
        URL(filePath: path).resolvingSymlinksInPath() == URL(filePath: Sorter.defaultPath).resolvingSymlinksInPath()
    }
}

struct AddFolderTile: View {
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 22))
                Text("Add Folder")
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(sorterCardShape)
            .overlay(sorterCardShape.stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
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
