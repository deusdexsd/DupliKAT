import AppKit
import DubelCore
import SwiftUI

/// Rola dysku: „backup” (M — tu lądują karty, eksporty, projekty) → „kopia backupu” (M2). Backupów i kopii może być kilka.
struct DriveRole: Codable, Hashable {
    enum Kind: String, Codable { case ingest, backup }
    var kind: Kind
    /// Dla kopii: klucz dysku, którego to jest kopia.
    var of: String?
}

/// Wpis w historii dysku: co i kiedy z nim zrobiono (skan, sprawdzenie, dogranie, podłączenie).
struct DriveEvent: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var symbol: String
    var text: String
}

/// Pamięć dysków: zapamiętana zawartość (także odłączonych) + role i „co czeka na kopię” + historia działań.
@MainActor
final class DriveMemory: ObservableObject {
    @Published private(set) var catalogs: [String: DriveCatalog] = [:]
    /// Historia działań na dysku (ostatnie 60 wpisów na dysk). Zostaje po przełączeniu widoku i po restarcie.
    @Published private(set) var history: [String: [DriveEvent]] = [:]
    /// Klucz dysku, którego zawartość właśnie zapamiętuję.
    @Published private(set) var indexing: (key: String, name: String, progress: ScanProgress)?
    weak var app: AppModel?
    private var queue: [VolumeUsage] = []
    private var task: Task<Void, Never>?

    static var dir: URL { AppPaths.support.appendingPathComponent("dyski") }

    static var historyFile: URL { AppPaths.support.appendingPathComponent("historia-dyskow.json") }

    init() {
        for c in DriveCatalog.load(from: Self.dir) { catalogs[c.key] = c }
        if let d = try? Data(contentsOf: Self.historyFile), let h = try? JSONDecoder().decode([String: [DriveEvent]].self, from: d) { history = h }
    }

    // MARK: Historia

    func log(_ key: String, _ symbol: String, _ text: String) {
        var list = history[key] ?? []
        list.insert(DriveEvent(date: Date(), symbol: symbol, text: text), at: 0)
        history[key] = Array(list.prefix(60))
        try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
        try? JSONEncoder().encode(history).write(to: Self.historyFile, options: .atomic)
    }

    /// Wpis dla dysków, na których leżą podane miejsca (np. korzenie skanu).
    func log(paths: [URL], _ symbol: String, _ text: String) {
        var keys: [String] = []
        for u in paths {
            // Dysk o najdłuższym pasującym punkcie montowania („/Volumes/M” przed „/”).
            let v = (app?.volumes ?? []).filter { v in v.url.path == "/" || u.path == v.url.path || u.path.hasPrefix(v.url.path + "/") }
                .max { $0.url.path.count < $1.url.path.count }
            if let v, !keys.contains(v.key) { keys.append(v.key) }
        }
        for k in keys { log(k, symbol, text) }
    }

    func clearHistory(_ key: String) {
        history[key] = nil
        try? JSONEncoder().encode(history).write(to: Self.historyFile, options: .atomic)
    }

    private var prefs: Prefs? { app?.prefs }

    // MARK: Role

    func role(_ key: String) -> DriveRole? { prefs?.auto.driveRoles[key] }
    func setRole(_ key: String, _ r: DriveRole?) {
        prefs?.auto.driveRoles[key] = r
        if r != nil, let v = app?.volumes.first(where: { $0.key == key }) { remember(v, force: false) }
    }

    /// Nazwa dysku po kluczu — podłączonego albo zapamiętanego.
    func name(_ key: String) -> String {
        app?.volumes.first { $0.key == key }?.name ?? catalogs[key]?.name ?? key
    }

    /// Dyski z kopią danego backupu (M → M2, M → M3…).
    func backupKeys(of ingest: String) -> [String] {
        (prefs?.auto.driveRoles ?? [:]).filter { $0.value.kind == .backup && $0.value.of == ingest }.keys.sorted { name($0) < name($1) }
    }

    /// „Backup” / „kopia M” — do wyświetlenia przy dysku.
    func roleTitle(_ key: String) -> String? {
        guard let r = role(key) else { return nil }
        switch r.kind {
        case .ingest: return T("backup")
        case .backup: return T("kopia %@", "\(r.of.map(name) ?? "?")")
        }
    }

    /// Plik leży na dysku „backup”, który ma swoją kopię — więc brak kopii to „czeka na kopię na M2”, a nie alarm.
    func awaitingNote(for file: ScannedFile) -> String? {
        guard let v = app?.volumes.first(where: { $0.url.path != "/" && file.url.path.hasPrefix($0.url.path + "/") }),
              role(v.key)?.kind == .ingest, case let bs = backupKeys(of: v.key), !bs.isEmpty else { return nil }
        return T("jeszcze bez kopii na %@ (leży na %@)", "\(bs.map(name).joined(separator: ", "))", "\(v.name)")
    }

    func isMounted(_ key: String) -> Bool { app?.volumes.contains { $0.key == key } == true }

    // MARK: Zapamiętywanie

    /// Zapamiętaj zawartość dysku (w tle, tylko lista plików). `force: false` = tylko, gdy stan starszy niż 6 h.
    func remember(_ v: VolumeUsage, force: Bool) {
        guard prefs?.auto.rememberDrives == true, v.url.path.hasPrefix("/Volumes/"), !v.isCard else { return }
        if !force, let c = catalogs[v.key], Date().timeIntervalSince(c.date) < 6 * 3600 { return }
        guard indexing?.key != v.key, !queue.contains(where: { $0.key == v.key }) else { return }
        queue.append(v)
        next()
    }

    func rememberAllMounted() {
        for v in app?.volumes ?? [] { remember(v, force: false) }
    }

