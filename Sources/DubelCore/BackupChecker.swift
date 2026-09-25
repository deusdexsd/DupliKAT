import Foundation

/// „Czy to już jest zgrane?” — porównuje źródło (karta, folder roboczy) z archiwum.
/// Dopasowanie po ZAWARTOŚCI, nie po nazwie: plik przemianowany w archiwum nadal liczy się jako zgrany.
public struct BackupChecker: Sendable {
    public enum Status: Sendable, Hashable {
        /// Identyczna kopia istnieje w archiwum.
        case backedUp([URL])
        /// W archiwum jest plik o tej samej nazwie, ale inna zawartość (np. inny eksport, uszkodzona kopia).
        case differs([URL])
        /// Brak w archiwum.
        case missing
    }

    public struct Entry: Identifiable, Sendable, Hashable {
        public let file: ScannedFile
        public let status: Status
        /// Kopie na dyskach NIEPODŁĄCZONYCH (z zapamiętanej zawartości, dopasowanie po nazwie i rozmiarze).
        public var offline: [URL] = []
        public var id: String { file.id }
        public init(file: ScannedFile, status: Status, offline: [URL] = []) { self.file = file; self.status = status; self.offline = offline }

        /// Wszystkie znane kopie: sprawdzone na podłączonych dyskach + zapamiętane z odłączonych.
        public var allCopies: [URL] {
            if case .backedUp(let u) = status { return u + offline.filter { !u.contains($0) } }
            return offline
        }
        /// Na ilu RÓŻNYCH dyskach jest kopia (M + M2 = 2).
        public var copyDrives: [String] {
            var seen: [String] = []
            for u in allCopies { let v = VolumeInfo.volumeName(forPath: u.path); if !seen.contains(v) { seen.append(v) } }
            return seen
        }
        /// Kopia jest tylko na niepodłączonym dysku (niesprawdzona zawartość).
        public var onlyOffline: Bool { if case .backedUp(let u) = status { return u.isEmpty && !offline.isEmpty } else { return false } }
    }

    public struct Report: Sendable {
        public var entries: [Entry]
        public init(entries: [Entry]) { self.entries = entries }
        public var backedUp: [Entry] { entries.filter { if case .backedUp = $0.status { return true } else { return false } } }
        public var differs: [Entry] { entries.filter { if case .differs = $0.status { return true } else { return false } } }
        public var missing: [Entry] { entries.filter { $0.status == .missing } }
    }

    public var walk: WalkOptions
    /// Pełne porównanie zawartości (domyślnie tak — to od tego wyniku zależy, czy coś uznasz za bezpieczne do usunięcia).
    public var verifyFullContent: Bool
    public var cache: HashCache?
    /// Pomijaj pliki źródła leżące wewnątrz archiwum (karta vs archiwum). Wyłączone przy „czy to gdzieś już jest” dla zaznaczenia w Finderze
    /// — wtedy plik nie znajdzie sam siebie, bo ten sam i-węzeł jest odfiltrowany.
    public var skipSourcesInsideBackups = true
    /// Zapamiętana zawartość dysków, które teraz są odłączone.
    public var offline: [CatalogIndex] = []

    public init(walk: WalkOptions, verifyFullContent: Bool = true, cache: HashCache? = nil) {
        self.walk = walk; self.verifyFullContent = verifyFullContent; self.cache = cache
    }

