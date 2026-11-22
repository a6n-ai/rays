import AppKit
import SwiftUI

@main
struct RaysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AppearanceChoice.key) private var appearance = AppearanceChoice.system
    @AppStorage(SettingsKey.menuBar) private var showsMenuBar = true

    var body: some Scene {
        Window("Rays", id: "main") {
            ContentView()
                .environment(appDelegate.model)
                .background(OpenSettingsAtLaunch())
        }
        .defaultSize(width: 760, height: 520)
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

        MenuBarExtra(isInserted: $showsMenuBar) {
            MenuBarPanel().environment(appDelegate.model)
        } label: {
            MenuBarLabel().environment(appDelegate.model)
        }
        .menuBarExtraStyle(.window)
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
        sizeWindowOnce()
        Updater.shared.checkIfDue()
        dock = DockProgress(model: model)
    }
    private var dock: DockProgress?

    /// Earlier builds opened at 640x480 and macOS keeps that size, so `defaultSize` never applies.
    /// Set the new default size once; afterwards the size the user picks is kept.
    private func sizeWindowOnce() {
        let key = "windowSized760"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Rays" }) else { return }
            let target = NSSize(width: 760, height: 520)
            var frame = window.frame
            frame.origin.y += frame.height - target.height
            frame.size = target
            window.setFrame(frame, display: true)
            window.center()
            UserDefaults.standard.set(true, forKey: key)
        }
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

    // With the menu bar item on, Rays keeps downloading after the window closes, like other download managers.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: SettingsKey.menuBar) as? Bool ?? true)
    }

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
