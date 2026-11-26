import AppKit
import CryptoKit
import SwiftUI

/// Checks GitHub for a newer Rays release. Sends nothing but a plain request to the public API.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    struct Release: Equatable {
        let version: String
        let page: URL
        let dmg: URL?
        /// The release zip and its SHA-256 from GitHub, used to update in place.
        var zip: URL? = nil
        var sha256: String? = nil
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(Release), installing, failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var dismissed: String? = UserDefaults.standard.string(forKey: Keys.dismissed)
    private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: Keys.lastChecked) as? Date

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    var available: Release? {
        if case .available(let release) = status { release } else { nil }
    }

    /// The pill shows unless the user closed it for this exact version.
    var showsPill: Bool {
        guard let available else { return false }
        return dismissed != available.version
    }

    private enum Keys {
        static let lastChecked = "updateLastChecked"
        static let dismissed = "updateDismissedVersion"
        static let automatic = "updateCheckAutomatically"
    }

    private static let latest = URL(string: "https://api.github.com/repos/a6n-ai/rays/releases/latest")!

    /// At launch (at most once an hour) and then every 6 hours while Rays is open, if automatic checks are on.
    func checkIfDue() {
        guard !started else { return }
        started = true
        Task {
            while !Task.isCancelled {
                let automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
                if automatic, lastChecked.map({ Date.now.timeIntervalSince($0) >= 3600 }) ?? true {
                    await check()
                }
                try? await Task.sleep(for: .seconds(6 * 3600))
            }
        }
    }
    private var started = false

    func check() async {
        status = .checking
        do {
            var request = URLRequest(url: Self.latest, timeoutInterval: 15)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let release = try Self.parse(data)
            lastChecked = .now
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            status = Self.isNewer(release.version, than: current) ? .available(release) : .upToDate
        } catch {
            status = .failed("Couldn't reach GitHub. Check your connection and try again.")
        }
    }

    /// Downloads the zip, checks its SHA-256 and the app inside, swaps it for this app, then relaunches.
    /// Anything that fails (no zip, no write access to the app's folder) falls back to downloading the DMG.
    func install(_ release: Release, fallback: @escaping (Release) -> Void) async {
        guard let zip = release.zip, let sha256 = release.sha256 else { return fallback(release) }
        status = .installing
        let current = Bundle.main.bundleURL
        let bundleID = Bundle.main.bundleIdentifier ?? ""
        do {
            let (file, response) = try await URLSession.shared.download(from: zip)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try await Task.detached {
                try Self.replace(current, withZip: file, sha256: sha256, bundleID: bundleID, version: release.version)
            }.value
            try Self.relaunch(current)
            NSApp.terminate(nil)
            // Quit was cancelled (the user kept a download running); the new version opens on the next quit.
            status = .available(release)
        } catch {
            status = .available(release)
            fallback(release)
        }
    }

    nonisolated static func replace(_ app: URL, withZip zip: URL, sha256: String, bundleID: String, version: String) throws {
        let fm = FileManager.default
        let hash = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
        guard hash.map({ String(format: "%02x", $0) }).joined() == sha256.lowercased() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let work = fm.temporaryDirectory.appending(path: "rays-update-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: work) }
        try run("/usr/bin/ditto", ["-x", "-k", zip.path(percentEncoded: false), work.path(percentEncoded: false)])
        let new = work.appending(path: "Rays.app", directoryHint: .isDirectory)
        let info = Bundle(url: new)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == bundleID,
              info?["CFBundleShortVersionString"] as? String == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        // Staged beside the app so the swap is a rename on the same volume.
        let staged = app.deletingLastPathComponent().appending(path: ".Rays-update.app", directoryHint: .isDirectory)
        try? fm.removeItem(at: staged)
        // A standard user can't add items to /Applications but owns Rays.app, so replace its contents in place instead.
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path(percentEncoded: false)) else {
            try run("/usr/bin/rsync", ["-a", "--delete", new.path(percentEncoded: false) + "/", app.path(percentEncoded: false) + "/"])
            return
        }
        try run("/usr/bin/ditto", [new.path(percentEncoded: false), staged.path(percentEncoded: false)])
        do {
            _ = try fm.replaceItemAt(app, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// Waits for this process to exit, then opens the (new) app at the same path.
    private static func relaunch(_ app: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let shell = Process()
        shell.executableURL = URL(filePath: "/bin/sh")
        shell.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"",
                           app.path(percentEncoded: false)]
        try shell.run()
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    func dismissPill() {
        guard let available else { return }
        dismissed = available.version
        UserDefaults.standard.set(available.version, forKey: Keys.dismissed)
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Body: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let body = try JSONDecoder().decode(Body.self, from: data)
        let version = body.tag_name.hasPrefix("v") ? String(body.tag_name.dropFirst()) : body.tag_name
        let dmg = body.assets.first { $0.name.hasSuffix(".dmg") && $0.name != "Rays.dmg" }
            ?? body.assets.first { $0.name.hasSuffix(".dmg") }
        let zip = body.assets.first { $0.name.hasSuffix(".zip") }
        return Release(version: version, page: body.html_url, dmg: dmg?.browser_download_url,
                       // Through rays.a6n.ai so updates are counted apart from new installs; it redirects to GitHub.
                       zip: zip.flatMap { URL(string: "https://rays.a6n.ai/download/\($0.name)?src=update") },
                       sha256: zip?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)) : nil })
    }

    /// Numeric compare of dotted versions: 0.1.10 is newer than 0.1.9.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

