import Combine
import AppKit
import DubelCore
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case duplicates, photos, media, transfer, backup, fcp, system
    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: return T("Duplikaty")
        case .photos: return T("Podobne zdjęcia")
        case .media: return T("Podobne wideo i audio")
        case .backup: return T("Porównaj foldery")
        case .transfer: return T("Karty z aparatu")
        case .fcp: return T("Pliki montażowe")
        case .system: return T("Dane systemowe")
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
        case .duplicates: return T("Pliki o identycznej zawartości, niezależnie od nazwy i folderu.")
        case .photos: return T("Ten sam obraz w innym rozmiarze, formacie albo zdjęcia z jednej serii.")
        case .media: return T("Ten sam materiał w innym eksporcie, kodeku lub rozdzielczości.")
        case .backup: return T("Czy wszystko z jednego miejsca jest w drugim? Np. folder roboczy vs dysk z archiwum. Po zawartości, nie po nazwie.")
        case .transfer: return T("Podłącz kartę — zobaczysz, co z niej jest już zgrane i gdzie, a czego nie ma nigdzie.")
        case .fcp: return T("Rendery, podglądy, proxy i cache programów do montażu. Każdy program odtworzy je sam, gdy będą potrzebne.")
        case .system: return T("Co po cichu zajmuje miejsce: cache, symulatory, kopie iPhone'a. Tylko podgląd — niczego tu nie usuwam.")
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
        case .duplicates, .photos, .media: return T("Szukaj duplikatów")
        case .transfer, .backup: return T("Kopie zapasowe")
        case .fcp, .system: return T("Miejsce na dysku")
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
    /// Wybór trybu zamyka ekran dysku.
    @Published var mode: Mode = .duplicates { didSet { if selectedDrive != nil { selectedDrive = nil } } }
    /// Dysk otwarty z paska bocznego (klucz). nil = zwykły tryb.
    @Published var selectedDrive: String?
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
    /// Pamięć dysków (zawartość odłączonych) i role karta → M → M2.
    let drives = DriveMemory()
    private var drivesSink: AnyCancellable?
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
        drives.app = self
        drivesSink = drives.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
        tasks.first.map { ($0.title, $0.progress.overall) }
    }

    /// Wszystko, co teraz trwa (do okienka przy pasku menu).
    var tasks: [RunningTask] {
        var out: [RunningTask] = []
        if let c = transfer.card {
            switch c.stage {
            case .checking(let p): out.append(RunningTask(id: "card", title: c.isSelection ? T("Szukam kopii: %@", "\(c.cardName)") : T("Sprawdzam kartę „%@”", "\(c.cardName)"), mode: .transfer, progress: p, cancel: { [weak self] in self?.transfer.closeCard() }))
            case .working(let p): out.append(RunningTask(id: "card-copy", title: T("Kopiuję z „%@”", "\(c.cardName)"), mode: .transfer, progress: p, cancel: { c.cancel() }))
            default: break
            }
        }
        if let d = drives.indexing {
            out.append(RunningTask(id: "drive-" + d.key, title: T("Zapamiętuję zawartość „%@”", "\(d.name)"), mode: .transfer, progress: d.progress, cancel: { [weak self] in self?.drives.cancelIndexing() }))
        }
        if let j = transfer.job, case .working(let p) = j.stage {
            out.append(RunningTask(id: "job", title: j.kind == .mirror ? T("Lustro — %@", "\(j.sourceName)") : T("Dogrywam brakujące — %@", "\(j.sourceName)"), mode: .backup, progress: p, cancel: { j.cancel() }))
        }
        let list: [(Mode, ScanStatus, () -> Void)] = [
            (.duplicates, duplicates.status, { [weak self] in self?.duplicates.cancel() }), (.photos, photos.status, { [weak self] in self?.photos.cancel() }),
            (.media, media.status, { [weak self] in self?.media.cancel() }), (.backup, backup.status, { [weak self] in self?.backup.cancel() }),
            (.fcp, fcp.status, { [weak self] in self?.fcp.cancel() }), (.system, system.status, { [weak self] in self?.system.cancel() }),
        ]
        for (m, s, cancel) in list { if case .running(let p) = s { out.append(RunningTask(id: m.rawValue, title: m.title, mode: m, progress: p, cancel: cancel)) } }
        return out
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
            return r.missing.isEmpty ? "✓" : T("%@ brak", "\(r.missing.count)")
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
        working = action.verb + T("…")
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

    /// Komunikat szybkiej akcji dla okienka przy pasku menu.
    @Published var quickNote: QuickNote?

    /// Zadanie skończone: wynik w okienku paska menu (z przyciskiem do wyników), dźwięk i — gdy okno nie jest na wierzchu — powiadomienie.
    /// `notify: false`, gdy dane miejsce wysyła własne powiadomienie (reguły automatyczne).
    func finished(_ title: String, _ body: String, mode: Mode, notify: Bool = true) {
        quickNote = QuickNote(text: title + " — " + body, isError: false, mode: mode)
        if prefs.auto.finishSound { NSSound(named: "Glass")?.play() }
        if notify && !NSApp.isActive { Notifier.send(title, body, mode: mode) }
    }

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey, .volumeIsBrowsableKey, .volumeIsLocalKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        volumes = urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable == true, let total = v.volumeTotalCapacity, total > 500_000_000 else { return nil }
            // „Ważne użycie” liczy też miejsce do odzyskania (APFS), ale na ExFAT/FAT zwraca 0 — bierzemy większą z dwóch wartości.
            let free = max(Int64(v.volumeAvailableCapacityForImportantUsage ?? 0), Int64(v.volumeAvailableCapacity ?? 0))
            let name = v.volumeName ?? u.lastPathComponent
            return VolumeUsage(url: u, name: name, total: Int64(total), free: free, isCard: u.path != "/" && CameraCard.isCard(u),
                               key: v.volumeUUIDString ?? name, drive: DriveInfo.read(volume: u))
        }
    }

    /// Szybkie miejsca do dodania w „Gdzie szukać”.
    var quickPlaces: [(title: String, url: URL, symbol: String)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var out: [(String, URL, String)] = [
            (T("Filmy"), home.appendingPathComponent("Movies"), "film"),
            (T("Pobrane"), home.appendingPathComponent("Downloads"), "arrow.down.circle"),
            (T("Biurko"), home.appendingPathComponent("Desktop"), "menubar.dock.rectangle"),
            (T("Muzyka"), home.appendingPathComponent("Music"), "music.note"),
            (T("Obrazy"), home.appendingPathComponent("Pictures"), "photo"),
        ]
        for v in volumes where v.url.path.hasPrefix("/Volumes/") { out.append((T("Dysk %@", "\(v.name)"), v.url, "externaldrive")) }
        return out
    }
}

