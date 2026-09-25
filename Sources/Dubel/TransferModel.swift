import AppKit
import Combine
import DubelCore
import SwiftUI

/// Jedno zgrywanie (karta → cel) albo „dodaj brakujące” / lustro dla stałej pary. Prowadzi przez etapy:
/// liczenie → Ty wybierasz i potwierdzasz → kopiowanie z weryfikacją → raport.
@MainActor
final class TransferJob: ObservableObject, Identifiable {
    enum Kind: Equatable { case card, pairAdd, mirror }
    enum Stage: Equatable {
        case planning(ScanProgress)
        case ready
        case working(ScanProgress)
        case done
        case failed(String)
    }

    let id = UUID()
    let kind: Kind
    let sourceName: String
    let sourceRoots: [URL]
    /// Wolumen karty (do wysunięcia i przycisku „Narzędzie dyskowe”).
    let cardVolume: URL?
    @Published var destination: Destination?
    @Published var template: String
    @Published var verify: Bool
    @Published var stage: Stage = .planning(ScanProgress(phase: .listing))
    @Published var plan: ImportPlan?
    @Published var mirror: Transfer.MirrorPlan?
    @Published var result: Transfer.Result?
    @Published var mirrorTrashed = 0
    @Published var mirrorConfirmed = false
    let log = ScanLog()
    private var task: Task<Void, Never>?
    weak var app: AppModel?

    var isBusy: Bool {
        switch stage { case .planning, .working: return true; default: return false }
    }

    init(kind: Kind, sourceName: String, sourceRoots: [URL], cardVolume: URL?, destination: Destination?, template: String, verify: Bool) {
        self.kind = kind; self.sourceName = sourceName; self.sourceRoots = sourceRoots; self.cardVolume = cardVolume
        self.destination = destination; self.template = template; self.verify = verify
    }

    /// Folder, do którego trafią nowe pliki: przy karcie podfolder ze wzoru, przy parze — sam cel.
    var targetFolder: URL? {
        guard let d = destination else { return nil }
        return kind == .card ? d.url.appendingPathComponent(CameraCard.folderName(template: template, cardName: sourceName)) : d.url
    }

    func replan() {
        task?.cancel()
        plan = nil; mirror = nil; result = nil; mirrorConfirmed = false
        guard let dest = destination, let target = targetFolder, let app else { stage = .failed(T("Wybierz, dokąd zgrać.")); return }
        guard dest.isAvailable else { stage = .failed(T("Cel „%@” jest niedostępny — podłącz dysk.", "\(dest.title)")); return }
        stage = .planning(ScanProgress(phase: .listing))
        let walk = app.prefs.walk(minSize: 1, log: log)
        let cache = app.prefs.useCache ? app.cache : nil
        let (roots, kind) = (sourceRoots, self.kind)
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .planning = self?.stage { self?.stage = .planning(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                if kind == .mirror {
                    let m = try Transfer.planMirror(source: roots[0], target: dest.url, walk: walk, progress: progress)
                    await MainActor.run { self?.mirror = m; self?.stage = .ready }
                } else {
                    let p = try await Transfer.planImport(sourceRoots: roots, archive: dest.url, target: target, walk: walk, cache: cache, progress: progress,
                                                         includeRootName: kind == .card)
                    await MainActor.run { self?.plan = p; self?.stage = .ready }
                }
            } catch is CancellationError {
            } catch {
                await MainActor.run { self?.stage = .failed(error.localizedDescription) }
            }
        }
    }

