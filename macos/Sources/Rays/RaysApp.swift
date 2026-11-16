import AppKit
import SwiftUI

@main
struct RaysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system

    var body: some Scene {
        Window("Rays", id: "main") {
            ContentView()
                .environment(appDelegate.model)
                .background(OpenSettingsAtLaunch())
        }
        .defaultSize(width: 640, height: 480)
        .windowToolbarStyle(.unified)
        .onChange(of: appearance, initial: true) { _, new in NSApp.appearance = new.nsAppearance }
        .commands {
            CommandGroup(after: .sidebar) {
                Menu("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
        }
    }
}

// Opens Settings at launch; used for screenshots and support.
private struct OpenSettingsAtLaunch: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.task {
            if UserDefaults.standard.bool(forKey: "RaysOpenSettings") { openSettings() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = EngineModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Backs the "Download with Rays" item in every app's Services menu (declared in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Keeps the stable extension copy in step with this build, so a loaded extension stays current.
        BrowserCheck.prepareExtensionFolder()
    }

    /// Services entry point: takes links (or text containing links) from the sender's selection.
    @objc func downloadWithRays(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        var links: [String] = []
        if let urls = pboard.readObjects(forClasses: [NSURL.self]) as? [URL] {
            links += urls.filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }.map(\.absoluteString)
        }
        if let text = pboard.string(forType: .string) {
            links += Links.inText(text)
        }
        var seen = Set<String>()
        links = links.filter { seen.insert($0).inserted }
        guard !links.isEmpty else {
            error.pointee = "No web link found in the selection." as NSString
            return
        }
        model.add(links.joined(separator: "\n"))
    }

    // Closing the only window quits, so the quit path (warning and shutdown) always runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let lost = model.unresumableActive
        if !lost.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Quit and stop these downloads?"
            alert.informativeText = lost
                .map { "\($0.name): stopping loses \(byteText($0.done)) of progress." }
                .joined(separator: "\n") + "\n\nStop anyway?"
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Quit Anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}
