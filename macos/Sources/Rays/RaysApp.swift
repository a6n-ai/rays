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
        .defaultSize(width: 760, height: 720)
        .windowToolbarStyle(.unified)
        .onChange(of: appearance, initial: true) { _, new in NSApp.appearance = new.nsAppearance }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    if appDelegate.model.removalPill != nil { appDelegate.model.undoRemoval() }
                    else { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                }
                .keyboardShortcut("z")
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Menu("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppearanceChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
            }
            CommandGroup(after: .help) {
                Button("Send feedback…") { Feedback.sendFeedback() }
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
    /// SwiftUI owns the delegate, so `NSApp.delegate` is not this class; App Intents reach the model through here.
    static weak var shared: AppDelegate?

    override init() {
        super.init()
        Self.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Backs the "Download with Rays" item in every app's Services menu (declared in Info.plist).
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        sizeWindowOnce()
        Updater.shared.checkIfDue()
        // After launch finishes, so the alert doesn't hold up the first window.
        Task { @MainActor in Feedback.offerCrashReportIfNeeded() }
        dock = DockProgress(model: model)
        clipboard = ClipboardWatcher(model: model)
    }
    private var dock: DockProgress?
    private var clipboard: ClipboardWatcher?

    /// Right-click on the Dock icon: hide to the menu bar, where downloads keep going and Quit Rays quits.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Keep Downloading in Menu Bar", action: #selector(hideToMenuBar), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// Closes the windows and takes Rays out of the Dock; the menu bar item (turned on if it was off) brings it back.
    @objc func hideToMenuBar() {
        UserDefaults.standard.set(true, forKey: SettingsKey.menuBar)
        for window in NSApp.windows where window.isVisible && window.canBecomeMain {
            window.close()
        }
        NSApp.setActivationPolicy(.accessory)
    }

    /// `rays://add?url=<encoded>` (repeatable), from the Share extension, puts the links in the add bar.
    /// `rays://install-helpers`, from the browser extension when its helper is missing: installs the helper for every
    /// installed browser (each only lets the Rays extension in) and shows Settings > Browsers with the result.
    func application(_ application: NSApplication, open urls: [URL]) {
        let adds = urls.filter { $0.scheme == "rays" && $0.host() == "add" }
        if !adds.isEmpty {
            var links: [String] = []
            for add in adds {
                for item in URLComponents(url: add, resolvingAgainstBaseURL: false)?.queryItems ?? [] where item.name == "url" {
                    guard let value = item.value, !links.contains(value) else { continue }
                    let scheme = URL(string: value)?.scheme?.lowercased() ?? ""
                    if scheme == "http" || scheme == "https" { links.append(value) }
                }
            }
            if !links.isEmpty {
                // A web page can open rays:// links, so they only fill the add bar; the user presses Download.
                model.pendingAdd = links.joined(separator: "\n")
                Self.showInDock()
            }
        }
        guard urls.contains(where: { $0.scheme == "rays" && $0.host() == "install-helpers" }) else { return }
        for browser in BrowserCheck.browsers where browser.engine != .safari && BrowserCheck.appURL(for: browser) != nil {
            try? BrowserCheck.installHelper(browser)
        }
        UserDefaults.standard.set("browsers", forKey: "settingsTab")
        Self.showInDock()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    /// Puts Rays back in the Dock and in front, for a window opened from the menu bar.
    static func showInDock() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    /// Earlier builds opened at 640x480 and macOS keeps that size, so `defaultSize` never applies.
    /// Set the new default size once; afterwards the size the user picks is kept.
    private func sizeWindowOnce() {
        let key = "windowSized760x720"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Rays" }) else { return }
            let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 760, height: 720)
            let target = NSSize(width: min(760, visible.width), height: min(720, visible.height))
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
            alert.addButton(withTitle: "Quit anyway")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}
