import AppKit
import DubelCore
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case duplicates, photos, media, transfer, backup, fcp, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: return "Duplikaty"
        case .photos: return "Podobne zdjęcia"
        case .media: return "Podobne wideo i audio"
        case .backup: return "Porównaj foldery"
        case .transfer: return "Karty z aparatu"
        case .fcp: return "Pliki montażowe"
        case .system: return "Dane systemowe"
        }
    }

    var symbol: String {
        switch self {
        case .duplicates: return "doc.on.doc"
        case .photos: return "photo.stack"
        case .media: return "film.stack"
        case .backup: return "arrow.left.arrow.right"
        case .transfer: return "sdcard"
        case .fcp: return "film"
        case .system: return "gauge.with.dots.needle.67percent"
        }
    }

    var subtitle: String {
        switch self {
        case .duplicates: return "Pliki o identycznej zawartości, niezależnie od nazwy i folderu."
        case .photos: return "Ten sam obraz w innym rozmiarze, formacie albo zdjęcia z jednej serii."
        case .media: return "Ten sam materiał w innym eksporcie, kodeku lub rozdzielczości."
        case .backup: return "Czy wszystko z jednego miejsca jest w drugim? Np. folder roboczy vs dysk z archiwum. Po zawartości, nie po nazwie."
        case .transfer: return "Podłącz kartę — zobaczysz, co z niej jest już zgrane i gdzie, a czego nie ma nigdzie."
        case .fcp: return "Rendery, podglądy, proxy i cache programów do montażu. Każdy program odtworzy je sam, gdy będą potrzebne."
        case .system: return "Co po cichu zajmuje miejsce: cache, symulatory, kopie iPhone'a. Tylko podgląd — niczego tu nie usuwam."
        }
    }

    /// Stały kolor trybu (ikona w pasku bocznym, poświata i nagłówek w stylu „jak przewodnik”).
    var color: Color {
        switch self {
        case .duplicates: return Theme.accent.primary
        case .photos: return Color(nsColor: .systemTeal)
        case .media: return Color(nsColor: .systemOrange)
        case .backup: return Color(nsColor: .systemIndigo)
        case .transfer: return Color(nsColor: .systemBlue)
        case .fcp: return Color(nsColor: .systemPurple)
        case .system: return Color(nsColor: .systemGray)
        }
    }

    /// Grupa w pasku bocznym.
    var section: String {
        switch self {
        case .duplicates, .photos, .media: return "Szukaj duplikatów"
        case .transfer, .backup: return "Kopie zapasowe"
        case .fcp, .system: return "Miejsce na dysku"
        }
    }
}

enum ScanStatus: Equatable {
    case idle
    case running(ScanProgress)
    case finished(Date)
    case failed(String)

    var isRunning: Bool { if case .running = self { return true } else { return false } }
}

/// Akcja czekająca na potwierdzenie. Nic nie dzieje się bez kliknięcia w oknie potwierdzenia.
struct PendingAction: Identifiable {
    enum Style { case destructive, normal }
    let id = UUID()
    var title: String
    var verb: String
    var style: Style = .destructive
    var items: [(name: String, detail: String, size: Int64)]
    var notes: [String] = []
    /// Jeśli niepuste — przycisk akcji jest zablokowany, a powód pokazany na czerwono.
    var blockers: [String] = []
    var perform: @MainActor () async -> FileActions.Outcome

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: Mode = .duplicates
    @Published var pending: PendingAction?
    @Published var toast: String?
    @Published var working: String?
    @Published var volumes: [VolumeUsage] = []
    /// Ustawiane przez AppDelegate: pokazuje główne okno (reguły automatyczne i menu w pasku go używają).
    var showMainWindow: (() -> Void)?

    let prefs: Prefs
    let duplicates: GroupScanModel
    let photos: GroupScanModel
    let media: GroupScanModel
    let backup: BackupModel
    let fcp: FCPModel
    let transfer: TransferModel
    let system: SystemModel
    private(set) lazy var automation = AutomationEngine(app: self)
    private(set) lazy var cache = HashCache(fileURL: prefs.useCache ? AppPaths.cacheFile : nil)

