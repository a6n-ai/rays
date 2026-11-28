import Testing
@testable import Rays

struct SorterReregisterTests {
    private let bundled = "/Applications/Rays.app/Contents/MacOS/sorter"

    private func folder(_ path: String, watching: Bool = true, binary: String?) -> SorterFolder {
        SorterFolder(path: path, watching: watching, label: "local.sorter", agentBinary: binary)
    }

    @Test func replacedSorterReregistersOnlyOurWatches() {
        let folders = [
            folder("/a", binary: bundled),
            folder("/off", watching: false, binary: nil),
            folder("/dev", binary: "/tmp/dev/sorter"),
        ]
        let stale = SorterModel.foldersToReregister(folders, bundled: bundled, registered: "1-10", current: "2-10")
        #expect(stale.map(\.path) == ["/a"])
    }

    @Test func firstRunAfterThisFixReregisters() {
        let folders = [folder("/a", binary: bundled)]
        #expect(SorterModel.foldersToReregister(folders, bundled: bundled, registered: nil, current: "2-10").count == 1)
    }

    @Test func unchangedSorterDoesNothing() {
        let folders = [folder("/a", binary: bundled)]
        #expect(SorterModel.foldersToReregister(folders, bundled: bundled, registered: "2-10", current: "2-10").isEmpty)
    }
}
