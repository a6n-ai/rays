import AppKit
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
    }

    enum Status: Equatable {
        case idle, checking, upToDate, available(Release), failed(String)
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

    /// At launch: at most once a day, and only if automatic checks are on (the default).
    func checkIfDue() {
        let automatic = UserDefaults.standard.object(forKey: Keys.automatic) as? Bool ?? true
        guard automatic else { return }
        if let lastChecked, Date.now.timeIntervalSince(lastChecked) < 24 * 3600 { return }
        Task { await check() }
    }

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

    func dismissPill() {
        guard let available else { return }
        dismissed = available.version
        UserDefaults.standard.set(available.version, forKey: Keys.dismissed)
    }

    nonisolated static func parse(_ data: Data) throws -> Release {
        struct Asset: Decodable { let name: String; let browser_download_url: URL }
        struct Body: Decodable { let tag_name: String; let html_url: URL; let assets: [Asset] }
        let body = try JSONDecoder().decode(Body.self, from: data)
        let version = body.tag_name.hasPrefix("v") ? String(body.tag_name.dropFirst()) : body.tag_name
        let dmg = body.assets.first { $0.name.hasSuffix(".dmg") && $0.name != "Rays.dmg" }
            ?? body.assets.first { $0.name.hasSuffix(".dmg") }
        return Release(version: version, page: body.html_url, dmg: dmg?.browser_download_url)
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
struct UpdatePill: View {
    @Environment(EngineModel.self) private var model
    private var updater: Updater { .shared }

    var body: some View {
        if updater.showsPill, let release = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green)
                Text("A new version of Rays is available")
                    .font(.callout.weight(.medium))
                Button("Download") {
                    if let dmg = release.dmg { model.add(dmg.absoluteString) } else { NSWorkspace.shared.open(release.page) }
                    updater.dismissPill()
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .tint(.green)
                .controlSize(.small)
                .help("Download the new version with Rays, then open it and drag Rays to Applications")
                Button { updater.dismissPill() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
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
            SettingRow(symbol: "arrow.triangle.2.circlepath", color: .blue,
                       title: "Rays \(updater.current)", hint: statusText) {
                if let release = updater.available {
                    Button("Download \(release.version)") {
                        if let dmg = release.dmg { model.add(dmg.absoluteString) } else { NSWorkspace.shared.open(release.page) }
                    }
                    .buttonStyle(.glassProminent)
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
        case .upToDate: "You have the latest version."
        case .available(let release): "Version \(release.version) is available."
        case .failed(let message): message
        case .idle:
            updater.lastChecked.map { "Last checked \($0.formatted(date: .abbreviated, time: .shortened))." }
                ?? "Rays checks GitHub once a day."
        }
    }
}
