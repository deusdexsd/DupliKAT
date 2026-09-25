import AppKit
import DubelCore
import ServiceManagement
import SwiftUI
import UserNotifications

// MARK: - Dane systemowe

@MainActor
final class SystemModel: ObservableObject {
    weak var app: AppModel?
    @Published var status: ScanStatus = .idle
    @Published var changes: [WatchChange] = []
    @Published var current: WatchSnapshot?
    @Published var previous: WatchSnapshot?
    private var task: Task<Void, Never>?

    private struct Stored: Codable { var current: WatchSnapshot?; var previous: WatchSnapshot? }

    init() {
        if let d = try? Data(contentsOf: AppPaths.watchFile), let s = try? JSONDecoder().decode(Stored.self, from: d) {
            current = s.current; previous = s.previous
            if let c = s.current { changes = SystemWatch.compare(c, previous: s.previous, spots: Hotspots.all()) }
            if s.current != nil { status = .finished(s.current!.date) }
        }
    }

    var total: Int64 { changes.reduce(0) { $0 + $1.size } }
    var totalDelta: Int64? { previous == nil ? nil : changes.reduce(0) { $0 + ($1.delta ?? 0) } }

    /// Pomiar w tle (niski priorytet — to długa operacja, u Ciebie ok. 7 min przy wszystkich miejscach).
    func measure(background: Bool = false, completion: (@MainActor ([WatchChange]) -> Void)? = nil) {
        guard !status.isRunning, let app else { return }
        let spots = Hotspots.all()
        let big = Int64(app.prefs.auto.systemWatchBigFileGB * 1_000_000_000)
        let growth = Int64(app.prefs.auto.systemWatchGrowthGB * 1_000_000_000)
        status = .running(ScanProgress(phase: .measuring, total: spots.count))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if self?.status.isRunning == true { self?.status = .running(p) } } }
        task = Task.detached(priority: background ? .background : .userInitiated) { [weak self] in
            do {
                let snap = try SystemWatch.measure(spots, bigFileThreshold: big, progress: progress)
                await MainActor.run {
                    guard let self else { return }
                    self.previous = self.current
                    self.current = snap
                    self.changes = SystemWatch.compare(snap, previous: self.previous, spots: spots)
                    self.status = .finished(snap.date)
                    self.app?.prefs.auto.lastSystemWatch = snap.date
                    try? FileManager.default.createDirectory(at: AppPaths.support, withIntermediateDirectories: true)
                    try? JSONEncoder().encode(Stored(current: self.current, previous: self.previous)).write(to: AppPaths.watchFile, options: .atomic)
                    if !background { self.app?.finished(T("Dane systemowe: zmierzone"), T("razem %@", "\(Fmt.bytes(self.total))"), mode: .system) }
                    completion?(SystemWatch.alarms(self.changes, growthThreshold: growth))
                }
            } catch {
                await MainActor.run { self?.status = .idle }
            }
        }
    }

    func cancel() { task?.cancel(); task = nil; if status.isRunning { status = .idle } }
}

// MARK: - Powiadomienia