/// Small glass pill at the top of the window when a newer Rays is out.
extension EngineModel {
    /// The manual path: the DMG downloads like any file, then the user drags Rays to Applications.
    func downloadDMG(_ release: Updater.Release) {
        if let dmg = release.dmg { add(dmg.absoluteString) } else { NSWorkspace.shared.open(release.page) }
    }
}

struct UpdatePill: View {
    @Environment(EngineModel.self) private var model
    private var updater: Updater { .shared }

    var body: some View {
        if updater.showsPill, let release = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                Text("A new version of Rays is available")
                    .font(.callout.weight(.medium))
                if updater.status == .installing {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.callout).foregroundStyle(.secondary)
                } else {
                    Button("Update") {
                        Task { await updater.install(release) { model.downloadDMG($0); updater.dismissPill() } }
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
                    .tint(.green)
                    .controlSize(.small)
                    .help("Download the new version, replace this one and reopen Rays")
                }
                Button { updater.dismissPill() } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Hide until the next version")
                .accessibilityLabel("Hide update notice")
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 6)
            .glassEffect(.regular.tint(.green.opacity(0.18)), in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Settings row: current version, Check for Updates, and the result.
struct UpdateSettingsSection: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("updateCheckAutomatically") private var automatic = true
    private var updater: Updater { .shared }

    var body: some View {
        Section {
            SettingRow(title: "Rays \(updater.current)", hint: statusText) {
                if let release = updater.available {
                    Button("Update to \(release.version)") {
                        Task { await updater.install(release) { model.downloadDMG($0) } }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(updater.status == .installing)
                } else {
                    Button("Check for Updates") { Task { await updater.check() } }
                        .buttonStyle(.glass)
                        .disabled(updater.status == .checking)
                }
            }
            Toggle("Check for updates automatically", isOn: $automatic)
                .toggleStyle(.switch)
        } header: {
            Text("Updates")
        }
    }

    private var statusText: String {
        switch updater.status {
        case .checking: "Checking…"
        case .installing: "Downloading and installing the update…"
        case .upToDate: "You have the latest version."
        case .available(let release): "Version \(release.version) is available."
        case .failed(let message): message
        case .idle:
            updater.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))." }
                ?? "Rays checks GitHub when it opens and every few hours."
        }
    }
}
