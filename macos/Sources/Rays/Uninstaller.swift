import AppKit
import SwiftUI

/// Removes everything Rays set up outside its bundle, then moves the app to the Trash.
/// Only offered for a copy in /Applications, so a development build never removes itself.
enum Uninstaller {
    static var appURL: URL { Bundle.main.bundleURL }
    static var canUninstall: Bool { appURL.deletingLastPathComponent().path == "/Applications" }
    static let dataDir = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/Rays", directoryHint: .isDirectory)

    /// Returns problems that did not stop the uninstall (shown before quitting is skipped).
    @MainActor
    static func run(deleteData: Bool) async -> [String] {
        var problems: [String] = []

        let sorter = SorterModel()
        await sorter.refresh()
        for folder in sorter.status?.folders ?? [] { await sorter.remove(folder) }
        if let error = sorter.error { problems.append("Sorter: \(error)") }

        for browser in BrowserCheck.browsers {
            try? BrowserCheck.removeHelper(browser) // a browser without a helper has nothing to remove
        }

        if case .installed(let link) = CommandLineTool.state(),
           link.resolvingSymlinksInPath().path == CommandLineTool.bundled.resolvingSymlinksInPath().path {
            do { try CommandLineTool.uninstall(link) } catch { problems.append("dl: \(error.localizedDescription)") }
        }

        if deleteData {
            try? FileManager.default.removeItem(at: dataDir)
            if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        }

        do {
            try await NSWorkspace.shared.recycle([appURL])
        } catch {
            problems.append("Could not move Rays to the Trash: \(error.localizedDescription)")
        }
        return problems
    }
}

struct UninstallSection: View {
    @State private var confirm = false
    @State private var working = false
    @State private var problems: [String] = []

    var body: some View {
        Section {
            Button {
                confirm = true
            } label: {
                Text(working ? "Uninstalling…" : "Uninstall Rays…").frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Uninstaller.canUninstall ? .red : .secondary)
            .disabled(!Uninstaller.canUninstall || working)
            .help(Uninstaller.canUninstall ? "Remove Rays from this Mac" : "Only a copy in Applications can uninstall itself.")
            .confirmationDialog("Uninstall Rays?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Uninstall", role: .destructive) { start(deleteData: false) }
                Button("Uninstall and delete data", role: .destructive) { start(deleteData: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Rays stops sorting your folders, removes its browser helpers and the dl command, and moves itself to the Trash. Your downloads and sorted files stay where they are. Uninstall and delete data also removes download history and settings.")
            }
            ForEach(problems, id: \.self) { ErrorLine(text: $0) }
        } footer: {
            if !Uninstaller.canUninstall {
                Text("This copy of Rays isn't in Applications, so it can't uninstall itself.")
            }
        }
    }

    private func start(deleteData: Bool) {
        working = true
        Task {
            problems = await Uninstaller.run(deleteData: deleteData)
            working = false
            if problems.isEmpty { NSApp.terminate(nil) }
        }
    }
}
