import AppKit
import SwiftUI

enum Unpacker {
    private static let extensions = [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz2", ".txz", ".zip", ".tar", ".7z"]

    /// The folder name for an archive file name ("foo.tar.gz" gives "foo"), or nil when it is not a supported archive.
    static func folderName(for fileName: String) -> String? {
        let lower = fileName.lowercased()
        guard let ext = extensions.first(where: { lower.hasSuffix($0) }) else { return nil }
        let base = String(fileName.dropLast(ext.count))
        return base.isEmpty ? nil : base
    }

    /// `base`, or "base 2", "base 3"... for the first name `exists` does not report as taken.
    static func uniqueName(_ base: String, exists: (String) -> Bool) -> String {
        guard exists(base) else { return base }
        var n = 2
        while exists("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Extracts next to the archive with bsdtar; nil when the file is not an archive.
    /// bsdtar refuses absolute paths and `..` unless given -P, which is never passed.
    nonisolated static func unpack(_ archive: URL, trash: Bool) async -> Result<URL, Error>? {
        guard let base = folderName(for: archive.lastPathComponent) else { return nil }
        return await Task.detached {
            let fm = FileManager.default
            let parent = archive.deletingLastPathComponent()
            let name = uniqueName(base) { fm.fileExists(atPath: parent.appending(path: $0).path(percentEncoded: false)) }
            let dest = parent.appending(path: name, directoryHint: .isDirectory)
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: false)
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/bsdtar")
                process.arguments = ["-xf", archive.path(percentEncoded: false), "-C", dest.path(percentEncoded: false)]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
            } catch {
                try? fm.removeItem(at: dest)
                return .failure(error)
            }
            if trash { try? fm.trashItem(at: archive, resultingItemURL: nil) }
            return .success(dest)
        }.value
    }
}

struct UnpackSettingsRows: View {
    @AppStorage(SettingsKey.unpackArchives) private var unpack = false
    @AppStorage(SettingsKey.trashUnpackedArchive) private var trash = false

    var body: some View {
        SettingRow(symbol: "archivebox.fill", color: .brown,
                   title: "Unpack archives when done",
                   hint: "A finished .zip, .tar, .tar.gz, .tgz, .tar.bz2, .tar.xz or .7z is unpacked into a folder next to it.") {
            Toggle("Unpack archives when done", isOn: $unpack)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        SettingRow(symbol: "trash.fill", color: .orange,
                   title: "Move the archive to the Trash after unpacking",
                   hint: "The archive stays if unpacking fails.") {
            Toggle("Move the archive to the Trash after unpacking", isOn: $trash)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .disabled(!unpack)
    }
}