struct RunningTask: Identifiable {
    let id: String
    let title: String
    let mode: Mode
    let progress: ScanProgress
    let cancel: () -> Void
}

struct VolumeUsage: Identifiable, Equatable {
    let url: URL
    let name: String
    let total: Int64
    let free: Int64
    var isCard = false
    /// Klucz do własnego opisu dysku (UUID woluminu albo nazwa).
    var key = ""
    var drive: DriveInfo?
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
                await MainActor.run {
                    guard let self else { return }
                    self.groups = result; self.status = .finished(Date())
                    self.app?.finished(T("%@: gotowe", "\(self.mode.title)"),
                                       result.isEmpty ? T("nic nie znaleziono") : T("%@, do odzyskania %@", "\(Fmt.groups(result.count))", "\(Fmt.bytes(self.reclaimable))"),
                                       mode: self.mode, notify: self.onFinish == nil)
                    self.app?.drives.log(paths: roots, self.mode.symbol, T("%@: %@, do odzyskania %@", "\(self.mode.title)", "\(Fmt.groups(result.count))", "\(Fmt.bytes(self.reclaimable))"))
                    self.fireFinish()
                }
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
            case .oldest: return T("Zostaw najstarszą kopię")
            case .newest: return T("Zostaw najnowszą kopię")
            case .shortestPath: return T("Zostaw kopię z najkrótszą ścieżką")
            case .onVolume(let v): return T("Zostaw kopię na dysku „%@”", "\(v)")
            case .inFolder(let p): return T("Zostaw kopię w „%@”", "\(Fmt.path(p))")
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
        return full.isEmpty ? [] : [T("W %@ zaznaczone są wszystkie kopie. Zostaw przynajmniej jedną w każdej grupie.", "\(Fmt.groups(full.count))")]
    }

    func notes() -> [String] {
        var n: [String] = []
        let allSimilar = groups.filter { g in !g.isExact && g.files.allSatisfy { checked.contains($0.id) } }
        if !allSimilar.isEmpty { n.append(T("W %@ podobnych zaznaczone są wszystkie pliki — z tej serii nic nie zostanie.", "\(Fmt.groups(allSimilar.count))")) }
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
            title: T("Przenieść %@ do Kosza?", "\(Fmt.files(files.count))"), verb: T("Przenoszę do Kosza"), items: items(files),
            notes: [T("Pliki trafią do Kosza — możesz je stamtąd przywrócić."),
                    T("Miejsce na dysku zwolni się dopiero po opróżnieniu Kosza") + (vols.count > 1 || vols.first != VolumeInfo.bootName ? T(" (każdy dysk zewnętrzny ma własny).") : ".")] + notes(),
            blockers: blockers(),
            perform: { [weak self] in
                let o = await FileActions.trash(files.map(\.url))
                self?.remove(o.done)
                return o
            }))
    }

    func askMove() {
        guard let app, let folder = FileActions.chooseFolder(title: T("Wybierz folder, do którego przenieść zaznaczone pliki"), prompt: T("Wybierz")).first else { return }
        let files = checkedFiles
        app.confirm(PendingAction(
            title: T("Przenieść %@ do „%@”?", "\(Fmt.files(files.count))", "\(folder.lastPathComponent)"), verb: T("Przenoszę"), style: .normal, items: items(files),
            notes: ["Cel: \(Fmt.path(folder.path))", T("Przy takiej samej nazwie plik dostanie dopisek „(2)”.")] + notes(),
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
        var notes = [T("Plik zostaje w obu miejscach, ale dane zajmują miejsce raz (klon APFS, jak „Duplikuj” w Finderze)."),
                     T("Przed zamianą każda para jest porównywana ponownie bajt po bajcie.")]
        if !skipped.isEmpty { notes.append(T("Pominięte: %@ — brak niezaznaczonej kopii na tym samym dysku APFS (np. T7-2 to exFAT).", "\(Fmt.files(skipped.count))")) }
        app.confirm(PendingAction(
            title: T("Zastąpić %@ klonami?", "\(Fmt.files(files.count))"), verb: T("Tworzę klony"), style: .normal, items: items(files), notes: notes,
            blockers: files.isEmpty ? [T("Żaden zaznaczony plik nie ma niezaznaczonej kopii na tym samym dysku APFS.")] : blockers(),
            perform: { [weak self] in
                let o = await FileActions.replaceWithClones(pairs)
                // Po klonowaniu pliki dalej istnieją, ale nie są już „do odzyskania” — znikają z listy.
                self?.remove(o.done)
                return o
            }))
    }

    func exportCSV() {
        FileActions.saveCSV(FileActions.csv(groups: groups), name: T("%@ – %@.csv", "\(AppInfo.name)", "\(mode.title)"))
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
                await MainActor.run {
                    guard let self else { return }
                    self.report = r; self.status = .finished(Date())
                    self.app?.finished(T("Porównanie: gotowe"), T("brakuje %@", "\(Fmt.files(r.missing.count))"), mode: .backup, notify: self.onFinish == nil)
                    self.fireFinish()
                }
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
            title: T("Przenieść %@ ze źródła do Kosza?", "\(Fmt.files(entries.count))"), verb: T("Przenoszę do Kosza"),
            items: entries.map { e in
                if let t = CopyText.describe(e, app.drives) { return (e.file.name, t, e.file.size) }
                return (e.file.name, Fmt.path(e.file.folder), e.file.size)
            },
            notes: [T("Każdy z tych plików ma identyczną kopię w archiwum") + (app.prefs.backupVerify ? T(" (sprawdzone bajt po bajcie).") : T(" (sprawdzone próbkami — pełna weryfikacja była wyłączona).")),
                    T("Pliki trafią do Kosza; miejsce zwolni się po jego opróżnieniu.")],
            perform: { [weak self] in
                let o = await FileActions.trash(entries.map(\.file.url))
                self?.remove(o.done)
                return o
            }))
    }

    func askCopyMissing() {
        guard let app, let r = report else { return }
        let entries = r.missing.filter { checked.contains($0.id) }
        guard let dest = FileActions.chooseFolder(title: T("Gdzie skopiować brakujące pliki? Struktura folderów ze źródła zostanie zachowana."), prompt: T("Kopiuj tutaj")).first else { return }
        let src = sources
        app.confirm(PendingAction(
            title: T("Skopiować %@ do archiwum?", "\(Fmt.files(entries.count))"), verb: T("Kopiuję"), style: .normal,
            items: entries.map { ($0.file.name, Fmt.path($0.file.folder), $0.file.size) },
            notes: ["Cel: \(Fmt.path(dest.path))", T("Oryginały zostają na miejscu. Istniejące pliki w archiwum nie są nadpisywane."),
                    T("Po skopiowaniu uruchom sprawdzanie ponownie, żeby potwierdzić kopie.")],
            perform: { [weak self] in
                let o = await FileActions.copy(entries.map(\.file.url), relativeTo: src, into: dest) { i, n in
                    Task { @MainActor in self?.app?.working = T("Kopiuję %@ z %@…", "\(i + 1 > n ? n : i + 1)", "\(n)") }
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
                await MainActor.run {
                    guard let self else { return }
                    self.libraries = libs; self.status = .finished(Date())
                    self.app?.finished(T("Pliki montażowe: gotowe"), T("%@ do przejrzenia", "\(Fmt.bytes(libs.reduce(0) { $0 + $1.folders.reduce(0) { $0 + $1.size } }))"), mode: .fcp, notify: self.onFinish == nil)
                    self.fireFinish()
                }
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
            title: T("Przenieść %@ %@ plików FCP do Kosza?", "\(folders.count)", "\(Fmt.plural(folders.count, "folder", "foldery", T("folderów")))"), verb: T("Przenoszę do Kosza"),
            items: folders.map { f in ("\(f.kind.title) · \(libName(f))", f.event.map { T("wydarzenie „%@”", "\($0)") } ?? Fmt.path(f.url.path), f.size) },
            notes: kinds.map { "\($0.title): \($0.consequence)" } + [
                T("Oryginalne media, projekty i autozapisy nie są ruszane."),
                T("Kopie bibliotek zrobione w Finderze mogą dzielić te pliki (APFS) — wtedy miejsce zwolni się dopiero, gdy znikną ze wszystkich kopii."),
            ],
            blockers: FileActions.runningEditors(Set(folders.compactMap { f in self.libraries.first { $0.folders.contains(f) }?.app })).map {
                T("%@ jest uruchomiony. Zamknij go (⌘Q) i kliknij akcję jeszcze raz — nie usuwamy plików spod otwartego programu.", "\($0.title)")
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
