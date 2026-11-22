import AppKit
import Foundation
import Observation

/// Reads browser files to report helper and extension status. Only `installHelper` writes, and only on a click.
enum BrowserCheck {
    static let hostName = "ai.a6n.rays"
    static let chromeID = "mgepiogdappnhmohefhalmeppkfciail"
    static let firefoxID = "rays@a6n.ai"
    static let manifestName = "\(hostName).json"
    static let chromeStoreURL = URL(string: "https://chromewebstore.google.com/detail/\(chromeID)")!
    static let firefoxStoreURL = URL(string: "https://addons.mozilla.org/firefox/addon/\(firefoxID)/")!
    static let addonNotFoundNote = "Rays couldn't find it in any Firefox profile. Add it from Firefox Add-ons."

    enum Engine: Sendable { case chromium, firefox, safari }

    struct Browser: Identifiable, Hashable, Sendable {
        let bundleID: String
        let name: String
        let engine: Engine
        /// Relative to ~/Library/Application Support.
        let support: String?
        /// Relative to ~/Library/Application Support.
        let hostDir: String?
        var helperNote: String? = nil

        var id: String { bundleID }
    }

    static let browsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", engine: .chromium,
                support: "Google/Chrome", hostDir: "Google/Chrome/NativeMessagingHosts"),
        Browser(bundleID: "com.brave.Browser", name: "Brave", engine: .chromium,
                support: "BraveSoftware/Brave-Browser", hostDir: "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
        Browser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", engine: .chromium,
                support: "Microsoft Edge", hostDir: "Microsoft Edge/NativeMessagingHosts"),
        Browser(bundleID: "org.chromium.Chromium", name: "Chromium", engine: .chromium,
                support: "Chromium", hostDir: "Chromium/NativeMessagingHosts"),
        Browser(bundleID: "company.thebrowser.Browser", name: "Arc", engine: .chromium,
                support: "Arc/User Data", hostDir: "Arc/User Data/NativeMessagingHosts"),
        Browser(bundleID: "org.mozilla.firefox", name: "Firefox", engine: .firefox,
                support: "Firefox", hostDir: "Mozilla/NativeMessagingHosts"),
        Browser(bundleID: "app.zen-browser.zen", name: "Zen", engine: .firefox,
                support: "zen", hostDir: "Mozilla/NativeMessagingHosts",
                helperNote: "Zen and Firefox share one helper."),
        Browser(bundleID: "ai.perplexity.comet", name: "Comet", engine: .chromium,
                support: "Comet", hostDir: "Comet/NativeMessagingHosts"),
        Browser(bundleID: "com.apple.Safari", name: "Safari", engine: .safari, support: nil, hostDir: nil),
    ]

    enum Helper: Equatable, Sendable {
        case ok
        case broken(String)
        case missing
    }

    enum Addon: Equatable, Sendable {
        case added
        case notAdded
        case unknown(String)
    }

    struct State: Identifiable, Sendable {
        let browser: Browser
        let appURL: URL
        let helper: Helper
        let addon: Addon

        var id: String { browser.bundleID }
    }

    /// The native host runs the copy inside the app bundle, so the manifest points there.
    static var dlURL: URL { Bundle.main.bundleURL.appending(path: "Contents/MacOS/dl") }

    /// Opens the extension's store page in that browser itself: a Chrome Web Store page in Safari can't install anything.
    static func openStore(in browser: Browser) {
        guard let store = storeURL(for: browser.engine) else { return }
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID) {
            NSWorkspace.shared.open([store], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(store)
        }
    }

    static func storeURL(for engine: Engine) -> URL? {
        switch engine {
        case .chromium: chromeStoreURL
        case .firefox: firefoxStoreURL
        case .safari: nil
        }
    }

    static func appURL(for browser: Browser) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID)
    }

    static func supportURL(_ relative: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/\(relative)")
    }

    static func state(for browser: Browser, appURL: URL) -> State {
        let helper = browser.hostDir.map { helperStatus(in: supportURL($0)) } ?? .missing
        return State(browser: browser, appURL: appURL, helper: helper, addon: addonStatus(for: browser))
    }

    static func helperStatus(in hostDir: URL) -> Helper {
        let fm = FileManager.default
        let manifest = hostDir.appending(path: manifestName)
        guard fm.fileExists(atPath: manifest.path(percentEncoded: false)) else { return .missing }
        guard let data = try? Data(contentsOf: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String
        else { return .broken("the helper file can't be read") }
        guard fm.isExecutableFile(atPath: path) else {
            return .broken(fm.fileExists(atPath: path) ? "Rays can't be run from there" : "Rays was moved or deleted")
        }
        return .ok
    }

    static func addonStatus(for browser: Browser) -> Addon {
        guard let support = browser.support else { return .notAdded }
        let root = supportURL(support)
        switch browser.engine {
        case .chromium: return chromiumAddon(root: root)
        case .firefox: return firefoxAddon(root: root)
        case .safari: return .notAdded
        }
    }

    static func chromiumAddon(root: URL) -> Addon {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for name in names where name == "Default" || name.hasPrefix("Profile ") {
            for file in ["Secure Preferences", "Preferences"] {
                guard let data = try? Data(contentsOf: root.appending(path: "\(name)/\(file)")),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = json["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      settings[chromeID] != nil
                else { continue }
                return .added
            }
        }
        return .notAdded
    }

    static func firefoxAddon(root: URL) -> Addon {
        let profiles = root.appending(path: "Profiles")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: profiles.path(percentEncoded: false))) ?? []
        for name in names {
            guard let data = try? Data(contentsOf: profiles.appending(path: "\(name)/extensions.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = json["addons"] as? [[String: Any]],
                  addons.contains(where: { ($0["id"] as? String) == firefoxID })
            else { continue }
            return .added
        }
        return .unknown(addonNotFoundNote)
    }

    static func installHelper(_ browser: Browser) throws {
        guard let hostDir = browser.hostDir else { return }
        var manifest: [String: Any] = [
            "name": hostName,
            "description": "Rays download manager",
            "path": dlURL.path(percentEncoded: false),
            "type": "stdio",
        ]
        if browser.engine == .firefox {
            manifest["allowed_extensions"] = [firefoxID]
        } else {
            manifest["allowed_origins"] = ["chrome-extension://\(chromeID)/"]
        }
        let dir = supportURL(hostDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: dir.appending(path: manifestName), options: .atomic)
    }

    /// Deletes Rays' helper manifest for this browser, and only if it is ours (name `ai.a6n.rays`).
    static func removeHelper(_ browser: Browser) throws {
        guard let hostDir = browser.hostDir else { return }
        let file = supportURL(hostDir).appending(path: manifestName)
        guard let data = try? Data(contentsOf: file) else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["name"] as? String == hostName else { return }
        try FileManager.default.removeItem(at: file)
    }
}

@MainActor
@Observable
final class BrowserCheckModel {
    private(set) var states: [BrowserCheck.State] = []
    private(set) var loaded = false
    private(set) var failures: [String: String] = [:]

    /// Installed lookup runs here; file reads run off the main actor.
    func refresh() {
        let installed = BrowserCheck.browsers.compactMap { browser in
            BrowserCheck.appURL(for: browser).map { (browser, $0) }
        }
        Task {
            states = await Task.detached {
                installed.map { BrowserCheck.state(for: $0.0, appURL: $0.1) }
            }.value
            loaded = true
        }
    }

    /// Writes the helper manifest for every listed browser that lacks a working one (Safari excluded).
    func installAllHelpers(_ states: [BrowserCheck.State]) {
        for state in states where state.browser.engine != .safari && state.helper != .ok {
            do {
                try BrowserCheck.installHelper(state.browser)
                failures[state.browser.bundleID] = nil
            } catch {
                failures[state.browser.bundleID] = error.localizedDescription
            }
        }
        refresh()
    }

    func removeHelper(_ state: BrowserCheck.State) {
        do {
            try BrowserCheck.removeHelper(state.browser)
            failures[state.browser.bundleID] = nil
        } catch {
            failures[state.browser.bundleID] = error.localizedDescription
        }
        refresh()
    }

    func removeAllHelpers() {
        for state in states where state.helper != .missing {
            do { try BrowserCheck.removeHelper(state.browser) } catch {
                failures[state.browser.bundleID] = error.localizedDescription
            }
        }
        refresh()
    }

    func installHelper(_ state: BrowserCheck.State) {
        do {
            try BrowserCheck.installHelper(state.browser)
            failures[state.browser.bundleID] = nil
        } catch {
            failures[state.browser.bundleID] = error.localizedDescription
        }
        refresh()
    }
}
