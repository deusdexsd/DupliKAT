import XCTest
@testable import DubelCore

final class DriveCatalogTests: XCTestCase {
    /// Kopia na „odłączonym” dysku: zapamiętana lista plików wystarcza, żeby wiedzieć, gdzie jest plik z karty.
    func testOfflineCatalogFindsCopy() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cat-\(UUID())")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("M2/KLIZA"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("karta/DCIM"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let clip = Data((0..<400_000).map { UInt8($0 % 199) })
        try clip.write(to: dir.appendingPathComponent("M2/KLIZA/C0001.MP4"))
        try clip.write(to: dir.appendingPathComponent("karta/DCIM/C0001.MP4"))
        try Data((0..<400_000).map { UInt8($0 % 7) }).write(to: dir.appendingPathComponent("karta/DCIM/C0002.MP4"))

        let cat = try DriveCatalog.build(volume: dir.appendingPathComponent("M2"), key: "uuid-m2", name: "M2", minSize: 1)
        XCTAssertEqual(cat.items.map(\.path), ["KLIZA/C0001.MP4"])
        try cat.save(in: dir.appendingPathComponent("pamiec"))
        let loaded = DriveCatalog.load(from: dir.appendingPathComponent("pamiec"))
        XCTAssertEqual(loaded.first?.items.count, 1)

        try fm.removeItem(at: dir.appendingPathComponent("M2")) // „odłączony”
        var c = BackupChecker(walk: WalkOptions(minSize: 1))
        c.offline = loaded.map(CatalogIndex.init)
        let r = try await c.run(sources: [dir.appendingPathComponent("karta")], backups: [])
        let found = try XCTUnwrap(r.entries.first { $0.file.name == "C0001.MP4" })
        XCTAssertTrue(found.onlyOffline)
        XCTAssertEqual(found.allCopies.first?.lastPathComponent, "C0001.MP4")
        XCTAssertEqual(r.missing.map(\.file.name), ["C0002.MP4"])
    }
}
