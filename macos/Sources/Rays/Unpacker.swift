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

    /// Extracts next to the archive with bsdtar; nil when the file is not an archive. Like Archive Utility, an archive
    /// with one top-level item yields that item; otherwise a folder named after the archive.
    /// bsdtar refuses absolute paths and `..` unless given -P, which is never passed.
    nonisolated static func unpack(_ archive: URL, trash: Bool) async -> Result<URL, Error>? {
        guard let base = folderName(for: archive.lastPathComponent) else { return nil }
        return await Task.detached {
            let fm = FileManager.default
            let parent = archive.deletingLastPathComponent()
            let work = parent.appending(path: ".rays-unpack-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? fm.removeItem(at: work) }
            let result: URL
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: false)
                let process = Process()
                process.executableURL = URL(filePath: "/usr/bin/bsdtar")
                process.arguments = ["-xf", archive.path(percentEncoded: false), "-C", work.path(percentEncoded: false)]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
                let items = try fm.contentsOfDirectory(atPath: work.path(percentEncoded: false)).filter { $0 != ".DS_Store" && $0 != "__MACOSX" }
                let taken = { (name: String) in fm.fileExists(atPath: parent.appending(path: name).path(percentEncoded: false)) }
                if items.count == 1, let only = items.first {
                    let ext = (only as NSString).pathExtension, stem = (only as NSString).deletingPathExtension
                    let name = ext.isEmpty ? uniqueName(only, exists: taken) : uniqueName(stem) { taken("\($0).\(ext)") } + ".\(ext)"
                    result = parent.appending(path: name)
                    try fm.moveItem(at: work.appending(path: only), to: result)
                } else {
                    result = parent.appending(path: uniqueName(base, exists: taken), directoryHint: .isDirectory)
                    try fm.moveItem(at: work, to: result)
                }
            } catch {
                return .failure(error)
            }
            if trash { try? fm.trashItem(at: archive, resultingItemURL: nil) }
            return .success(result)
        }.value
    }
}

struct UnpackSettingsRows: View {
    @AppStorage(SettingsKey.unpackArchives) private var unpack = false
    @AppStorage(SettingsKey.trashUnpackedArchive) private var trash = false

    var body: some View {
        SettingRow(title: "Unpack archives when done",
                   hint: "A finished .zip, .tar, .tar.gz, .tgz, .tar.bz2, .tar.xz or .7z is unpacked into a folder next to it.") {
            Toggle("Unpack archives when done", isOn: $unpack)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        SettingRow(title: "Move the archive to the Trash after unpacking",
                   hint: "The archive stays if unpacking fails.") {
            Toggle("Move the archive to the Trash after unpacking", isOn: $trash)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .disabled(!unpack)
    }
}
