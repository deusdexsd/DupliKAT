import DubelCore
import Foundation

// Użycie (tylko odczyt, nic nie usuwa):
//   dubel-probe dupes <folder>...           identyczne pliki
//   dubel-probe quick <folder>...           identyczne, tylko próbki
//   dubel-probe similar image|video|audio <folder>...
//   dubel-probe backup <źródło> -- <archiwum>...
//   dubel-probe fcp <folder>...
let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print("brak polecenia"); exit(1) }
let fmt = ByteCountFormatter()
func gb(_ b: Int64) -> String { fmt.string(fromByteCount: b) }
let started = Date()
var lastPhase = ""
let progress: ProgressHandler = { p in
    if p.phase.rawValue != lastPhase { lastPhase = p.phase.rawValue; FileHandle.standardError.write("[\(String(format: "%.1f", Date().timeIntervalSince(started)))s] \(p.phase.rawValue) \(p.total > 0 ? "(\(p.total))" : "")\n".data(using: .utf8)!) }
}
func urls(_ a: ArraySlice<String>) -> [URL] { a.map { URL(fileURLWithPath: $0) } }
let walk = WalkOptions(minSize: 100_000)

switch cmd {
case "dupes", "quick":
    let g = try await DuplicateFinder(walk: walk, verifyFullContent: cmd == "dupes").run(roots: urls(args.dropFirst()), progress: progress)
    print("grup: \(g.count), do odzyskania: \(gb(g.reduce(0) { $0 + $1.reclaimable }))")
    for x in g.prefix(15) { print("— \(x.files.count)× \(gb(x.files[0].size)) \(x.match)"); for f in x.files { print("    \(f.url.path)") } }
case "similar":
    let kind: MediaKind = args[1] == "video" ? .video : args[1] == "audio" ? .audio : .image
    let g = try await SimilarityFinder(walk: WalkOptions(minSize: 1)).run(roots: urls(args.dropFirst(2)), kinds: [kind], progress: progress)
    print("grup: \(g.count)")
    for x in g.prefix(15) { print("— \(x.files.count)× \(x.match)"); for f in x.files { print("    \(f.url.path)") } }
case "backup":
    let split = args.firstIndex(of: "--") ?? args.count
    let r = try await BackupChecker(walk: WalkOptions(minSize: 1)).run(sources: urls(args[1..<split]), backups: urls(args.dropFirst(split + 1)), progress: progress)
    print("zgrane: \(r.backedUp.count), brak: \(r.missing.count), inna zawartość: \(r.differs.count)")
    for e in r.missing.prefix(10) { print("  BRAK \(e.file.url.path)") }
    for e in r.differs.prefix(10) { print("  INNE \(e.file.url.path)") }
case "fcp":
    let r = try FCPGeneratedScanner.scan(roots: urls(args.dropFirst()), progress: progress)
    print("bibliotek/folderów: \(r.count), razem: \(gb(r.reduce(0) { $0 + $1.total }))")
    for l in r { print("  \(gb(l.total).padding(toLength: 10, withPad: " ", startingAt: 0)) \(l.app.title) · \(l.name) [\(l.volumeName)] " + GeneratedKind.allCases.compactMap { k in l.size(of: k) > 0 ? "\(k.title) \(gb(l.size(of: k)))" : nil }.joined(separator: ", ")) }
case "fp":
    var fps: [(String, MediaFingerprint)] = []
    for u in urls(args.dropFirst()) {
        guard let fp = await MediaAnalyzer.video(u) else { print(u.lastPathComponent, "nil"); continue }
        print(u.lastPathComponent, "dur \(fp.duration) frames \(fp.frames.count) vec \(fp.vectors.count) dim \(fp.vectors.first?.count ?? 0)")
        fps.append((u.lastPathComponent, fp))
    }
    for i in fps.indices { for j in fps.indices where j > i {
        let per = zip(fps[i].1.vectors, fps[j].1.vectors).map { String(format: "%.2f", FeaturePrint.distance($0, $1)) }
        print(fps[i].0, "<>", fps[j].0, String(format: "%.3f", MediaAnalyzer.visualDistance(fps[i].1, fps[j].1)), per)
    } }
case "imgd":
    let fps = urls(args.dropFirst()).compactMap { u in MediaAnalyzer.image(u).map { (u.lastPathComponent, $0.vectors[0]) } }
    for i in fps.indices { for j in fps.indices where j > i { print(String(format: "%.3f", FeaturePrint.distance(fps[i].1, fps[j].1)), fps[i].0, "<>", fps[j].0) } }
case "watch":
    let spots = Hotspots.all()
    let snap = try SystemWatch.measure(spots, bigFileThreshold: 1_000_000_000, progress: progress)
    for c in SystemWatch.compare(snap, previous: nil, spots: spots) { print(gb(c.size).padding(toLength: 10, withPad: " ", startingAt: 0), c.spot.title, c.noAccess ? "(brak dostępu)" : "", snap.spots[c.spot.id]!.bigFiles.count, "duże") }
    print("migawki TM:", snap.localSnapshots, "wolne:", gb(snap.freeBytes))
case "card":
    let split = args.firstIndex(of: "--") ?? args.count
    let src = urls(args[1..<split]); let dst = URL(fileURLWithPath: args[split + 1])
    let plan = try await Transfer.planImport(sourceRoots: src, archive: dst, target: dst.appendingPathComponent("TEST"), walk: WalkOptions(), cache: nil, progress: progress)
    print("do skopiowania: \(plan.toCopy.count) (\(gb(plan.bytes))), już są: \(plan.alreadyThere.count)")
    for t in plan.toCopy { print("  ", t.source.lastPathComponent, "→", t.target.path) }
case "cardcheck":
    let split = args.firstIndex(of: "--") ?? args.count
    let card = URL(fileURLWithPath: args[1])
    var w = WalkOptions(minSize: 1); w.kinds = [.video, .audio, .image]; w.skipFolderNames = CameraCard.helperFolders
    let r = try await BackupChecker(walk: w, verifyFullContent: false).run(sources: CameraCard.mediaRoots(card), backups: urls(args.dropFirst(split + 1)), progress: progress)
    print("zgrane: \(r.backedUp.count), nie ma nigdzie: \(r.missing.count) (\(gb(r.missing.reduce(0) { $0 + $1.file.size }))), inna treść: \(r.differs.count)")
    var folders: [String: Int] = [:]
    for e in r.backedUp { if case .backedUp(let u) = e.status { folders[u[0].deletingLastPathComponent().path, default: 0] += 1 } }
    for (f, n) in folders.sorted(by: { $0.value > $1.value }).prefix(6) { print("  \(n) → \(f)") }
    for e in r.missing.prefix(5) { print("  BRAK", e.file.name) }
default: print("nieznane polecenie")
}
print(String(format: "czas: %.1f s", Date().timeIntervalSince(started)))