    /// Start kopiowania — wywoływany wyłącznie przyciskiem w oknie zgrywania (to jest Twoje potwierdzenie).
    func run() {
        let items = kind == .mirror ? (mirror?.toCopy ?? []) : (plan?.toCopy ?? [])
        let replace = mirror?.toReplace ?? []
        let extra = mirror?.toTrash.map(\.url) ?? []
        let verify = self.verify
        stage = .working(ScanProgress(phase: .copying, total: items.count))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .working = self?.stage { self?.stage = .working(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                // Lustro: stare wersje zmienionych plików najpierw do Kosza (kopiowanie nigdy nie nadpisuje).
                var trashed = 0
                for u in replace { if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { trashed += 1 } }
                let r = try Transfer.copy(items, verify: verify, progress: progress)
                for u in extra { if (try? FileManager.default.trashItem(at: u, resultingItemURL: nil)) != nil { trashed += 1 } }
                await MainActor.run {
                    self?.result = r; self?.mirrorTrashed = trashed; self?.stage = .done
                    self?.app?.finished(T("Kopiowanie: gotowe"), T("skopiowano %@", "\(Fmt.files(r.copied.count))") + (r.failed.isEmpty ? "" : T(", nieudane: %@", "\(r.failed.count)")), mode: .transfer)
                    if let d = self?.destination, let name = self?.sourceName {
                        self?.app?.drives.log(paths: [d.url], "arrow.down.doc.fill", T("Dograno %@ z „%@”", "\(Fmt.files(r.copied.count))", "\(name)") + (r.failed.isEmpty ? "" : T(", nieudane: %@", "\(r.failed.count)")))
                    }
                    self?.app?.refreshVolumes()
                    if let d = self?.destination { self?.app?.prefs.auto.lastDestinationID = d.id }
                }
            } catch is CancellationError {
                await MainActor.run { self?.stage = .failed(T("Przerwano. Skopiowane pliki zostają; niedokończony plik nie powstał.")) }
            } catch {
                await MainActor.run { self?.stage = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() { task?.cancel() }

    /// Karta jest w całości bezpieczna: wszystko skopiowane i sprawdzone, nic nie padło.
    var cardFullyBackedUp: Bool {
        guard kind == .card, let r = result else { return false }
        return r.failed.isEmpty && verify
    }
}

@MainActor
final class TransferModel: ObservableObject {
    weak var app: AppModel?
    @Published var job: TransferJob? { didSet { jobSink = job?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } } }
    @Published var card: CardCheckJob? { didSet { cardSink = card?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() } } }
    private var jobSink: AnyCancellable?
    private var cardSink: AnyCancellable?

    /// Karta (albo dowolny folder) → sprawdź, co jest już zgrane i gdzie. Tylko odczyt.
    func startCard(_ volume: URL, automatic: Bool = false) {
        guard let app else { return }
        let c = CardCheckJob(card: volume, searchRoots: app.prefs.auto.copySearchRoots(excluding: volume))
        c.app = app
        c.automatic = automatic
        card = c
        app.mode = .transfer
        c.start()
    }

    /// Zaznaczenie z Findera → „czy to już gdzieś jest (i gdzie)?”. W tle, bez przełączania okna. Szuka wszędzie poza samym zaznaczeniem.
    func startSelection(_ urls: [URL]) {
        guard let app, let first = urls.first else { return }
        // Szukaj w zwykłych miejscach + w samym zaznaczeniu (folder) i obok niego (plik) — kopia w tym samym folderze też się liczy.
        let near = urls.map { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true ? $0 : $0.deletingLastPathComponent() }
        let c = CardCheckJob(card: first, searchRoots: app.prefs.auto.copySearchRoots(excluding: nil) + near, selection: urls)
        c.app = app
        c.automatic = true
        card = c
        c.start()
    }

    func startFolder() {
        guard let src = FileActions.chooseFolder(title: T("Który folder albo kartę sprawdzić?"), prompt: T("Sprawdź")).first else { return }
        startCard(src)
    }

    func closeCard() { card?.cancel(); card = nil }

    func startPair(_ p: ComparePair, mirror: Bool) {
        guard let app else { return }
        open(TransferJob(kind: mirror ? .mirror : .pairAdd, sourceName: p.name, sourceRoots: [URL(fileURLWithPath: p.source)], cardVolume: nil,
                         destination: Destination(path: p.target), template: "", verify: app.prefs.auto.verifyCopies))
    }

    private func open(_ j: TransferJob) {
        j.app = app
        job = j
        app?.mode = .transfer
        j.replan()
    }

    func close() { job?.cancel(); job = nil }

    func eject(_ volume: URL) {
        let key = app?.volumes.first { $0.url == volume }?.key
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume); if let key { app?.drives.log(key, "eject", T("Wysunięto")) }; app?.show(T("Wysunięto „%@”.", "\(volume.lastPathComponent)")) }
        catch { app?.show(T("Nie udało się wysunąć: %@", "\(error.localizedDescription)")) }
        app?.refreshVolumes()
    }

    /// Formatowanie robi system, nie Dubel: otwieramy Narzędzie dyskowe.
    /// Najpierw ostrzeżenie: Narzędzie dyskowe po otwarciu zaznacza dysk startowy, a nie kartę.
    func openDiskUtility(for card: URL?) {
        guard let app else { return }
        if app.prefs.auto.formatWarnings, let card {
            let info = CardInfo.read(card)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = T("Uwaga: wymaż właściwy dysk")
            alert.informativeText = T("Karta, którą chcesz sformatować:\n• nazwa: %@\n• pojemność: %@\n• format: %@\n• identyfikator: %@\n\nNarzędzie dyskowe po otwarciu zaznacza zwykle dysk startowy (Macintosh HD). Zanim klikniesz „Wymaż”, wybierz po lewej „%@” i sprawdź, że pojemność to %@.\n\nNigdy nie wymazuj Macintosh HD ani dysków z archiwum. Wymazania nie da się cofnąć.",
                                      info.name, info.capacity, info.format, info.device, info.name, info.capacity)
            alert.addButton(withTitle: T("Rozumiem, otwórz"))
            alert.addButton(withTitle: T("Anuluj"))
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = T("Nie pokazuj więcej (włączysz w Ustawieniach → Zgrywanie)")
            NSApp.activate(ignoringOtherApps: true)
            let r = alert.runModal()
            if alert.suppressionButton?.state == .on { app.prefs.auto.formatWarnings = false }
            guard r == .alertFirstButtonReturn else { return }
        }
        openDiskUtility()
    }

    func openDiskUtility() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
    }
}

/// Dane karty do ostrzeżenia przed formatowaniem (nazwa, pojemność, format, identyfikator dysku z diskutil).
struct CardInfo {
    var name: String, capacity: String, format: String, device: String

    static func read(_ url: URL) -> CardInfo {
        let v = try? url.resourceValues(forKeys: [.volumeNameKey, .volumeTotalCapacityKey, .volumeLocalizedFormatDescriptionKey])
        var device = "?"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", url.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = Pipe()
        if (try? p.run()) != nil {
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                let id = plist["DeviceIdentifier"] as? String ?? "?"
                let media = plist["MediaName"] as? String
                device = media.map { "\(id) (\($0))" } ?? id
            }
        }
        return CardInfo(name: v?.volumeName ?? url.lastPathComponent,
                        capacity: v?.volumeTotalCapacity.map { Fmt.bytes(Int64($0)) } ?? "?",
                        format: v?.volumeLocalizedFormatDescription ?? "?", device: device)
    }
}
