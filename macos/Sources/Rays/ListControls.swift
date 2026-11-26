import SwiftUI
import UniformTypeIdentifiers

/// What a file is, from its extension, for the list filters.
enum FileKind: String, CaseIterable, Identifiable {
    case all = "All types", documents = "Documents", images = "Images", video = "Video", audio = "Audio"
    case archives = "Archives", apps = "Apps and installers", other = "Other"

    var id: Self { self }

    static func of(_ name: String) -> FileKind {
        guard let type = UTType(filenameExtension: (name as NSString).pathExtension) else { return .other }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .diskImage) || type.conforms(to: .application) || type.conforms(to: .executable)
            || type.identifier == "com.apple.installer-package-archive" { return .apps }
        if type.conforms(to: .archive) { return .archives }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .epub) || type.conforms(to: .compositeContent) { return .documents }
        return .other
    }

    func matches(_ name: String) -> Bool { self == .all || Self.of(name) == self }
}

enum ListSort: String, CaseIterable, Identifiable {
    case newest = "Newest first", fastest = "Fastest", oldest = "Oldest first", name = "Name", size = "Largest first", nextRun = "Next run"
    var id: Self { self }
}

/// Filter and sort menus and page buttons above a list. `statuses` empty hides the status filter; `sorts` is the
/// orders this list can offer.
struct ListControls: View {
    var statuses: [String] = []
    @Binding var status: String
    @Binding var kind: FileKind
    /// False for lists that are not files, such as queues.
    var showsKind = true
    var sorts: [ListSort] = [.newest, .oldest, .name, .size]
    @Binding var sort: ListSort
    let count: Int
    @Binding var page: Int
    /// Shown as a Remove Missing button: clears rows whose finished file was moved or deleted.
    var removeMissing: (() -> Void)? = nil
    /// `.menus` goes in the list's section header, `.paging` stays above the page.
    enum Part { case all, menus, paging }
    var part = Part.all

    private var filtered: Bool { (showsKind && kind != .all) || (statuses.first.map { status != $0 } ?? false) }

    var body: some View {
        HStack(spacing: 10) {
            if part != .paging { menus }
            Spacer()
            if part != .menus { PageBar(count: count, page: $page) }
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, part == .menus ? 0 : LayoutMetrics.margin)
        .padding(.vertical, part == .menus ? 0 : 6)
        .onChange(of: kind) { _, _ in page = 0 }
        .onChange(of: status) { _, _ in page = 0 }
        .onChange(of: sort) { _, _ in page = 0 }
    }

    @ViewBuilder private var menus: some View {
            Menu {
                if !statuses.isEmpty {
                    Picker("Status", selection: $status) {
                        ForEach(statuses, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                if showsKind {
                    Picker("Type", selection: $kind) {
                        ForEach(FileKind.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                Label(filtered ? "Filtered" : "Filter", systemImage: filtered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }
            .fixedSize()
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(sorts) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sort.rawValue, systemImage: "arrow.up.arrow.down")
            }
            .fixedSize()
            if let removeMissing {
                Button(action: removeMissing) { Label("Remove missing", systemImage: "trash.slash") }
                    .help("Remove finished downloads whose file was moved or deleted. Files that are still there stay.")
            }
    }

    /// The items on the current page. `size` is the `Paging.key` setting, read with @AppStorage by the caller so the list redraws when it changes.
    static func page<T>(_ items: [T], _ page: Int, _ size: Int) -> ArraySlice<T> {
        let start = min(items.count, page * size)
        return items[start..<min(items.count, start + size)]
    }
}

/// The page size every list shares.
enum Paging {
    static let key = "listPageSize"
    static let defaultSize = 50
    static let sizes = [25, 50, 100, 200]
}

/// Page-size menu, arrows and range for one list. The menu shows only when the list is longer than the smallest size, the arrows
/// only when it spans several pages. `padded` is for a bar on its own, outside ListControls.
struct PageBar: View {
    let count: Int
    @Binding var page: Int
    var padded = false
    @AppStorage(Paging.key) private var size = Paging.defaultSize

    private var pages: Int { max(1, (count + size - 1) / size) }

    var body: some View {
        Group {
            if !padded {
                controls
            } else if count > Paging.sizes[0] {
                HStack(spacing: 10) {
                    Spacer()
                    controls
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, LayoutMetrics.margin)
                .padding(.vertical, 6)
            }
        }
        // Back to a page that exists when a filter shrinks the list.
        .onChange(of: count) { _, _ in page = min(page, pages - 1) }
        .onChange(of: size) { _, _ in page = 0 }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if count > Paging.sizes[0] {
                Menu {
                    Picker("Per page", selection: $size) {
                        ForEach(Paging.sizes, id: \.self) { Text("\($0) per page").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("\(size) per page")
                }
                .menuStyle(.button)
                .fixedSize()
                .help("How many items each list shows at once")
            }
            if pages > 1 {
                Button { page -= 1 } label: { Image(systemName: "chevron.left") }
                    .disabled(page == 0)
                    .help("Previous page")
                Text("\(page * size + 1)–\(min(count, (page + 1) * size)) of \(count)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button { page += 1 } label: { Image(systemName: "chevron.right") }
                    .disabled(page >= pages - 1)
                    .help("Next page")
            }
        }
    }
}

extension JobView {
    /// The status filter's choices for download lists.
    static let statuses = ["All", "Active", "Finished", "Failed"]
}

extension Array where Element == JobView {
    /// Filtered by status (one of `JobView.statuses`) and kind, then sorted.
    func listed(status: String, kind: FileKind, sort: ListSort) -> [JobView] {
        let jobs = filter { job in
            let byStatus = switch status {
            case "Active": !job.isFinished
            case "Finished": job.isDone
            case "Failed": if case .failed = job.state { true } else { false }
            default: true
            }
            return byStatus && kind.matches(job.name)
        }
        // Ids grow with each new download, so they order by when it was added.
        return switch sort {
        case .newest, .nextRun, .fastest: jobs.sorted { $0.id > $1.id }
        case .oldest: jobs.sorted { $0.id < $1.id }
        case .name: jobs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size: jobs.sorted { ($0.total ?? $0.done) > ($1.total ?? $1.done) }
        }
    }
}
