import Foundation

/// Karty z aparatu i kopiowanie: „tylko dodawaj” (nic w celu nie jest kasowane) oraz lustro (na żądanie, z listą tego, co zniknie).
public enum CameraCard {
    /// Karta = w katalogu głównym jest DCIM albo struktura Sony/Panasonic/Canon (PRIVATE/M4ROOT, PRIVATE/AVCHD, CLIP, XDROOT).
    public static func isCard(_ volume: URL) -> Bool {
        let fm = FileManager.default
        return ["DCIM", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "CLIP", "XDROOT", "M4ROOT"].contains { fm.fileExists(atPath: volume.appendingPathComponent($0).path) }
    }

    /// Foldery z materiałem na karcie (to je zgrywamy; resztę — pliki bazy aparatu — pomijamy).
    public static func mediaRoots(_ volume: URL) -> [URL] {
        let fm = FileManager.default
        let found = ["DCIM", "PRIVATE/M4ROOT/CLIP", "PRIVATE/AVCHD", "CLIP", "XDROOT/Clip", "M4ROOT/CLIP"]
            .map { volume.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        return found.isEmpty ? [volume] : found
    }

    /// Foldery aparatu bez materiału: miniatury, baza, informacje o nośniku.
    public static let helperFolders: Set<String> = ["THMBNL", "GENERAL", "DATABASE", "AVF_INFO", "MISC", "CANONMSC", "PANA_GRP"]

    /// Nazwa folderu docelowego ze wzoru: {data} → 2026-09-24, {karta} → nazwa karty, {rok}, {miesiac}, {dzien}.
    public static func folderName(template: String, cardName: String, date: Date = Date()) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", c.year ?? 0), m = String(format: "%02d", c.month ?? 0), d = String(format: "%02d", c.day ?? 0)
        var s = template
        for (k, v) in ["{data}": "\(y)-\(m)-\(d)", "{rok}": y, "{miesiac}": m, "{dzien}": d, "{karta}": cardName] { s = s.replacingOccurrences(of: k, with: v) }
        s = s.replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? "\(y)-\(m)-\(d)" : s
    }
}

public struct TransferItem: Sendable, Hashable, Identifiable {
    public let source: URL
    public let target: URL
    public let size: Int64
    public var id: String { source.path }
    public init(source: URL, target: URL, size: Int64) { self.source = source; self.target = target; self.size = size }
}

/// Plan kopiowania „tylko dodawaj”: pliki ze źródła, których ZAWARTOŚCI nie ma nigdzie w archiwum
/// (więc karta zgrana tydzień temu do innego folderu nie zostanie skopiowana drugi raz).
public struct ImportPlan: Sendable {
    public var toCopy: [TransferItem]
    /// Pliki, które już są w archiwum (z informacją gdzie).
    public var alreadyThere: [BackupChecker.Entry]
    public var bytes: Int64 { toCopy.reduce(0) { $0 + $1.size } }
}

public enum Transfer {
    /// `sourceRoots` = foldery z materiałem, `archive` = gdzie szukać istniejących kopii, `target` = nowy folder na kopie.
    /// `includeRootName`: przy karcie zachowujemy nazwę folderu źródła (DCIM/…), przy parze folderów — kopiujemy zawartość wprost do celu.
    public static func planImport(sourceRoots: [URL], archive: URL, target: URL, walk: WalkOptions, cache: HashCache?, progress: ProgressHandler?,
                                  includeRootName: Bool = true) async throws -> ImportPlan {
        var w = walk
        w.minSize = 1
        var report = BackupChecker.Report(entries: [])
        if FileManager.default.fileExists(atPath: archive.path) {
            report = try await BackupChecker(walk: w, verifyFullContent: true, cache: cache).run(sources: sourceRoots, backups: [archive], progress: progress)
        } else {
            report.entries = try FileWalker.files(in: sourceRoots, options: w, progress: progress).map { .init(file: $0, status: .missing) }
        }
        let roots = sourceRoots.map { FileWalker.canonical($0.path) }
        let copy = (report.missing + report.differs).map { e -> TransferItem in
            TransferItem(source: e.file.url, target: target.appendingPathComponent(relativePath(e.file.url, roots: roots, includeRootName: includeRootName)), size: e.file.size)
        }.sorted { $0.source.path < $1.source.path }
        return ImportPlan(toCopy: copy, alreadyThere: report.backedUp)
    }

    /// Ścieżka pliku względem źródła, z nazwą folderu źródła (DCIM/100MSDCF/DSC0001.ARW).
    public static func relative(_ url: URL, roots: [String]) -> String { relativePath(url, roots: roots) }

