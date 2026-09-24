import XCTest
@testable import DubelCore

final class TransferTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: FileWalker.canonical(FileManager.default.temporaryDirectory.path)).appendingPathComponent("dubel-tr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult func write(_ p: String, _ seed: UInt8, _ n: Int = 250_000) throws -> URL {
        let u = root.appendingPathComponent(p)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed) &* 5) ^ seed }).write(to: u)
        return u
    }

    func testCardDetection() throws {
        try write("KARTA/PRIVATE/M4ROOT/CLIP/C0001.MP4", 1)
        try write("DYSK/filmy/a.mp4", 2)
        XCTAssertTrue(CameraCard.isCard(root.appendingPathComponent("KARTA")))
        XCTAssertFalse(CameraCard.isCard(root.appendingPathComponent("DYSK")))
        XCTAssertEqual(CameraCard.mediaRoots(root.appendingPathComponent("KARTA")).map(\.lastPathComponent), ["CLIP"])
    }

    func testFolderTemplate() {
        let d = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 4))!
        XCTAssertEqual(CameraCard.folderName(template: "{data} {karta}", cardName: "Sony A7", date: d), "2026-09-04 Sony A7")
        XCTAssertEqual(CameraCard.folderName(template: "{rok}/{miesiac}", cardName: "x", date: d), "2026/09")
        XCTAssertEqual(CameraCard.folderName(template: "  ", cardName: "x", date: d), "2026-09-04")
    }

    func testImportSkipsFilesAlreadyInArchiveUnderOtherName() async throws {
        try write("KARTA/DCIM/100/A.ARW", 1)
        try write("KARTA/DCIM/100/B.ARW", 2)
        try write("M/BACKUP KART/stare/zmieniona-nazwa.arw", 1)
        let target = root.appendingPathComponent("M/BACKUP KART/2026-09-24")
        let plan = try await Transfer.planImport(sourceRoots: [root.appendingPathComponent("KARTA/DCIM")], archive: root.appendingPathComponent("M/BACKUP KART"),
                                                  target: target, walk: WalkOptions(), cache: nil, progress: nil)
        XCTAssertEqual(plan.toCopy.map { $0.source.lastPathComponent }, ["B.ARW"])
        XCTAssertEqual(plan.toCopy.first?.target.path, target.appendingPathComponent("DCIM/100/B.ARW").path)
        XCTAssertEqual(plan.alreadyThere.count, 1)

        let r = try Transfer.copy(plan.toCopy, verify: true, progress: nil)
        XCTAssertEqual(r.copied.count, 1)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("DCIM/100/B.ARW")), try Data(contentsOf: root.appendingPathComponent("KARTA/DCIM/100/B.ARW")))
        // Drugi raz: nic do zrobienia.
        let again = try await Transfer.planImport(sourceRoots: [root.appendingPathComponent("KARTA/DCIM")], archive: root.appendingPathComponent("M/BACKUP KART"),
                                                   target: target, walk: WalkOptions(), cache: nil, progress: nil)
        XCTAssertTrue(again.toCopy.isEmpty)
    }

    func testCopyNeverOverwrites() throws {
        let src = try write("a/x.mov", 1)
        let dst = try write("b/x.mov", 9)
        let r = try Transfer.copy([TransferItem(source: src, target: dst, size: 1)], verify: true, progress: nil)
        XCTAssertEqual(r.skippedExisting.count, 1)
        XCTAssertEqual(try Data(contentsOf: dst), try Data(contentsOf: try write("c/ref", 9)))
    }

    func testMirrorPlan() throws {
        try write("src/same.mp4", 1); try write("dst/same.mp4", 1)
        try write("src/changed.mp4", 2); try write("dst/changed.mp4", 3)
        try write("src/new/n.wav", 4)
        try write("dst/extra.jpg", 5)
        let p = try Transfer.planMirror(source: root.appendingPathComponent("src"), target: root.appendingPathComponent("dst"), walk: WalkOptions(), progress: nil)
        XCTAssertEqual(Set(p.toCopy.map { $0.source.lastPathComponent }), ["changed.mp4", "n.wav"])
        XCTAssertEqual(p.toReplace.map(\.lastPathComponent), ["changed.mp4"])
        XCTAssertEqual(p.toTrash.map(\.name), ["extra.jpg"])
    }

    func testScanLogRecordsProtected() throws {
        try write("x/Lib.fcpbundle/e/a.mov", 1)
        let log = ScanLog()
        _ = try FileWalker.files(in: [root], options: WalkOptions(log: log))
        XCTAssertEqual(log.count(.protected), 1)
    }

    func testSystemWatchDetectsGrowthAndNewBigFile() throws {
        let spot = Hotspot(id: "t", title: "T", path: root.appendingPathComponent("spot").path, explanation: "", safety: .safe, symbol: "x")
        try write("spot/app1/a", 1, 100_000)
        let before = try SystemWatch.measure([spot], bigFileThreshold: 400_000, progress: nil)
        try write("spot/app2/big", 2, 600_000)
        let after = try SystemWatch.measure([spot], bigFileThreshold: 400_000, progress: nil)
        let changes = SystemWatch.compare(after, previous: before, spots: [spot])
        XCTAssertGreaterThan(changes[0].delta ?? 0, 500_000)
        XCTAssertEqual(changes[0].newBigFiles.count, 1)
        XCTAssertEqual(changes[0].children.first?.name, "app2")
        XCTAssertEqual(SystemWatch.alarms(changes, growthThreshold: 1_000_000_000).count, 1, "nowy duży plik = alarm, nawet przy małym wzroście")
    }
}