    public func run(sources: [URL], backups: [URL], progress: ProgressHandler? = nil) async throws -> Report {
        let backupRoots = FileWalker.normalizedRoots(backups)
        let backupPaths = backupRoots.map(\.path)
        let src = try FileWalker.files(in: sources, options: walk, progress: progress)
            .filter { !skipSourcesInsideBackups || !FileWalker.isExcluded($0.url.path, backupPaths) } // źródło leżące wewnątrz archiwum nie jest „źródłem”
        var backupWalk = walk
        backupWalk.recursive = true // archiwum zawsze przeszukujemy w całości
        let dst = try FileWalker.files(in: backupRoots, options: backupWalk, progress: progress)
        let srcIDs = Set(src.compactMap(\.identity))
        // Karta vs archiwum: pliki źródła nie są kopiami. Zaznaczenie z Findera: kopia może leżeć także w samym zaznaczeniu
        // (dwa takie same pliki w Pobranych) — wtedy wykluczamy tylko ten sam plik (ten sam i-węzeł).
        let others = skipSourcesInsideBackups ? dst.filter { $0.identity == nil || !srcIDs.contains($0.identity!) } : dst
        let dstBySize = Dictionary(grouping: others, by: \.size)
        let dstByName = Dictionary(grouping: others, by: { $0.name.lowercased() })

        let bytesTotal = src.reduce(Int64(0)) { $0 + (dstBySize[$1.size] != nil ? $1.size : 0) }
        var bytesDone: Int64 = 0
        var entries: [Entry] = []
        var lastReport = Date.distantPast
        for (i, f) in src.sorted(by: { $0.url.path < $1.url.path }).enumerated() {
            try Task.checkCancellation()
            if Date().timeIntervalSince(lastReport) > 0.15 {
                lastReport = Date()
                progress?(ScanProgress(phase: verifyFullContent ? .hashing : .sampling, done: i, total: src.count, bytesDone: bytesDone, bytesTotal: bytesTotal, current: f.name))
            }
            var matches: [URL] = []
            // Postęp także podczas czytania plików z archiwum — inaczej przy wolnym dysku USB wygląda to na zawieszenie.
            func tick(_ path: String) {
                if Date().timeIntervalSince(lastReport) > 0.15 {
                    lastReport = Date()
                    progress?(ScanProgress(phase: verifyFullContent ? .hashing : .sampling, done: i, total: src.count, bytesDone: bytesDone, bytesTotal: bytesTotal, current: path))
                }
            }
            if let all = dstBySize[f.size], case let same = all.filter({ !isSame($0, f) }), !same.isEmpty, let mine = sample(f) {
                let candidates = same.filter { tick($0.url.path); return sample($0) == mine }
                if !candidates.isEmpty, needsFull(f) {
                    if let full = fullHash(f, onBytes: { bytesDone += $0; tick(f.url.path) }) {
                        matches = candidates.filter { c in fullHash(c, onBytes: { _ in tick("porównuję z: " + c.url.path) }) == full }.map(\.url)
                    }
                } else {
                    matches = candidates.map(\.url)
                    bytesDone += f.size
                }
            }
            let off = offline.flatMap { $0.matches(name: f.name, size: f.size) }
            if !matches.isEmpty {
                entries.append(Entry(file: f, status: .backedUp(matches), offline: off))
            } else if !off.isEmpty {
                entries.append(Entry(file: f, status: .backedUp([]), offline: off))
            } else if let named = dstByName[f.name.lowercased()]?.filter({ !isSame($0, f) }), !named.isEmpty {
                entries.append(Entry(file: f, status: .differs(named.map(\.url))))
            } else {
                entries.append(Entry(file: f, status: .missing))
            }
        }
        cache?.save()
        progress?(ScanProgress(phase: .done))
        return Report(entries: entries)
    }

    private func isSame(_ a: ScannedFile, _ b: ScannedFile) -> Bool {
        if let x = a.identity, let y = b.identity { return x == y }
        return FileWalker.canonical(a.url.path) == FileWalker.canonical(b.url.path)
    }

    private func needsFull(_ f: ScannedFile) -> Bool { verifyFullContent && f.size > 3 * Int64(ContentHasher.sampleChunk) }

    private func sample(_ f: ScannedFile) -> String? {
        if let s = cache?.get(f)?.sample { return s }
        guard let s = try? ContentHasher.sampleHash(f.url, size: f.size) else { return nil }
        cache?.update(f) { $0.sample = s }
        return s
    }

    private func fullHash(_ f: ScannedFile, onBytes: ((Int64) -> Void)?) -> String? {
        if let full = cache?.get(f)?.full { onBytes?(f.size); return full }
        guard let full = try? ContentHasher.fullHash(f.url, onBytes: onBytes) else { return nil }
        cache?.update(f) { $0.full = full }
        return full
    }
}
