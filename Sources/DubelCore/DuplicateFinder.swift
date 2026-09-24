import Foundation

/// Identyczne pliki: rozmiar → próbki (początek/środek/koniec) → pełna zawartość.
/// Każdy etap odsiewa kandydatów, więc pełne czytanie dotyczy tylko plików, które naprawdę wyglądają na kopie.
public struct DuplicateFinder: Sendable {
    public var walk: WalkOptions
    /// false = kończymy na próbkach (dużo szybciej na dyskach USB; grupy oznaczone jako „prawie na pewno”).
    public var verifyFullContent: Bool
    public var cache: HashCache?

    public init(walk: WalkOptions, verifyFullContent: Bool = true, cache: HashCache? = nil) {
        self.walk = walk; self.verifyFullContent = verifyFullContent; self.cache = cache
    }

    public func run(roots: [URL], progress: ProgressHandler? = nil) async throws -> [DuplicateGroup] {
        let files = try FileWalker.files(in: roots, options: walk, progress: progress)
        return try await groups(from: files, progress: progress)
    }

    public func groups(from files: [ScannedFile], progress: ProgressHandler? = nil) async throws -> [DuplicateGroup] {
        progress?(ScanProgress(phase: .grouping, total: files.count))
        let bySize = Dictionary(grouping: files, by: \.size).values.filter { $0.count > 1 }

        // Etap 2: próbki.
        let candidates = bySize.flatMap { $0 }.sorted { $0.url.path < $1.url.path }
        var sampleOf: [String: String] = [:]
        var lastSample = Date.distantPast
        for (i, f) in candidates.enumerated() {
            try Task.checkCancellation()
            // Co ~0,1 s aktualny plik trafia do UI — widać, na czym skan pracuje, nawet gdy dysk jest wolny.
            if Date().timeIntervalSince(lastSample) > 0.1 {
                lastSample = Date()
                progress?(ScanProgress(phase: .sampling, done: i, total: candidates.count, current: f.url.path))
            }
            if let s = cache?.get(f)?.sample { sampleOf[f.id] = s; continue }
            guard let s = try? ContentHasher.sampleHash(f.url, size: f.size) else { walk.log?.skip(f.url, .unreadable); continue }
            sampleOf[f.id] = s
            cache?.update(f) { $0.sample = s }
        }
        let bySample = Dictionary(grouping: candidates.filter { sampleOf[$0.id] != nil }, by: { "\($0.size)|\(sampleOf[$0.id]!)" })
            .values.filter { $0.count > 1 }

        guard verifyFullContent else {
            cache?.save()
            progress?(ScanProgress(phase: .done))
            return Self.sorted(bySample.map { DuplicateGroup(id: "s:" + sampleOf[$0[0].id]!, files: Self.ordered($0), match: .sampled) })
        }

        // Etap 3: pełna zawartość. Pliki mniejsze niż 3 próbki już są przeczytane w całości przez sampleHash.
        let toHash = bySample.flatMap { $0 }.sorted { $0.url.path < $1.url.path }
        let bytesTotal = toHash.reduce(Int64(0)) { $0 + ($1.size <= 3 * Int64(ContentHasher.sampleChunk) ? 0 : $1.size) }
        var bytesDone: Int64 = 0
        var fullOf: [String: String] = [:]
        var lastReport = Date.distantPast
        for (i, f) in toHash.enumerated() {
            try Task.checkCancellation()
            if f.size <= 3 * Int64(ContentHasher.sampleChunk) { fullOf[f.id] = sampleOf[f.id]; continue }
            if let full = cache?.get(f)?.full { fullOf[f.id] = full; bytesDone += f.size; continue }
            let full = try? ContentHasher.fullHash(f.url) { n in
                bytesDone += n
                if Date().timeIntervalSince(lastReport) > 0.15 {
                    lastReport = Date()
                    progress?(ScanProgress(phase: .hashing, done: i, total: toHash.count, bytesDone: bytesDone, bytesTotal: bytesTotal, current: f.url.path))
                }
            }
            guard let full else { walk.log?.skip(f.url, .unreadable); continue }
            fullOf[f.id] = full
            cache?.update(f) { $0.full = full }
        }
        cache?.save()
        let byFull = Dictionary(grouping: toHash.filter { fullOf[$0.id] != nil }, by: { fullOf[$0.id]! }).filter { $0.value.count > 1 }
        progress?(ScanProgress(phase: .done))
        return Self.sorted(byFull.map { DuplicateGroup(id: $0.key, files: Self.ordered($0.value), match: .identical) })
    }

    /// Najstarsza kopia na górze grupy — zwykle to oryginał (np. zgrany z karty jako pierwszy).
    static func ordered(_ files: [ScannedFile]) -> [ScannedFile] {
        files.sorted { ($0.created ?? $0.modified, $0.url.path) < ($1.created ?? $1.modified, $1.url.path) }
    }

    /// Najpierw grupy, które oddadzą najwięcej miejsca.
    public static func sorted(_ groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.sorted { $0.reclaimable != $1.reclaimable ? $0.reclaimable > $1.reclaimable : $0.id < $1.id }
    }
}

private func < (a: (Date, String), b: (Date, String)) -> Bool { a.0 != b.0 ? a.0 < b.0 : a.1 < b.1 }

/// Łączenie w grupy „A podobne do B, B podobne do C” (union-find).
struct UnionFind {
    private var parent: [Int]
    init(_ n: Int) { parent = Array(0..<n) }
    mutating func find(_ x: Int) -> Int {
        var r = x
        while parent[r] != r { r = parent[r] }
        var c = x
        while parent[c] != r { let n = parent[c]; parent[c] = r; c = n }
        return r
    }
    mutating func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }
    mutating func components() -> [[Int]] {
        var m: [Int: [Int]] = [:]
        for i in parent.indices { m[find(i), default: []].append(i) }
        return m.values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}
