import XCTest
@testable import DubelCore

final class DriveInfoTests: XCTestCase {
    func testBootDiskIsInternal() throws {
        let d = try XCTUnwrap(DriveInfo.read(volume: URL(fileURLWithPath: "/")))
        print("BOOT DRIVE:", d)
        XCTAssertTrue(d.isInternal)
        XCTAssertNotNil(d.interconnect)
    }

    func testUSBStandardNames() {
        var d = DriveInfo()
        d.linkSpeed = 10_000_000_000
        XCTAssertEqual(d.usbStandard, "USB 3.2 Gen 2")
        XCTAssertEqual(DriveInfo.formatBits(10_000_000_000), "10 Gb/s")
        d.linkSpeed = 480_000_000
        XCTAssertEqual(d.usbStandard, "USB 2.0")
        XCTAssertTrue(d.isSlowLink)
    }

    /// Plik wewnątrz przeszukiwanego miejsca nie znajduje sam siebie, ale znajduje swoją kopię obok.
    func testSelectionInsideBackupFindsOtherCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sel-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("a"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("b"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data((0..<300_000).map { UInt8($0 % 251) })
        try data.write(to: dir.appendingPathComponent("a/x.mov"))
        try data.write(to: dir.appendingPathComponent("b/kopia.mov"))
        try Data((0..<300_000).map { UInt8($0 % 13) }).write(to: dir.appendingPathComponent("a/sam.mov"))
        var c = BackupChecker(walk: WalkOptions(minSize: 1))
        c.skipSourcesInsideBackups = false
        let r = try await c.run(sources: [dir.appendingPathComponent("a/x.mov"), dir.appendingPathComponent("a/sam.mov")], backups: [dir])
        print("ENTRIES:", r.entries.map { "\($0.file.name) \($0.status)" })
        XCTAssertEqual(r.backedUp.count, 1)
        XCTAssertEqual(r.missing.count, 1)
        XCTAssertEqual(r.missing.first?.file.name, "sam.mov")
    }

    /// Dwa takie same pliki w zaznaczonym folderze są dla siebie kopiami (jak w skanie duplikatów).
    func testCopiesInsideSelectionCount() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sel2-\(UUID())")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let data = Data((0..<200_000).map { UInt8($0 % 241) })
        try data.write(to: dir.appendingPathComponent("a.jpg"))
        try data.write(to: dir.appendingPathComponent("sub/deeper/a kopia.jpg"))
        var c = BackupChecker(walk: WalkOptions(minSize: 1))
        c.skipSourcesInsideBackups = false
        let r = try await c.run(sources: [dir], backups: [dir])
        XCTAssertEqual(r.backedUp.count, 2)
        XCTAssertEqual(r.missing.count, 0)
    }
}
