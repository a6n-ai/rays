import SwiftUI

/// One level of a bucket: folders open in place, objects download with the normal engine.
struct BucketView: View {
    @Environment(EngineModel.self) private var model
    let bucket: String
    @State private var prefix = ""
    @State private var folders: [String] = []
    @State private var objects: [BucketObject] = []
    @State private var nextToken: String?
    @State private var loading = false
    @State private var error: String?
    @State private var added = Set<String>()

    var body: some View {
        List {
            if let error {
                ErrorLine(text: error)
            } else if !loading && folders.isEmpty && objects.isEmpty {
                Text(prefix.isEmpty ? "This bucket is empty." : "This folder is empty.")
                    .foregroundStyle(.secondary)
            }
            ForEach(folders, id: \.self) { folder in
                Button {
                    prefix = folder
                } label: {
                    Label(Self.leaf(folder), systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(objects, id: \.key) { object in
                HStack {
                    Label(Self.leaf(object.key), systemImage: "doc")
                    Spacer()
                    Text(byteText(object.size))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button {
                        model.download(bucket: bucket, key: object.key)
                        if model.notice == nil { added.insert(object.key) }
                    } label: {
                        Image(systemName: added.contains(object.key) ? "checkmark.circle.fill" : "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(added.contains(object.key) ? "Added to Downloads" : "Download")
                    .accessibilityLabel("Download \(Self.leaf(object.key))")
                }
            }
            if let nextToken, !loading {
                Button("Load More") { Task { await load(token: nextToken) } }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(bucket)
        .navigationSubtitle(prefix)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button("Up", systemImage: "chevron.left") { prefix = Self.parent(prefix) }
                    .disabled(prefix.isEmpty)
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await load(token: nil) } }
            }
        }
        .task(id: prefix) { await load(token: nil) }
    }

    /// nil starts the level over; a token appends the next page.
    private func load(token: String?) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await model.listBucket(bucket, prefix: prefix, token: token)
            if token == nil {
                folders = page.folders
                objects = page.objects
            } else {
                folders += page.folders
                objects += page.objects
            }
            nextToken = page.nextToken
            error = nil
        } catch {
            self.error = EngineModel.message(for: error)
        }
    }

    static func leaf(_ key: String) -> String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/").last.map(String.init) ?? trimmed
    }

    /// "a/b/" goes up to "a/"; a top-level folder goes back to the bucket root.
    static func parent(_ prefix: String) -> String {
        var parts = prefix.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.isEmpty else { return "" }
        parts.removeLast()
        return parts.isEmpty ? "" : parts.joined(separator: "/") + "/"
    }
}
