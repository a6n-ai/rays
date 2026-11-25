import AppKit
import Foundation

/// Where model downloads go by default: the sorter's AI Models destination for Downloads, else a folder inside it.
enum AIModelsFolder {
    static func base(downloadsDir: URL, destinations: [String: [String: String]]) -> URL {
        if let path = destinations[key(for: downloadsDir)]?["AI Models"], path.hasPrefix("/") {
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        return downloadsDir.appending(path: "AI Models", directoryHint: .isDirectory)
    }

    /// The sorter's folder key: realpath, no trailing slash.
    static func key(for url: URL) -> String {
        let path = url.path(percentEncoded: false)
        if let resolved = realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Shown only when LM Studio has been installed (its ~/.lmstudio folder exists).
    static var lmStudioModels: URL? {
        let lmStudio = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".lmstudio", directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: lmStudio.path(percentEncoded: false)) else { return nil }
        return lmStudio.appending(path: "models", directoryHint: .isDirectory)
    }

    /// Opens the folder in Finder, creating it first if it's missing.
    static func reveal(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