    private func next() {
        guard indexing == nil, !queue.isEmpty, let prefs else { return }
        let v = queue.removeFirst()
        indexing = (v.key, v.name, ScanProgress(phase: .listing))
        let excluded = prefs.excludedPaths
        let dir = Self.dir
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if self?.indexing?.key == v.key { self?.indexing?.progress = p } } }
        task = Task.detached(priority: .utility) { [weak self] in
            let c = try? DriveCatalog.build(volume: v.url, key: v.key, name: v.name, excluded: excluded, progress: progress)
            try? c?.save(in: dir)
            await MainActor.run {
                guard let self else { return }
                if let c {
                    self.catalogs[c.key] = c
                    self.log(c.key, "brain", T("Zapamiętano zawartość: %@ (%@)", "\(Fmt.files(c.items.count))", "\(Fmt.bytes(c.totalSize))"))
                }
                self.indexing = nil
                self.afterRemember(v.key)
                self.next()
            }
        }
    }

    func cancelIndexing() { task?.cancel(); indexing = nil; queue = []; }

    func forget(_ key: String) {
        catalogs[key] = nil
        DriveCatalog.delete(key: key, in: Self.dir)
        prefs?.auto.driveRoles[key] = nil
        for (k, r) in prefs?.auto.driveRoles ?? [:] where r.of == key { prefs?.auto.driveRoles[k] = nil }
    }

    /// Zapamiętana zawartość odłączonych dysków, które mieszczą się w przeszukiwanych miejscach.
    func offlineIndexes(searchRoots: [URL]) -> [CatalogIndex] {
        guard prefs?.auto.rememberDrives == true else { return [] }
        let everywhere = prefs?.auto.searchLocations.isEmpty ?? true
        return catalogs.values.filter { c in
            !isMounted(c.key) && (everywhere || searchRoots.contains { c.root.hasPrefix($0.path) || $0.path.hasPrefix(c.root) })
        }.map(CatalogIndex.init)
    }

    // MARK: Co czeka na kopię

    struct Pending: Equatable {
        var ingest: String, backup: String
        var count: Int, size: Int64
        var backupDate: Date
        var backupMounted: Bool
    }

    /// Pliki z backupu, których nie ma na jego kopii (po nazwie i rozmiarze, z zapamiętanej zawartości obu dysków). Jedna pozycja na kopię.
    func pending(for ingest: String) -> [Pending] {
        guard let src = catalogs[ingest] else { return [] }
        return backupKeys(of: ingest).compactMap { b in
            guard let dst = catalogs[b] else { return nil }
            let idx = CatalogIndex(dst)
            let missing = src.items.filter { !idx.contains(name: ($0.path as NSString).lastPathComponent, size: $0.size) }
            return Pending(ingest: ingest, backup: b, count: missing.count, size: missing.reduce(0) { $0 + $1.size }, backupDate: dst.date, backupMounted: isMounted(b))
        }
    }

    var allPending: [Pending] {
        (prefs?.auto.driveRoles ?? [:]).filter { $0.value.kind == .ingest }.keys.sorted().flatMap { pending(for: $0) }.filter { $0.count > 0 }
    }

    /// Po odświeżeniu pamięci dysku: gdy oba dyski pary są podłączone i coś czeka na kopię — powiadomienie.
    private func afterRemember(_ key: String) {
        let pairs: [Pending] = pending(for: key) + (prefs?.auto.driveRoles[key]?.of.map { pending(for: $0) } ?? [])
        for p in pairs where p.count > 0 && isMounted(p.ingest) && isMounted(p.backup) {
            Notifier.send(T("%@ → %@: bez kopii %@", "\(name(p.ingest))", "\(name(p.backup))", "\(Fmt.files(p.count))"),
                          T("%@. Dograj z zachowaniem folderów — w DupliKAT → Porównaj foldery albo z okienka w pasku menu.", "\(Fmt.bytes(p.size))"), mode: .backup)
        }
    }

    /// Dograj brakujące z M na M2 z zachowaniem folderów (zwykłe „dogrywanie” pary; niczego nie usuwa).
    func copyPending(_ p: Pending) {
        guard let app, let src = app.volumes.first(where: { $0.key == p.ingest }), let dst = app.volumes.first(where: { $0.key == p.backup }) else { return }
        app.transfer.startPair(ComparePair(name: "\(src.name) → \(dst.name)", source: src.url.path, target: dst.url.path, runOnMount: false), mirror: false)
    }
}

/// Opis kopii pliku do listy: „kopia: M ▸ KLIZA/C0003.MP4 (+M2, niepodłączony)”.
@MainActor
enum CopyText {
    static func describe(_ e: BackupChecker.Entry, _ memory: DriveMemory?) -> String? {
        let all = e.allCopies
        guard let first = all.first else { return nil }
        var t = T("kopia: ") + Fmt.path(first.path)
        if !FileManager.default.fileExists(atPath: first.path) {
            let date = memory?.catalogs.values.first { first.path.hasPrefix($0.root + "/") }?.date
            t += date.map { T(" (dysk niepodłączony, stan z %@)", "\(Fmt.date.string(from: $0))") } ?? T(" (dysk niepodłączony)")
        }
        let others = e.copyDrives.dropFirst()
        if !others.isEmpty { t += " · " + T("też na: %@", "\(others.joined(separator: ", "))") }
        return t
    }

    /// „2 dyski” / „tylko M” — ile niezależnych kopii ma plik.
    static func level(_ e: BackupChecker.Entry) -> (text: String, safe: Bool) {
        let d = e.copyDrives
        return d.count >= 2 ? (T("%@ dyski: %@", "\(d.count)", "\(d.joined(separator: " + "))"), true) : (T("tylko %@", "\(d.first ?? "?")"), false)
    }
}
