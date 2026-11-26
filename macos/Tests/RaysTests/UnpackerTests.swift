import Testing
@testable import Rays

@Suite struct UnpackerTests {
    @Test(arguments: [
        ("a.zip", "a"), ("a.tar", "a"), ("foo.tar.gz", "foo"), ("a.tgz", "a"), ("a.tar.bz2", "a"),
        ("a.tbz2", "a"), ("a.tar.xz", "a"), ("a.txz", "a"), ("a.7z", "a"), ("my.app.v2.zip", "my.app.v2"),
    ])
    func names(file: String, folder: String) {
        #expect(Unpacker.folderName(for: file) == folder)
    }

    @Test func caseInsensitive() {
        #expect(Unpacker.folderName(for: "Photos.ZIP") == "Photos")
        #expect(Unpacker.folderName(for: "Src.Tar.GZ") == "Src")
    }

    @Test(arguments: ["a.gz", "a.dmg", "a.pkg", "a.rar", "a", ".zip", "zip"])
    func nonArchives(file: String) {
        #expect(Unpacker.folderName(for: file) == nil)
    }

    @Test func collisions() {
        #expect(Unpacker.uniqueName("foo") { _ in false } == "foo")
        #expect(Unpacker.uniqueName("foo") { $0 == "foo" } == "foo 2")
        #expect(Unpacker.uniqueName("foo") { ["foo", "foo 2"].contains($0) } == "foo 3")
    }
}