    /// Ścieżka względem źródła, z nazwą folderu źródła na początku (DCIM/100MSDCF/DSC0001.ARW).
    static func relativePath(_ url: URL, roots: [String], includeRootName: Bool = true) -> String {
        let path = FileWalker.canonical(url.path)
        guard let root = roots.filter({ path.hasPrefix($0 + "/") }).max(by: { $0.count < $1.count }) else { return url.lastPathComponent }
        let rel = String(path.dropFirst(root.count + 1))
        return includeRootName ? URL(fileURLWithPath: root).lastPathComponent + "/" + rel : rel
    }

    public struct Result: Sendable {
        public var copied: [TransferItem] = []
        public var failed: [(TransferItem, String)] = []
        public var skippedExisting: [TransferItem] = []
    }

    /// Kopiuje i (opcjonalnie) sprawdza kopię bajt po bajcie. Istniejących plików w celu NIE nadpisuje.
    /// Kopia, która nie przeszła weryfikacji, jest usuwana (to nasz własny, świeży plik — oryginał zostaje nietknięty).
    public static func copy(_ items: [TransferItem], verify: Bool, progress: ProgressHandler?) throws -> Result {
        let fm = FileManager.default
        var r = Result()
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0
        for (i, it) in items.enumerated() {
            try Task.checkCancellation()
            progress?(ScanProgress(phase: .copying, done: i, total: items.count, bytesDone: done, bytesTotal: total, current: it.source.path))
            if fm.fileExists(atPath: it.target.path) { r.skippedExisting.append(it); done += it.size; continue }
            do {
                try fm.createDirectory(at: it.target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: it.source, to: it.target)
                if verify {
                    progress?(ScanProgress(phase: .verifying, done: i, total: items.count, bytesDone: done, bytesTotal: total, current: it.target.path))
                    let a = try ContentHasher.fullHash(it.source), b = try ContentHasher.fullHash(it.target)
                    guard a == b else {
                        try? fm.removeItem(at: it.target)
                        r.failed.append((it, "kopia różni się od oryginału — usunięta, oryginał nietknięty")); done += it.size; continue
                    }
                }
                r.copied.append(it)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                r.failed.append((it, error.localizedDescription))
            }
            done += it.size
        }
        progress?(ScanProgress(phase: .done, done: items.count, total: items.count, bytesDone: total, bytesTotal: total))
        return r
    }

    /// Lustro: cel ma wyglądać dokładnie jak źródło (po ścieżkach względnych).
    public struct MirrorPlan: Sendable {
        /// Nowe albo zmienione pliki do skopiowania.
        public var toCopy: [TransferItem]
        /// Pliki w celu, które zostaną ZASTĄPIONE (stara wersja idzie do Kosza).
        public var toReplace: [URL]
        /// Pliki w celu, których nie ma w źródle — pójdą do Kosza.
        public var toTrash: [ScannedFile]
    }

    public static func planMirror(source: URL, target: URL, walk: WalkOptions, progress: ProgressHandler?) throws -> MirrorPlan {
        var w = walk
        w.minSize = 1
        let src = try FileWalker.files(in: [source], options: w, progress: progress)
        let dst = FileManager.default.fileExists(atPath: target.path) ? try FileWalker.files(in: [target], options: w, progress: progress) : []
        let s = FileWalker.canonical(source.path), t = FileWalker.canonical(target.path)
        func rel(_ f: ScannedFile, _ root: String) -> String { String(FileWalker.canonical(f.url.path).dropFirst(root.count + 1)) }
        let dstByRel = Dictionary(dst.map { (rel($0, t), $0) }, uniquingKeysWith: { a, _ in a })
        let srcRels = Set(src.map { rel($0, s) })
        var copy: [TransferItem] = [], replace: [URL] = []
        for (i, f) in src.enumerated() {
            try Task.checkCancellation()
            if i % 50 == 0 { progress?(ScanProgress(phase: .sampling, done: i, total: src.count, current: f.url.path)) }
            let r = rel(f, s)
            let targetURL = URL(fileURLWithPath: t).appendingPathComponent(r)
            if let d = dstByRel[r] {
                // Ten sam rozmiar + te same próbki = bez zmian. Inaczej: nowa wersja zastępuje starą (stara do Kosza).
                if d.size == f.size, (try? ContentHasher.sampleHash(d.url, size: d.size)) == (try? ContentHasher.sampleHash(f.url, size: f.size)) { continue }
                replace.append(d.url)
            }
            copy.append(TransferItem(source: f.url, target: targetURL, size: f.size))
        }
        let trash = dst.filter { !srcRels.contains(rel($0, t)) }
        return MirrorPlan(toCopy: copy, toReplace: replace, toTrash: trash)
    }
}