@MainActor
enum Notifier {
    static func request() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// `mode` — który ekran otworzyć po kliknięciu w powiadomienie.
    static func send(_ title: String, _ body: String, mode: Mode? = nil, userInfo: [String: String] = [:]) {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body
        var info = userInfo
        if let mode { info["mode"] = mode.rawValue }
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

// MARK: - Reguły automatyczne

/// Wszystko, co dzieje się „samo”. Zasada: automatycznie wolno tylko CZYTAĆ i PYTAĆ.
/// Kopiowanie, Kosz, lustro — zawsze po kliknięciu w oknie, które pokazuje, co się stanie.
@MainActor
final class AutomationEngine {
    unowned let app: AppModel
    private var timer: Timer?
    private var alertedVolumes: [String: Date] = [:]

    init(app: AppModel) { self.app = app }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in
                // Chwila na zamontowanie się systemu plików (Spotlight, uprawnienia).
                try? await Task.sleep(for: .seconds(2))
                self?.volumeMounted(url)
            }
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let url = n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.volumeUnmounted(url) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in Task { @MainActor in self?.tick() } }
        Task { try? await Task.sleep(for: .seconds(20)); tick(); app.drives.rememberAllMounted() }
    }

    private var auto: Automation { app.prefs.auto }

    func volumeMounted(_ url: URL) {
        app.refreshVolumes()
        // Odśwież zapamiętaną zawartość dysku (tylko lista plików, w tle).
        if let v = app.volumes.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            app.drives.log(v.key, "cable.connector", T("Podłączono (wolne %@)", "\(Fmt.bytes(v.free))"))
            app.drives.remember(v, force: true)
        }
        let name = url.lastPathComponent
        // 1. Karta z aparatu → „co jest zgrane i gdzie” (tylko odczyt; kopiujesz/przenosisz sam).
        if auto.cardImportEnabled, CameraCard.isCard(url) {
            app.transfer.startCard(url, automatic: true)
            app.showMainWindow?()
            return
        }
        // Karta bez włączonej reguły: tylko powiadomienie z pytaniem (kliknięcie = sprawdź).
        if CameraCard.isCard(url) {
            Notifier.send(T("Podłączono kartę „%@”", "\(name)"), T("Kliknij, żeby sprawdzić, co z niej jest już zgrane i gdzie."), userInfo: ["checkCard": url.path])
            if let c = app.transfer.card, c.ejected, c.card.lastPathComponent == name { app.transfer.closeCard() }
            return
        }
        // 2. Sprawdź duplikaty na tym dysku (tylko odczyt).
        if auto.checkVolumesOnMount.contains(name), !app.duplicates.status.isRunning {
            app.duplicates.roots = [url]
            app.duplicates.onFinish = { [weak self] in
                guard let self else { return }
                let g = self.app.duplicates.groups
                Notifier.send(T("Dysk „%@” sprawdzony", "\(name)"),
                              g.isEmpty ? T("Brak duplikatów.") : T("%@ duplikatów, do odzyskania %@. Nic nie zostało usunięte.", "\(Fmt.groups(g.count))", "\(Fmt.bytes(self.app.duplicates.reclaimable))"),
                              mode: .duplicates)
            }
            app.duplicates.start()
        }
        // 3. Stałe pary, które teraz są dostępne.
        for p in auto.pairs where p.runOnMount && p.isAvailable && (p.source.hasPrefix(url.path + "/") || p.target.hasPrefix(url.path + "/") || p.source == url.path || p.target == url.path) {
            runPairCompare(p, notify: true)
            break // jedno porównanie naraz; reszta z menu
        }
    }

    /// Karta wysunięta: widok zostaje jako ostatni stan z banerem „wysunięto”.
    func volumeUnmounted(_ url: URL) {
        app.refreshVolumes()
        if let c = app.transfer.card, c.card.standardizedFileURL.path == url.standardizedFileURL.path || c.card.path.hasPrefix(url.path + "/") {
            c.cancel()
            c.ejected = true
            if case .checking = c.stage { c.stage = .failed(T("Karta została wysunięta w trakcie sprawdzania.")) }
            Notifier.send(T("Wysunięto „%@”", "\(url.lastPathComponent)"), T("Widok karty zostaje jako ostatni stan — zamkniesz go przyciskiem „Zamknij”."), mode: .transfer)
        }
    }

    func runPairCompare(_ p: ComparePair, notify: Bool) {
        guard !app.backup.status.isRunning else { return }
        app.backup.sources = [URL(fileURLWithPath: p.source)]
        app.backup.backups = [URL(fileURLWithPath: p.target)]
        if notify {
            app.backup.onFinish = { [weak self] in
                guard let r = self?.app.backup.report else { return }
                Notifier.send(T("„%@” porównane", "\(p.name)"),
                              r.missing.isEmpty ? T("Wszystko jest w archiwum (%@).", "\(Fmt.files(r.backedUp.count))") : T("Brakuje w archiwum: %@ (%@).", "\(Fmt.files(r.missing.count))", "\(Fmt.bytes(r.missing.reduce(0) { $0 + $1.file.size }))"),
                              mode: .backup)
            }
        } else { app.mode = .backup }
        app.backup.start()
    }

    func tick() {
        app.refreshVolumes()
        if auto.spaceAlarmEnabled { checkSpace() }
        if auto.weeklyReportEnabled, Date().timeIntervalSince(auto.lastWeeklyReport ?? .distantPast) > 7 * 86_400 { weeklyReport() }
        if auto.systemWatchEnabled, Date().timeIntervalSince(auto.lastSystemWatch ?? .distantPast) > auto.systemWatchIntervalHours * 3600 {
            app.system.measure(background: true) { alarms in
                guard !alarms.isEmpty else { return }
                let top = alarms.prefix(3).map { a in
                    let grew = (a.delta ?? 0) > 0 ? "+\(Fmt.bytes(a.delta ?? 0))" : ""
                    return "\(a.spot.title) \(grew)" + (a.newBigFiles.isEmpty ? "" : T(" (nowy duży plik)"))
                }.joined(separator: ", ")
                Notifier.send(T("Coś nagle zajmuje miejsce"), top, mode: .system)
            }
        }
    }

    private func checkSpace() {
        for v in app.volumes where v.used * 100 >= auto.spaceAlarmPercent {
            if let last = alertedVolumes[v.id], Date().timeIntervalSince(last) < 86_400 { continue }
            alertedVolumes[v.id] = Date()
            var hint = T("Sprawdź duplikaty i pliki Final Cut.")
            if v.url.path == "/", app.fcp.total > 5_000_000_000 { hint = T("Same pliki generowane FCP to %@.", "\(Fmt.bytes(app.fcp.total))") }
            Notifier.send(T("Dysk „%@” zajęty w %@", "\(v.name)", "\(Fmt.percent(v.used))"), T("Wolne: %@.", "\(Fmt.bytes(v.free))") + " \(hint)", mode: v.url.path == "/" ? .fcp : .duplicates)
        }
    }

    private func weeklyReport() {
        app.prefs.auto.lastWeeklyReport = Date()
        app.fcp.onFinish = { [weak self] in
            guard let self else { return }
            let vols = self.app.volumes.map { T("%@: wolne %@", "\($0.name)", "\(Fmt.bytes($0.free))") }.joined(separator: " · ")
            Notifier.send(T("Tygodniowy przegląd dysków"), T("Pliki generowane FCP: %@. %@", "\(Fmt.bytes(self.app.fcp.total))", "\(vols)"), mode: .fcp)
        }
        app.fcp.start()
    }

    // MARK: Start z systemem, Dock

    static func applyLoginItem(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } } catch { NSLog("Dubel: login item \(error)") }
    }
}
