import CoreGraphics
import XCTest
@testable import DubelCore

final class DubelCoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("dubel-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ path: String, _ data: Data) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    func bytes(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed) &* 7) ^ seed }) }

    // MARK: Duplikaty

    func testFindsIdenticalFilesAcrossFolders() async throws {
        let a = bytes(500_000, seed: 1)
        try write("karta/C0001.MP4", a)
        try write("archiwum/2026/C0001.MP4", a)
        try write("archiwum/inna-nazwa.mp4", a)
        try write("karta/C0002.MP4", bytes(500_000, seed: 2)) // ten sam rozmiar, inna treść
        let groups = try await DuplicateFinder(walk: WalkOptions()).run(roots: [root])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].files.count, 3)
        XCTAssertEqual(groups[0].match, .identical)
        XCTAssertEqual(groups[0].reclaimable, 1_000_000)
        XCTAssertEqual(groups[0].kind, .video)
    }

    func testSameSampleDifferentMiddleIsNotDuplicateWhenVerified() async throws {
        // Te same początek i koniec, różnica między próbkami — tylko pełne porównanie to wyłapie.
        var a = bytes(2_000_000, seed: 3)
        try write("a.mov", a)
        a[300_000] ^= 0xFF
        try write("b.mov", a)
        let full = try await DuplicateFinder(walk: WalkOptions(), verifyFullContent: true).run(roots: [root])
        XCTAssertTrue(full.isEmpty)
        let quick = try await DuplicateFinder(walk: WalkOptions(), verifyFullContent: false).run(roots: [root])
        XCTAssertEqual(quick.first?.match, .sampled)
    }

    func testHardLinkIsNotADuplicate() async throws {
        let a = try write("a.wav", bytes(300_000, seed: 4))
        try FileManager.default.linkItem(at: a, to: root.appendingPathComponent("b.wav"))
        let groups = try await DuplicateFinder(walk: WalkOptions()).run(roots: [root])
        XCTAssertTrue(groups.isEmpty)
    }

    func testProtectedFoldersAreSkipped() async throws {
        let a = bytes(200_000, seed: 5)
        try write("Film.fcpbundle/Event/Original Media/C0001.MP4", a)
        try write("Motion Templates.localized/Titles/X/Media/tex.png", a)
        try write("Final Cut Proxy Media/2026/C0001.mov", a)
        try write("zwykly/C0001.MP4", a)
        let groups = try await DuplicateFinder(walk: WalkOptions()).run(roots: [root])
        XCTAssertTrue(groups.isEmpty, "pliki w bibliotekach FCP / szablonach Motion / proxy nie mogą być proponowane do usunięcia")
    }

    func testAppleDoubleAndMinSizeAndExclusions() async throws {
        let a = bytes(10_000, seed: 6)
        try write("x/._a.jpg", a)
        try write("y/._a.jpg", a)
        try write("x/maly.jpg", Data([1, 2, 3]))
        try write("y/maly.jpg", Data([1, 2, 3]))
        try write("pomin/a.jpg", a)
        try write("ok/a.jpg", a)
        let walk = WalkOptions(minSize: 100, excludedPaths: [root.appendingPathComponent("pomin").path])
        let groups = try await DuplicateFinder(walk: walk).run(roots: [root])
        XCTAssertTrue(groups.isEmpty, groups.flatMap { $0.files.map(\.url.path) }.joined(separator: "\n"))
    }

    func testNestedRootsAreCountedOnce() async throws {
        try write("a/b/plik.mp3", bytes(50_000, seed: 7))
        let files = try FileWalker.files(in: [root, root.appendingPathComponent("a"), root.appendingPathComponent("a/b")], options: WalkOptions())
        XCTAssertEqual(files.count, 1)
    }

    func testCacheIsReused() async throws {
        let a = bytes(400_000, seed: 8)
        try write("a.mp4", a); try write("b.mp4", a)
        let cacheURL = root.appendingPathComponent("cache.json")
        let cache = HashCache(fileURL: cacheURL)
        _ = try await DuplicateFinder(walk: WalkOptions(excludedPaths: [cacheURL.path]), cache: cache).run(roots: [root])
        XCTAssertEqual(HashCache(fileURL: cacheURL).count, 2)
    }

    // MARK: Backup

    func testBackupStatuses() async throws {
        let one = bytes(300_000, seed: 10), two = bytes(300_000, seed: 11)
        try write("karta/C0001.MP4", one)
        try write("karta/C0002.MP4", two)
        try write("karta/C0003.MP4", bytes(1000, seed: 12))
        try write("M/2026-09/przemianowany.mp4", one)       // zgrany pod inną nazwą
        try write("M/2026-09/C0002.MP4", bytes(300_000, seed: 13)) // ta sama nazwa, inna treść
        let r = try await BackupChecker(walk: WalkOptions()).run(sources: [root.appendingPathComponent("karta")], backups: [root.appendingPathComponent("M")])
        let byName = Dictionary(uniqueKeysWithValues: r.entries.map { ($0.file.name, $0.status) })
        if case .backedUp(let urls) = byName["C0001.MP4"] { XCTAssertEqual(urls.first?.lastPathComponent, "przemianowany.mp4") } else { XCTFail() }
        if case .differs = byName["C0002.MP4"] {} else { XCTFail() }
        XCTAssertEqual(byName["C0003.MP4"], .missing)
    }

    func testBackupIgnoresSourceInsideBackup() async throws {
        try write("M/karta/a.jpg", bytes(1000, seed: 14))
        let r = try await BackupChecker(walk: WalkOptions()).run(sources: [root.appendingPathComponent("M/karta")], backups: [root.appendingPathComponent("M")])
        XCTAssertTrue(r.entries.isEmpty, r.entries.map(\.file.url.path).joined(separator: "\n"))
    }

    // MARK: Klon APFS

    func testCloneReplaceKeepsContentAndDates() throws {
        guard VolumeInfo.supportsCloning(root) else { throw XCTSkip("dysk bez klonów APFS") }
        let data = bytes(600_000, seed: 20)
        let keeper = try write("M/C0001.MP4", data)
        let dup = try write("kopia/C0001.MP4", data)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dup.path)
        try CloneReplacer.replace(duplicate: dup, withCloneOf: keeper)
        XCTAssertEqual(try Data(contentsOf: dup), data)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dup.path)[.modificationDate] as? Date, old)
        XCTAssertTrue(FileManager.default.fileExists(atPath: keeper.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dup.deletingLastPathComponent().path), ["C0001.MP4"], "bez plików tymczasowych")
    }

    func testCloneReplaceRefusesDifferentContent() throws {
        let keeper = try write("a.mov", bytes(300_000, seed: 21))
        let dup = try write("b.mov", bytes(300_000, seed: 22))
        XCTAssertThrowsError(try CloneReplacer.replace(duplicate: dup, withCloneOf: keeper))
        XCTAssertEqual(try Data(contentsOf: dup), bytes(300_000, seed: 22), "plik nietknięty")
    }

    // MARK: Pliki FCP

    func testFCPGeneratedFolders() throws {
        let lib = "Moje/Projekt 99.fcpbundle"
        try write("\(lib)/22-05-2026/Render Files/High Quality Media/a.mov", bytes(5000, seed: 1))
        try write("\(lib)/22-05-2026/Transcoded Media/Proxy Media/b.mov", bytes(6000, seed: 2))
        try write("\(lib)/22-05-2026/Transcoded Media/High Quality Media/c.mov", bytes(7000, seed: 3))
        try write("\(lib)/22-05-2026/Original Media/C0001.MP4", bytes(90000, seed: 4)) // nie wolno liczyć
        try write("\(lib)/VideoSegmentationFiles/x/seg", bytes(3000, seed: 5))
        try write("\(lib)/.fcpcache/Event/Render Files/d.mov", bytes(4000, seed: 6))
        try write("Dysk/Final Cut Proxy Media/2026/e.mov", bytes(8000, seed: 7))
        let reports = try FCPGeneratedScanner.scan(roots: [root], includeFixed: false)
        XCTAssertEqual(reports.count, 2)
        let libR = try XCTUnwrap(reports.first { !$0.isExternalFolder })
        XCTAssertEqual(libR.name, "Projekt 99")
        XCTAssertEqual(Set(libR.folders.map(\.kind)), [.render, .proxy, .optimized, .segmentation])
        XCTAssertEqual(libR.folders.filter { $0.kind == .render }.count, 2, "render z biblioteki i z .fcpcache")
        XCTAssertFalse(libR.folders.contains { $0.url.path.contains("Original Media") })
        XCTAssertTrue(reports.contains { $0.isExternalFolder && $0.folders.first?.kind == .proxy })
    }

    func testOtherEditorsFolders() throws {
        try write("Projekty/Reklama/Adobe Premiere Pro Video Previews/a.mpeg", bytes(4000, seed: 1))
        try write("Resolve/CacheClip/x.mov", bytes(3000, seed: 2))
        try write("Resolve/ProxyMedia/y.mov", bytes(2000, seed: 3))
        let reports = try FCPGeneratedScanner.scan(roots: [root], includeFixed: false)
        XCTAssertEqual(Set(reports.map(\.app)), [.adobe, .davinci])
        XCTAssertTrue(reports.contains { $0.app == .adobe && $0.folders.first?.kind == .preview })
        XCTAssertTrue(reports.contains { $0.app == .davinci && $0.folders.first?.kind == .cache })
        XCTAssertTrue(reports.contains { $0.app == .davinci && $0.folders.first?.kind == .proxy })
    }

    // MARK: Podobieństwo

    /// Zmniejsza z zachowaniem proporcji (dłuższy bok = size) — jak eksport w mniejszej rozdzielczości.
    func scaled(_ img: CGImage, to size: Int) -> CGImage {
        let w = img.width >= img.height ? size : size * img.width / img.height
        let h = img.width >= img.height ? size * img.height / img.width : size
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func image(seed: Int, size: Int = 256, shift: Int = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = seed
        for i in 0..<24 {
            rng = rng &* 1103515245 &+ 12345
            let c = CGFloat((rng >> 8) & 255) / 255
            ctx.setFillColor(CGColor(red: c, green: CGFloat(i) / 24, blue: 1 - c, alpha: 1))
            let x = CGFloat((rng >> 4) % size), y = CGFloat((rng >> 12) % size)
            ctx.fill(CGRect(x: x + CGFloat(shift), y: y, width: CGFloat(size / 5), height: CGFloat(size / 6)))
        }
        return ctx.makeImage()!
    }

    func testFeaturePrintSeparatesSameFromDifferent() throws {
        // Prawdziwe zdjęcia z systemu (Vision słabo ocenia sztuczne kształty — zmierzone, to dawało fałszywe wyniki).
        let dir = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.thumbnails")
        let pics = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["heic", "jpg", "png"].contains($0.pathExtension.lowercased()) }.sorted { $0.path < $1.path }
        guard pics.count >= 2, let one = PerceptualHash.thumbnail(pics[0], maxPixel: 512), let two = PerceptualHash.thumbnail(pics[pics.count / 2], maxPixel: 512) else {
            throw XCTSkip("brak zdjęć systemowych")
        }
        let a = try XCTUnwrap(FeaturePrint.vector(one))
        let aSmall = try XCTUnwrap(FeaturePrint.vector(scaled(one, to: 320))) // typowy mały eksport
        let b = try XCTUnwrap(FeaturePrint.vector(two))
        XCTAssertLessThan(FeaturePrint.distance(a, aSmall), 0.25)
        XCTAssertGreaterThan(FeaturePrint.distance(a, b), 0.5)
        let pairs = FeaturePrint.neighborPairs([a, aSmall, b], maxDistance: 0.25)
        XCTAssertEqual(pairs.map { [$0.0, $0.1] }, [[0, 1]])
        guard let first = pairs.first else { return }
        XCTAssertEqual(first.2, FeaturePrint.distance(a, aSmall), accuracy: 0.01)
    }

    func testStarClustersDoNotChain() {
        // 0~1, 1~2, 2~3 (łańcuch) — gwiazda nie może skleić 0 z 3.
        let groups = SimilarityFinder.starClusters(count: 4, pairs: [(0, 1, 0.9), (1, 2, 0.9), (2, 3, 0.9)])
        XCTAssertFalse(groups.contains { g in Set(g.map(\.0)).isSuperset(of: [0, 3]) })
        XCTAssertEqual(groups.flatMap { $0.map(\.0) }.count, Set(groups.flatMap { $0.map(\.0) }).count, "plik w jednej grupie")
    }

    func testAudioSimilarityToleratesShift() {
        let env: [Float] = (0..<200).map { Float(sin(Double($0) / 5) + 1.2 + Double($0 % 7) * 0.1) }
        let shifted = Array(repeating: Float(0.01), count: 3) + env
        let other: [Float] = (0..<200).map { Float(cos(Double($0) / 3) + 1.2) }
        let a = MediaFingerprint(duration: 20, envelope: env)
        XCTAssertGreaterThan(MediaAnalyzer.audioSimilarity(a, MediaFingerprint(duration: 20, envelope: shifted)), 0.9)
        XCTAssertLessThan(MediaAnalyzer.audioSimilarity(a, MediaFingerprint(duration: 20, envelope: other)), 0.5)
    }

    func testDurationTolerance() {
        XCTAssertTrue(MediaAnalyzer.durationsMatch(17.8, 17.83))
        XCTAssertTrue(MediaAnalyzer.durationsMatch(600, 605))
        XCTAssertFalse(MediaAnalyzer.durationsMatch(17.8, 19))
    }

    func testMediaKind() {
        XCTAssertEqual(MediaKind.from(extension: "MP4"), .video)
        XCTAssertEqual(MediaKind.from(extension: "ARW"), .image)
        XCTAssertEqual(MediaKind.from(extension: "wav"), .audio)
        XCTAssertEqual(MediaKind.from(extension: "fcpxml"), .project)
        XCTAssertEqual(VolumeInfo.volumeName(forPath: "/Volumes/T7-2/karta 1/a.mp4"), "T7-2")
    }
}