    init(prefs: Prefs) {
        self.prefs = prefs
        duplicates = GroupScanModel(mode: .duplicates)
        photos = GroupScanModel(mode: .photos)
        media = GroupScanModel(mode: .media)
        backup = BackupModel()
        fcp = FCPModel()
        transfer = TransferModel()
        system = SystemModel()
        for m in [duplicates, photos, media] { m.app = self }
        backup.app = self
        fcp.app = self
        transfer.app = self
        system.app = self
        refreshVolumes()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refreshVolumes() } }
        }
    }

    /// Programy do montażu na tym Macu. Bez żadnego z nich tryb „Pliki montażowe” jest ukryty (chyba że włączysz go w Ustawieniach).
    let installedEditors: [EditorApp] = EditorApp.allCases.filter { FileActions.isInstalled($0) }
    var hasFinalCut: Bool { !installedEditors.isEmpty }

    var visibleModes: [Mode] {
        Mode.allCases.filter { m in
            if prefs.auto.hiddenModes.contains(m.rawValue) { return false }
            if m == .fcp && !hasFinalCut && !prefs.auto.fcpForced { return false }
            return true
        }
    }

    /// Aktualny postęp (do paska menu): co trwa i ile procent (nil = nieznane).
    var currentProgress: (String, Double?)? {
        if let c = transfer.card {
            switch c.stage {
            case .checking(let p): return ("sprawdzam „\(c.cardName)”", p.fraction)
            case .working(let p): return ("kopiuję z „\(c.cardName)”", p.fraction)
            default: break
            }
        }
        for (m, s) in [(Mode.duplicates, duplicates.status), (.photos, photos.status), (.media, media.status), (.backup, backup.status), (.fcp, fcp.status), (.system, system.status)] {
            if case .running(let p) = s { return (m.title, p.fraction) }
        }
        return nil
    }

    @Published var tourActive = false
    @Published var tourStep = 0

    func groupModel(_ m: Mode) -> GroupScanModel? {
        switch m {
        case .duplicates: return duplicates
        case .photos: return photos
        case .media: return media
        default: return nil
        }
    }

    func isRunning(_ m: Mode) -> Bool {
        switch m {
        case .backup: return backup.status.isRunning
        case .fcp: return fcp.status.isRunning
        case .system: return system.status.isRunning
        case .transfer: return (transfer.job?.isBusy ?? false) || (transfer.card?.isBusy ?? false)
        default: return groupModel(m)?.status.isRunning ?? false
        }
    }

    /// Krótka informacja w pasku bocznym (np. „12,4 GB”) po zakończonym skanie.
    func badge(_ m: Mode) -> String? {
        switch m {
        case .backup:
            guard case .finished = backup.status, let r = backup.report else { return nil }
            return r.missing.isEmpty ? "✓" : "\(r.missing.count) brak"
        case .fcp:
            guard case .finished = fcp.status else { return nil }
            return Fmt.bytes(fcp.libraries.reduce(0) { $0 + $1.total })
        case .system:
            guard let d = system.totalDelta, d != 0 else { return nil }
            return (d > 0 ? "+" : "−") + Fmt.bytes(abs(d))
        case .transfer:
            let cards = volumes.filter(\.isCard).count
            return cards > 0 ? "\(cards) \(Fmt.plural(cards, "karta", "karty", "kart"))" : nil
        default:
            guard let g = groupModel(m), case .finished = g.status else { return nil }
            return Fmt.bytes(g.groups.reduce(0) { $0 + $1.reclaimable })
        }
    }

    func resetCache() {
        cache.clear()
        cache = HashCache(fileURL: prefs.useCache ? AppPaths.cacheFile : nil)
    }

    func confirm(_ action: PendingAction) { pending = action }

    func run(_ action: PendingAction) {
        pending = nil
        working = action.verb + "…"
        Task {
            let outcome = await action.perform()
            working = nil
            show(outcome.summary + (outcome.failed.first.map { "\n\($0.0.lastPathComponent): \($0.1)" } ?? ""))
            refreshVolumes()
        }
    }

    func show(_ message: String) {
        toast = message
        let current = message
        Task {
            try? await Task.sleep(for: .seconds(6))
            if toast == current { toast = nil }
        }
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey, .volumeIsLocalKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true, let total = v.volumeTotalCapacity, total > 500_000_000 else { return nil }
            let free = v.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? Int64(v.volumeAvailableCapacity ?? 0)
            return VolumeUsage(url: u, name: v.volumeName ?? u.lastPathComponent, total: Int64(total), free: free, isCard: u.path != "/" && CameraCard.isCard(u))
        }
    }

    /// Szybkie miejsca do dodania w „Gdzie szukać”.
    var quickPlaces: [(title: String, url: URL, symbol: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [(String, URL, String)] = [
            ("Filmy", home.appendingPathComponent("Movies"), "film"),
            ("Pobrane", home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            ("Biurko", home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            ("Muzyka", home.appendingPathComponent("Music"), "music.note"),
            ("Obrazy", home.appendingPathComponent("Pictures"), "photo"),
        ]
        for v in volumes where v.url.path.hasPrefix("/Volumes/") { out.append(("Dysk \(v.name)", v.url, "externaldrive")) }
        return out
    }
}

struct VolumeUsage: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    var isCard = false
    var id: String { url.path }
    var used: Double { total > 0 ? Double(total - free) / Double(total) : 0 }
}

// MARK: - Duplikaty / podobne

@MainActor
final class GroupScanModel: ObservableObject {
    let mode: Mode
    weak var app: AppModel?

    @Published var roots: [URL] { didSet { Prefs.setPaths(roots, "roots.\(mode.rawValue)") } }
    @Published var status: ScanStatus = .idle
    @Published var groups: [DuplicateGroup] = []
    @Published var checked: Set<String> = []
    @Published var filter: MediaKind?
    /// Tylko dla trybu wideo/audio: co porównywać.
    @Published var mediaKinds: Set<MediaKind> = [.video, .audio]
    /// Tylko dla duplikatów: jakie rodzaje plików brać pod uwagę.
    @Published var kinds: Set<MediaKind> = Set(MediaKind.allCases)
    /// Co pominięto w ostatnim skanie (iCloud, brak dostępu, foldery chronione).
    @Published var log = ScanLog()
    private var task: Task<Void, Never>?

    init(mode: Mode) {
        self.mode = mode
        roots = Prefs.paths("roots.\(mode.rawValue)")
    }

    var visibleGroups: [DuplicateGroup] { filter.map { k in groups.filter { $0.kind == k } } ?? groups }
    var reclaimable: Int64 { groups.reduce(0) { $0 + $1.reclaimable } }
    var allFiles: [ScannedFile] { groups.flatMap(\.files) }
    var checkedFiles: [ScannedFile] { allFiles.filter { checked.contains($0.id) } }
    var checkedSize: Int64 { checkedFiles.reduce(0) { $0 + $1.size } }

    func start() {
        guard let app, !roots.isEmpty else { return }
        cancel()
        let prefs = app.prefs
        let cache = prefs.useCache ? app.cache : nil
        let roots = self.roots
        let mode = self.mode
        log = ScanLog()
        var walk = prefs.walk(minSize: mode == .duplicates ? nil : 1, log: log)
        if mode == .duplicates, kinds.count < MediaKind.allCases.count { walk.kinds = kinds }
        let quick = prefs.quickMode
        let thresholds = SimilarityFinder.Thresholds(imageDistance: prefs.photoSensitivity.imageDistance,
                                                     videoDistance: prefs.mediaSensitivity.videoDistance,
                                                     audio: prefs.mediaSensitivity.audioCorrelation)
        let mediaKinds = mode == .photos ? Set([MediaKind.image]) : self.mediaKinds
        groups = []; checked = []; filter = nil
        status = .running(ScanProgress(phase: .listing))
        let report: ProgressHandler = { [weak self] p in Task { @MainActor in if self?.status.isRunning == true { self?.status = .running(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let result: [DuplicateGroup]
                if mode == .duplicates {
                    result = try await DuplicateFinder(walk: walk, verifyFullContent: !quick, cache: cache).run(roots: roots, progress: report)
                } else {
                    result = try await SimilarityFinder(walk: walk, thresholds: thresholds, cache: cache).run(roots: roots, kinds: mediaKinds, progress: report)
                }
                await MainActor.run { self?.groups = result; self?.status = .finished(Date()); self?.fireFinish() }
            } catch is CancellationError {
                await MainActor.run { self?.status = .idle }
            } catch {
                await MainActor.run { self?.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Wywoływane raz po zakończonym skanie (reguły automatyczne wysyłają wtedy powiadomienie).
    var onFinish: (@MainActor () -> Void)?
    func fireFinish() { let f = onFinish; onFinish = nil; f?() }

    func cancel() { task?.cancel(); task = nil; if status.isRunning { status = .idle } }

    func toggle(_ f: ScannedFile) { if checked.contains(f.id) { checked.remove(f.id) } else { checked.insert(f.id) } }

    /// Usuwa z wyników pliki, których już nie ma (po akcji), i grupy, w których został jeden plik.
    func remove(_ urls: [URL]) {
        let gone = Set(urls.map(\.path))
        groups = groups.compactMap { g in
            var g = g
            g.files.removeAll { gone.contains($0.url.path) }
            return g.files.count > 1 ? g : nil
        }
        checked.subtract(gone)
    }

    // MARK: Zaznaczanie według reguły (na Twoje kliknięcie — to tylko zaznaczenie, nic się nie usuwa)

    enum KeepRule: Hashable {
        case oldest, newest, shortestPath, onVolume(String), inFolder(String)
        var title: String {
            switch self {
            case .oldest: return "Zostaw najstarszą kopię"
            case .newest: return "Zostaw najnowszą kopię"
            case .shortestPath: return "Zostaw kopię z najkrótszą ścieżką"
            case .onVolume(let v): return "Zostaw kopię na dysku „\(v)”"
            case .inFolder(let p): return "Zostaw kopię w „\(Fmt.path(p))”"
            }
        }
    }

    func select(keeping rule: KeepRule) {
        var result = Set<String>()
        for g in visibleGroups {
            let keeper: ScannedFile?
            switch rule {
            case .oldest: keeper = g.files.min { ($0.created ?? $0.modified) < ($1.created ?? $1.modified) }
            case .newest: keeper = g.files.max { $0.modified < $1.modified }
            case .shortestPath: keeper = g.files.min { $0.url.path.count < $1.url.path.count }
            case .onVolume(let v): keeper = g.files.first { $0.volumeName == v }
            case .inFolder(let p): keeper = g.files.first { $0.url.path.hasPrefix(p + "/") }
            }
            guard let keeper else { continue } // grupy bez kopii na wskazanym dysku zostają nietknięte
            for f in g.files where f.id != keeper.id { result.insert(f.id) }
        }
        checked = result
    }

    var volumesInResults: [String] { Array(Set(allFiles.map(\.volumeName))).sorted() }

    // MARK: Akcje (każda przez okno potwierdzenia)

    func blockers() -> [String] {
        let full = groups.filter { g in g.isExact && g.files.allSatisfy { checked.contains($0.id) } }
        return full.isEmpty ? [] : ["W \(Fmt.groups(full.count)) zaznaczone są wszystkie kopie. Zostaw przynajmniej jedną w każdej grupie."]
    }

    func notes() -> [String] {
        var n: [String] = []
        let allSimilar = groups.filter { g in !g.isExact && g.files.allSatisfy { checked.contains($0.id) } }
        if !allSimilar.isEmpty { n.append("W \(Fmt.groups(allSimilar.count)) podobnych zaznaczone są wszystkie pliki — z tej serii nic nie zostanie.") }
        return n
    }

    private func items(_ files: [ScannedFile]) -> [(name: String, detail: String, size: Int64)] {
        files.map { ($0.name, Fmt.path($0.folder), $0.size) }
    }

    func askTrash() {
        guard let app else { return }
        let files = checkedFiles
        let vols = Set(files.map(\.volumeName))
        app.confirm(PendingAction(
            title: "Przenieść \(Fmt.files(files.count)) do Kosza?", verb: "Przenoszę do Kosza", items: items(files),
            notes: ["Pliki trafią do Kosza — możesz je stamtąd przywrócić.",
                    "Miejsce na dysku zwolni się dopiero po opróżnieniu Kosza" + (vols.count > 1 || vols.first != VolumeInfo.bootName ? " (każdy dysk zewnętrzny ma własny)." : ".")] + notes(),
            blockers: blockers(),
            perform: { [weak self] in
                let o = await FileActions.trash(files.map(\.url))
                self?.remove(o.done)
                return o
            }))
    }

    func askMove() {
        guard let app, let folder = FileActions.chooseFolder(title: "Wybierz folder, do którego przenieść zaznaczone pliki", prompt: "Wybierz").first else { return }
        let files = checkedFiles
        app.confirm(PendingAction(
            title: "Przenieść \(Fmt.files(files.count)) do „\(folder.lastPathComponent)”?", verb: "Przenoszę", style: .normal, items: items(files),
            notes: ["Cel: \(Fmt.path(folder.path))", "Przy takiej samej nazwie plik dostanie dopisek „(2)”."] + notes(),
            blockers: blockers(),
            perform: { [weak self] in
                let o = await FileActions.move(files.map(\.url), to: folder)
                self?.remove(o.done)
                return o
            }))
    }

    /// Klon APFS: dla każdego zaznaczonego pliku szukamy NIEzaznaczonej kopii na tym samym dysku APFS.
    func askClone() {
        guard let app else { return }
        var pairs: [(duplicate: URL, keeper: URL)] = []
        var skipped: [ScannedFile] = []
        for g in groups where g.match == .identical {
            let keepers = g.files.filter { !checked.contains($0.id) }
            for f in g.files where checked.contains(f.id) {
                if let k = keepers.first(where: { $0.identity?.device == f.identity?.device }), VolumeInfo.supportsCloning(f.url) {
                    pairs.append((f.url, k.url))
                } else { skipped.append(f) }
            }
        }
        let files = allFiles.filter { f in pairs.contains { $0.duplicate == f.url } }
        var notes = ["Plik zostaje w obu miejscach, ale dane zajmują miejsce raz (klon APFS, jak „Duplikuj” w Finderze).",
                     "Przed zamianą każda para jest porównywana ponownie bajt po bajcie."]
        if !skipped.isEmpty { notes.append("Pominięte: \(Fmt.files(skipped.count)) — brak niezaznaczonej kopii na tym samym dysku APFS (np. T7-2 to exFAT).") }
        app.confirm(PendingAction(
            title: "Zastąpić \(Fmt.files(files.count)) klonami?", verb: "Tworzę klony", style: .normal, items: items(files), notes: notes,
            blockers: files.isEmpty ? ["Żaden zaznaczony plik nie ma niezaznaczonej kopii na tym samym dysku APFS."] : blockers(),
            perform: { [weak self] in
                let o = await FileActions.replaceWithClones(pairs)
                // Po klonowaniu pliki dalej istnieją, ale nie są już „do odzyskania” — znikają z listy.
                self?.remove(o.done)
                return o
            }))
    }

    func exportCSV() {
        FileActions.saveCSV(FileActions.csv(groups: groups), name: "\(AppInfo.name) – \(mode.title).csv")
    }
}

// MARK: - Backup

@MainActor
final class BackupModel: ObservableObject {
    weak var app: AppModel?
    @Published var sources: [URL] { didSet { Prefs.setPaths(sources, "roots.backup.src") } }
    @Published var backups: [URL] { didSet { Prefs.setPaths(backups, "roots.backup.dst") } }
    @Published var status: ScanStatus = .idle
    @Published var report: BackupChecker.Report?
    @Published var checked: Set<String> = []
    @Published var log = ScanLog()
    private var task: Task<Void, Never>?

    init() {
        sources = Prefs.paths("roots.backup.src")
        backups = Prefs.paths("roots.backup.dst")
    }

    func start() {
        guard let app, !sources.isEmpty, !backups.isEmpty else { return }
        cancel()
        log = ScanLog()
        let checker = BackupChecker(walk: app.prefs.walk(minSize: 1, log: log), verifyFullContent: app.prefs.backupVerify, cache: app.prefs.useCache ? app.cache : nil)
        let (src, dst) = (sources, backups)
        report = nil; checked = []
        status = .running(ScanProgress(phase: .listing))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if self?.status.isRunning == true { self?.status = .running(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await checker.run(sources: src, backups: dst, progress: progress)
                await MainActor.run { self?.report = r; self?.status = .finished(Date()); self?.fireFinish() }
            } catch is CancellationError {
                await MainActor.run { self?.status = .idle }
            } catch {
                await MainActor.run { self?.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Wywoływane raz po zakończonym skanie (reguły automatyczne wysyłają wtedy powiadomienie).
    var onFinish: (@MainActor () -> Void)?
    func fireFinish() { let f = onFinish; onFinish = nil; f?() }

    func cancel() { task?.cancel(); task = nil; if status.isRunning { status = .idle } }

    func remove(_ urls: [URL]) {
        let gone = Set(urls.map(\.path))
        report?.entries.removeAll { gone.contains($0.file.url.path) }
        checked.subtract(gone)
    }

    func askTrashBackedUp() {
        guard let app, let r = report else { return }
        let entries = r.backedUp.filter { checked.contains($0.id) }
        app.confirm(PendingAction(
            title: "Przenieść \(Fmt.files(entries.count)) ze źródła do Kosza?", verb: "Przenoszę do Kosza",
            items: entries.map { e in
                if case .backedUp(let copies) = e.status { return (e.file.name, "kopia: " + Fmt.path(copies[0].path), e.file.size) }
                return (e.file.name, Fmt.path(e.file.folder), e.file.size)
            },
            notes: ["Każdy z tych plików ma identyczną kopię w archiwum" + (app.prefs.backupVerify ? " (sprawdzone bajt po bajcie)." : " (sprawdzone próbkami — pełna weryfikacja była wyłączona)."),
                    "Pliki trafią do Kosza; miejsce zwolni się po jego opróżnieniu."],
            perform: { [weak self] in
                let o = await FileActions.trash(entries.map(\.file.url))
                self?.remove(o.done)
                return o
            }))
    }

    func askCopyMissing() {
        guard let app, let r = report else { return }
        let entries = r.missing.filter { checked.contains($0.id) }
        guard let dest = FileActions.chooseFolder(title: "Gdzie skopiować brakujące pliki? Struktura folderów ze źródła zostanie zachowana.", prompt: "Kopiuj tutaj").first else { return }
        let src = sources
        app.confirm(PendingAction(
            title: "Skopiować \(Fmt.files(entries.count)) do archiwum?", verb: "Kopiuję", style: .normal,
            items: entries.map { ($0.file.name, Fmt.path($0.file.folder), $0.file.size) },
            notes: ["Cel: \(Fmt.path(dest.path))", "Oryginały zostają na miejscu. Istniejące pliki w archiwum nie są nadpisywane.",
                    "Po skopiowaniu uruchom sprawdzanie ponownie, żeby potwierdzić kopie."],
            perform: { [weak self] in
                let o = await FileActions.copy(entries.map(\.file.url), relativeTo: src, into: dest) { i, n in
                    Task { @MainActor in self?.app?.working = "Kopiuję \(i + 1 > n ? n : i + 1) z \(n)…" }
                }
                return o
            }))
    }
}

// MARK: - Pliki FCP

@MainActor
final class FCPModel: ObservableObject {
    weak var app: AppModel?
    @Published var roots: [URL] { didSet { Prefs.setPaths(roots, "roots.fcp") } }
    @Published var status: ScanStatus = .idle
    @Published var libraries: [LibraryReport] = []
    @Published var checked: Set<String> = []
    private var task: Task<Void, Never>?

    init() {
        let saved = Prefs.paths("roots.fcp")
        roots = saved.isEmpty ? [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")] : saved
    }

    var allFolders: [GeneratedFolder] { libraries.flatMap(\.folders) }
    var checkedFolders: [GeneratedFolder] { allFolders.filter { checked.contains($0.id) } }
    var total: Int64 { libraries.reduce(0) { $0 + $1.total } }
    func total(_ k: GeneratedKind) -> Int64 { libraries.reduce(0) { $0 + $1.size(of: k) } }

    func start() {
        guard let app, !roots.isEmpty else { return }
        cancel()
        let (r, excluded) = (roots, app.prefs.excludedPaths)
        libraries = []; checked = []
        status = .running(ScanProgress(phase: .listing))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if self?.status.isRunning == true { self?.status = .running(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let libs = try FCPGeneratedScanner.scan(roots: r, excluded: excluded, progress: progress)
                await MainActor.run { self?.libraries = libs; self?.status = .finished(Date()); self?.fireFinish() }
            } catch is CancellationError {
                await MainActor.run { self?.status = .idle }
            } catch {
                await MainActor.run { self?.status = .failed(error.localizedDescription) }
            }
        }
    }

    /// Wywoływane raz po zakończonym skanie (reguły automatyczne wysyłają wtedy powiadomienie).
    var onFinish: (@MainActor () -> Void)?
    func fireFinish() { let f = onFinish; onFinish = nil; f?() }

    func cancel() { task?.cancel(); task = nil; if status.isRunning { status = .idle } }

    func select(kind: GeneratedKind, on: Bool) {
        let ids = allFolders.filter { $0.kind == kind }.map(\.id)
        if on { checked.formUnion(ids) } else { checked.subtract(ids) }
    }

    func isSelected(kind: GeneratedKind) -> Bool {
        let ids = allFolders.filter { $0.kind == kind }.map(\.id)
        return !ids.isEmpty && ids.allSatisfy { checked.contains($0) }
    }

    func askTrash() {
        guard let app else { return }
        let folders = checkedFolders
        let kinds = GeneratedKind.allCases.filter { k in folders.contains { $0.kind == k } }
        let libName: (GeneratedFolder) -> String = { f in self.libraries.first { $0.folders.contains(f) }?.name ?? "" }
        app.confirm(PendingAction(
            title: "Przenieść \(folders.count) \(Fmt.plural(folders.count, "folder", "foldery", "folderów")) plików FCP do Kosza?", verb: "Przenoszę do Kosza",
            items: folders.map { f in ("\(f.kind.title) · \(libName(f))", f.event.map { "wydarzenie „\($0)”" } ?? Fmt.path(f.url.path), f.size) },
            notes: kinds.map { "\($0.title): \($0.consequence)" } + [
                "Oryginalne media, projekty i autozapisy nie są ruszane.",
                "Kopie bibliotek zrobione w Finderze mogą dzielić te pliki (APFS) — wtedy miejsce zwolni się dopiero, gdy znikną ze wszystkich kopii.",
            ],
            blockers: FileActions.runningEditors(Set(folders.compactMap { f in self.libraries.first { $0.folders.contains(f) }?.app })).map {
                "\($0.title) jest uruchomiony. Zamknij go (⌘Q) i kliknij akcję jeszcze raz — nie usuwamy plików spod otwartego programu."
            },
            perform: { [weak self] in
                let o = await FileActions.trash(folders.map(\.url))
                let gone = Set(o.done.map(\.path))
                self?.libraries = (self?.libraries ?? []).map { l in LibraryReport(url: l.url, isExternalFolder: l.isExternalFolder, folders: l.folders.filter { !gone.contains($0.url.path) }, app: l.app, label: l.label) }.filter { $0.total > 0 }
                self?.checked.subtract(gone)
                return o
            }))
    }
}
