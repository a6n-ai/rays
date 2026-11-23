import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

/// Reads browser files to report helper and extension status. Only `installHelper` writes, and only on a click.
enum BrowserCheck {
    static let hostName = "ai.a6n.rays"
    static let chromeID = "mgepiogdappnhmohefhalmeppkfciail"
    static let firefoxID = "rays@a6n.ai"
    static let manifestName = "\(hostName).json"
    static let chromeHostDir = "Google/Chrome/NativeMessagingHosts"
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
        /// Also written on install and removed on uninstall, for versions of the browser that read their own folder.
        var alsoHostDir: String? = nil

        var id: String { bundleID }
    }

    static let browsers: [Browser] = [
        Browser(bundleID: "com.google.Chrome", name: "Google Chrome", engine: .chromium,
                support: "Google/Chrome", hostDir: "Google/Chrome/NativeMessagingHosts"),
        Browser(bundleID: "com.brave.Browser", name: "Brave", engine: .chromium,
                // Brave reads helpers from Chrome's folder (seen in Brave 1.100's log: its own folder is never read).
                support: "BraveSoftware/Brave-Browser", hostDir: "Google/Chrome/NativeMessagingHosts",
                helperNote: "Brave and Chrome share one helper.",
                alsoHostDir: "BraveSoftware/Brave-Browser/NativeMessagingHosts"),
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

    /// An installed browser Rays has no extension setup for: listed so people see why it is missing.
    struct OtherBrowser: Identifiable, Sendable {
        let bundleID: String
        let name: String
        let appURL: URL
        /// Built on Chromium (a `… Framework.framework` inside), so it may take the Chrome Web Store extension.
        let chromium: Bool

        var id: String { bundleID }
    }

    /// Apps in the Applications folders that open both web links and .html files (a download manager opens links but
    /// not pages), other than the browsers Rays supports. Copies elsewhere (disk images, test builds) are skipped.
    static func otherBrowsers() -> [OtherBrowser] {
        let ws = NSWorkspace.shared
        let pages = Set(ws.urlsForApplications(toOpen: .html).map(\.standardizedFileURL))
        let folders = ["/Applications/", FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/"]
        let known = Set(browsers.map(\.bundleID) + [Bundle.main.bundleIdentifier ?? ""])
        var seen = Set<String>()
        return ws.urlsForApplications(toOpen: URL(string: "https://example.com")!).compactMap { url in
            let url = url.standardizedFileURL
            guard pages.contains(url), folders.contains(where: url.path.hasPrefix),
                  let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !known.contains(id), seen.insert(id).inserted
            else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") ?? bundle.object(forInfoDictionaryKey: "CFBundleName")) as? String
            let frameworks = (try? FileManager.default.contentsOfDirectory(atPath: url.appending(path: "Contents/Frameworks").path)) ?? []
            let chromium = frameworks.contains { $0.hasSuffix(" Framework.framework") && !$0.hasPrefix("Electron") }
            return OtherBrowser(bundleID: id, name: name ?? url.deletingPathExtension().lastPathComponent, appURL: url, chromium: chromium)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
        return State(browser: browser, appURL: appURL, helper: helper, addon: addonStatus(for: browser, appURL: appURL))
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

    /// Browsers whose extension has talked to the helper, written by `dl` each time (app path: seen time).
    static func seenBrowsers() -> Set<String> {
        let file = supportURL("Rays/browsers.json")
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return Set(json.keys)
    }

    static func appKey(_ url: URL) -> String {
        url.standardizedFileURL.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    static func addonStatus(for browser: Browser, appURL: URL) -> Addon {
        // The extension reporting in is proof it is added, and works where macOS keeps Rays out of the profile.
        if seenBrowsers().contains(where: { appKey(URL(filePath: $0)) == appKey(appURL) }) { return .added }
        guard let support = browser.support else { return .notAdded }
        let root = supportURL(support)
        switch browser.engine {
        case .chromium: return chromiumAddon(root: root, name: browser.name)
        case .firefox: return firefoxAddon(root: root)
        case .safari: return .notAdded
        }
    }

    static func chromiumAddon(root: URL, name browserName: String) -> Addon {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        var blocked = false
        for name in names where name == "Default" || name.hasPrefix("Profile ") {
            for file in ["Secure Preferences", "Preferences"] {
                let data: Data
                do { data = try Data(contentsOf: root.appending(path: "\(name)/\(file)")) } catch {
                    blocked = blocked || (error as NSError).code == NSFileReadNoPermissionError
                    continue
                }
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let extensions = json["extensions"] as? [String: Any],
                      let settings = extensions["settings"] as? [String: Any],
                      settings[chromeID] != nil
                else { continue }
                return .added
            }
        }
        // macOS keeps apps out of other apps' data unless given Full Disk Access; the extension can still report in.
        return blocked ? .unknown("Open the Rays button in \(browserName) once so Rays can see the extension.") : .notAdded
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
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        // Chrome's folder too for every Chromium browser: forks that keep Chrome's path (as Brave does) read it there.
        // It is never removed for another browser, so Chrome and Brave keep it.
        let shared = browser.engine == .chromium ? chromeHostDir : nil
        for hostDir in NSOrderedSet(array: [hostDir, browser.alsoHostDir, shared].compactMap { $0 }).array as! [String] {
            let dir = supportURL(hostDir)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appending(path: manifestName), options: .atomic)
        }
    }

    /// Deletes Rays' helper manifest for this browser, and only if it is ours (name `ai.a6n.rays`).
    static func removeHelper(_ browser: Browser) throws {
        guard let hostDir = browser.hostDir else { return }
        for hostDir in [hostDir] + [browser.alsoHostDir].compactMap({ $0 }) {
            let file = supportURL(hostDir).appending(path: manifestName)
            guard let data = try? Data(contentsOf: file) else { continue }
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard json?["name"] as? String == hostName else { continue }
            try FileManager.default.removeItem(at: file)
        }
    }
}

@MainActor
@Observable
final class BrowserCheckModel {
    private(set) var states: [BrowserCheck.State] = []
    private(set) var others: [BrowserCheck.OtherBrowser] = []
    private(set) var loaded = false
    private(set) var failures: [String: String] = [:]

    /// Installed lookup runs here; file reads run off the main actor.
    func refresh() {
        let installed = BrowserCheck.browsers.compactMap { browser in
            BrowserCheck.appURL(for: browser).map { (browser, $0) }
        }
        others = BrowserCheck.otherBrowsers()
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
