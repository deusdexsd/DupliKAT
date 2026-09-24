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
        guard let dest = destination, let target = targetFolder, let app else { stage = .failed("Wybierz, dokąd zgrać."); return }
        guard dest.isAvailable else { stage = .failed("Cel „\(dest.title)” jest niedostępny — podłącz dysk."); return }
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
                    self?.app?.refreshVolumes()
                    if let d = self?.destination { self?.app?.prefs.auto.lastDestinationID = d.id }
                }
            } catch is CancellationError {
                await MainActor.run { self?.stage = .failed("Przerwano. Skopiowane pliki zostają; niedokończony plik nie powstał.") }
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

    func startFolder() {
        guard let src = FileActions.chooseFolder(title: "Który folder albo kartę sprawdzić?", prompt: "Sprawdź").first else { return }
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
        do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume); app?.show("Wysunięto „\(volume.lastPathComponent)”.") }
        catch { app?.show("Nie udało się wysunąć: \(error.localizedDescription)") }
        app?.refreshVolumes()
    }

    /// Formatowanie robi system, nie Dubel: otwieramy Narzędzie dyskowe.
    func openDiskUtility() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
    }
}
