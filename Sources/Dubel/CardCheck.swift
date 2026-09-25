import AppKit
import Combine
import DubelCore
import MidniteUIKit
import QuickLook
import SwiftUI

/// Karta podłączona → „co z niej jest już zgrane i gdzie, a czego nie ma nigdzie”.
/// Tylko czyta. Kopiowanie/przenoszenie zaznaczonych plików dopiero po Twoim wyborze folderu i potwierdzeniu.
@MainActor
final class CardCheckJob: ObservableObject, Identifiable {
    enum Stage: Equatable { case checking(ScanProgress), ready, working(ScanProgress), failed(String) }

    let id = UUID()
    let card: URL
    let sourceRoots: [URL]
    let searchRoots: [URL]
    @Published var stage: Stage = .checking(ScanProgress(phase: .listing))
    @Published var report: BackupChecker.Report?
    @Published var checked: Set<String> = []
    @Published var lastResult: String?
    let log = ScanLog()
    weak var app: AppModel?
    private var task: Task<Void, Never>?

    /// Zaznaczenie z Findera (pliki i foldery): „czy to już gdzieś jest?” — bez reguł karty (bez automatycznego kopiowania).
    let isSelection: Bool
    private let title: String?

    init(card: URL, searchRoots: [URL], selection: [URL]? = nil) {
        self.card = card
        self.isSelection = selection != nil
        if let selection {
            self.sourceRoots = selection
            self.title = selection.count == 1 ? selection[0].lastPathComponent : T("%@ zaznaczone", "\(selection.count)")
        } else {
            self.sourceRoots = CameraCard.isCard(card) ? CameraCard.mediaRoots(card) : [card]
            self.title = nil
        }
        self.searchRoots = searchRoots
    }

    /// Czy ostatnie sprawdzenie było bajt po bajcie (wpływa na pytanie o formatowanie).
    @Published var exact = false

    var isBusy: Bool { switch stage { case .checking, .working: return true; default: return false } }
    var cardName: String { title ?? card.lastPathComponent }
    var isRealCard: Bool { !isSelection && card.path.hasPrefix("/Volumes/") && card.pathComponents.count == 3 }

    /// Pliki z karty już zgrane, pogrupowane według folderu, w którym leży kopia („M ▸ BACKUP KART/karta 3”: 120 plików).
    var backedUpByFolder: [(folder: String, count: Int, size: Int64)] {
        guard let r = report else { return [] }
        var m: [String: (Int, Int64)] = [:]
        for e in r.backedUp {
            guard let u = e.allCopies.first else { continue }
            let f = u.deletingLastPathComponent().path
            m[f, default: (0, 0)].0 += 1
            m[f, default: (0, 0)].1 += e.file.size
        }
        return m.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.count > $1.count }
    }

    /// Bez kopii + niepewne (to, co ewentualnie zabrać z karty).
    var missing: [BackupChecker.Entry] { (report?.missing ?? []) + (report?.differs ?? []) }
    var selected: [BackupChecker.Entry] { missing.filter { checked.contains($0.id) } }
    var selectedBacked: [BackupChecker.Entry] { (report?.backedUp ?? []).filter { checked.contains($0.id) } }
    /// Karta została wysunięta — widok zostaje jako ostatni stan, akcje są wyłączone.
    @Published var ejected = false

    /// Co znaczy „ta sama nazwa, inna treść” dla konkretnego pliku — na podstawie rozmiaru i daty obu plików.
    func differsNote(_ e: BackupChecker.Entry) -> (text: String, other: URL)? {
        guard case .differs(let us) = e.status, let u = us.first else { return nil }
        guard let o = ScannedFile.stat(u) else { return (T("W archiwum jest plik o tej nazwie, ale nie da się go teraz odczytać."), u) }
        let mine = e.file
        let sizes = T("karta %@ · archiwum %@", "\(Fmt.bytes(mine.size))", "\(Fmt.bytes(o.size))")
        let days = abs(mine.modified.timeIntervalSince(o.modified)) / 86_400
        if o.size < mine.size {
            return (T("Kopia w archiwum jest MNIEJSZA (%@) — najpewniej niepełna, np. przerwane kopiowanie. Warto skopiować jeszcze raz.", "\(sizes)"), u)
        }
        if days > 1 {
            return (T("Inna data nagrania (%@ vs %@) — to raczej inne nagranie o tym samym numerze (aparat numeruje od nowa). %@.", "\(Fmt.date.string(from: mine.modified))", "\(Fmt.date.string(from: o.modified))", "\(sizes)"), u)
        }
        if o.size > mine.size {
            return (T("W archiwum plik jest WIĘKSZY (%@) — to raczej inny plik (inne nagranie albo po edycji), nie kopia tego z karty.", "\(sizes)"), u)
        }
        return (T("Ten sam rozmiar i data, ale inna zawartość — któraś kopia może być uszkodzona. Obejrzyj oba pliki."), u)
    }

    /// Przenieś do Kosza z karty pliki, które mają kopię (po Twoim potwierdzeniu).
    func trashBacked() {
        guard let app else { return }
        let entries = selectedBacked
        app.confirm(PendingAction(
            title: T("Usunąć z karty %@, które mają kopię?", "\(Fmt.files(entries.count))"), verb: T("Przenoszę do Kosza"),
            items: entries.map { e in
                if let t = CopyText.describe(e, app.drives) { return (e.file.name, t, e.file.size) }
                return (e.file.name, Fmt.path(e.file.folder), e.file.size)
            },
            notes: [exact ? T("Każdy z tych plików ma identyczną kopię (sprawdzone bajt po bajcie).") : T("Kopie sprawdzone szybko (rozmiar + fragmenty). Dla pewności możesz najpierw sprawdzić bajt po bajcie."),
                    T("Pliki trafią do Kosza na karcie — miejsce zwolni się po jego opróżnieniu albo sformatowaniu karty.")],
            perform: { [weak self] in
                let o = await FileActions.trash(entries.map(\.file.url))
                self?.checked = []
                self?.start()
                return o
            }))
    }

    func start() {
        guard let app else { return }
        task?.cancel()
        stage = .checking(ScanProgress(phase: .listing))
        let a = app.prefs.auto
        var walk = app.prefs.walk(minSize: max(1, Int64(a.cardMinSizeMB * 1_000_000)), log: log)
        if isSelection {
            // Zaznaczenie z Findera: każdy rodzaj pliku, próg wielkości jak przy duplikatach (ale nie większy niż najmniejszy zaznaczony plik).
            let smallest = sourceRoots.compactMap { ScannedFile.stat($0)?.size }.min()
            walk = app.prefs.walk(minSize: max(1, min(Int64(app.prefs.minSizeMB * 1_000_000), smallest ?? .max)), log: log)
        } else {
            walk.recursive = true // karta ma pliki w DCIM/100MSDCF… — zawsze całość
            if a.cardMediaOnly && !checkAll { walk.kinds = [.video, .audio, .image]; walk.skipFolderNames = CameraCard.helperFolders }
        }
        let mediaOnly = !isSelection && a.cardMediaOnly && !checkAll
        var restWalk = walk
        restWalk.kinds = [.project, .other]; restWalk.skipFolderNames = []
        exact = a.cardExact
        var checker = BackupChecker(walk: walk, verifyFullContent: a.cardExact, cache: app.prefs.useCache ? app.cache : nil)
        checker.skipSourcesInsideBackups = !isSelection
        checker.offline = app.drives.offlineIndexes(searchRoots: searchRoots)
        let (src, dst) = (sourceRoots, searchRoots)
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .checking = self?.stage { self?.stage = .checking(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await checker.run(sources: src, backups: dst, progress: progress)
                // Ile innych plików (XML, baza aparatu, miniatury…) zostało pominiętych — tylko lista, bez czytania treści.
                let rest = mediaOnly ? ((try? FileWalker.files(in: src, options: restWalk)) ?? []) : []
                await MainActor.run {
                    guard let self else { return }
                    let firstCheck = self.report == nil
                    self.report = r
                    self.skippedOthers = rest.isEmpty ? nil : (rest.count, rest.reduce(0) { $0 + $1.size })
                    self.checked = self.checked.intersection(Set(self.missing.map(\.id)))
                    self.stage = .ready
                    if firstCheck {
                        self.app?.finished(self.isSelection ? T("Sprawdzone: %@", "\(self.cardName)") : T("Karta „%@” sprawdzona", "\(self.cardName)"),
                                           T("z kopią %@, bez kopii %@", "\(r.backedUp.count)", "\(self.missing.count)"), mode: .transfer, notify: !self.automatic)
                        self.app?.drives.log(paths: self.isSelection ? [] : [self.card], "sdcard.fill",
                                             T("Sprawdzono: zgrane %@, nie ma nigdzie %@", "\(r.backedUp.count)", "\(self.missing.count)"))
                        self.afterAutomaticCheck()
                    }
                }
            } catch is CancellationError {
            } catch { await MainActor.run { self?.stage = .failed(error.localizedDescription) } }
        }
    }

    func cancel() { task?.cancel() }

    /// Sprawdzono tylko zdjęcia/wideo/audio — ile innych plików zostało na karcie (liczba, bajty). nil = nic nie pominięto.
    @Published var skippedOthers: (count: Int, size: Int64)?
    /// Po „sprawdź też resztę” kolejne odświeżenia obejmują wszystkie pliki.
    private(set) var checkAll = false

    /// Dosprawdź pominięte pliki (bez ponownego sprawdzania zdjęć/wideo/audio) i dołącz je do wyniku.
    func checkRest() {
        guard let app, let old = report else { return }
        checkAll = true
        skippedOthers = nil
        stage = .checking(ScanProgress(phase: .listing))
        var walk = app.prefs.walk(minSize: max(1, Int64(app.prefs.auto.cardMinSizeMB * 1_000_000)), log: log)
        walk.recursive = true
        walk.kinds = [.project, .other]
        var checker = BackupChecker(walk: walk, verifyFullContent: exact, cache: app.prefs.useCache ? app.cache : nil)
        checker.offline = app.drives.offlineIndexes(searchRoots: searchRoots)
        let (src, dst) = (sourceRoots, searchRoots)
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .checking = self?.stage { self?.stage = .checking(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await checker.run(sources: src, backups: dst, progress: progress)
                await MainActor.run {
                    guard let self else { return }
                    let known = Set(old.entries.map(\.id))
                    self.report = BackupChecker.Report(entries: old.entries + r.entries.filter { !known.contains($0.id) })
                    self.stage = .ready
                }
            } catch is CancellationError {
            } catch { await MainActor.run { self?.stage = .failed(error.localizedDescription) } }
        }
    }

    /// Uruchomione przez regułę „karta podłączona” — wtedy po sprawdzeniu działa ustawienie „co dalej”.
    var automatic = false

    /// Po automatycznym sprawdzeniu: pokaż / zapytaj o kopię do stałego folderu / kopiuj od razu.
    func afterAutomaticCheck() {
        guard automatic, let app, let r = report else { return }
        let missing = self.missing
        if isSelection {
            Notifier.send(T("Sprawdzone: %@", "\(cardName)"),
                          missing.isEmpty ? T("Wszystko (%@) ma już kopię gdzie indziej.", "\(Fmt.files(r.backedUp.count))") : T("Ma kopię: %@. Bez kopii: %@.", "\(r.backedUp.count)", "\(Fmt.files(missing.count))"),
                          mode: .transfer)
            return
        }
        Notifier.send(T("Karta „%@” sprawdzona", "\(cardName)"),
                      missing.isEmpty ? T("Wszystko (%@) ma już kopię.", "\(Fmt.files(r.backedUp.count))") : T("Zgrane: %@. Nie ma nigdzie: %@ (%@).", "\(r.backedUp.count)", "\(Fmt.files(missing.count))", "\(Fmt.bytes(missing.reduce(0) { $0 + $1.file.size }))"),
                      mode: .transfer)
        guard !missing.isEmpty, let folder = app.prefs.auto.cardAutoFolder, FileManager.default.fileExists(atPath: folder) else { return }
        switch app.prefs.auto.cardAfterCheck {
        case "ask":
            checked = Set(missing.map(\.id))
            transfer(move: false, to: URL(fileURLWithPath: folder))
        case "auto":
            checked = Set(missing.map(\.id))
            transfer(move: false, to: URL(fileURLWithPath: folder), confirm: false)
        default: break
        }
    }

    /// Skopiuj albo przenieś zaznaczone. Folder wybierasz Ty (albo stały folder z reguły automatycznej);
    /// przy „przenieś” oryginały idą do Kosza karty DOPIERO po sprawdzonej kopii.
    func transfer(move: Bool, to fixed: URL? = nil, confirm: Bool = true) {
        guard let app else { return }
        let dest: URL
        if let fixed { dest = fixed } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            panel.message = move ? T("Dokąd przenieść zaznaczone pliki z karty?") : T("Dokąd skopiować zaznaczone pliki z karty?")
            panel.prompt = move ? T("Przenieś tutaj") : T("Kopiuj tutaj")
            if let last = app.prefs.auto.lastCopyFolder { panel.directoryURL = URL(fileURLWithPath: last) }
            guard panel.runModal() == .OK, let picked = panel.url else { return }
            dest = picked
            app.prefs.auto.lastCopyFolder = dest.path
        }
        let keep = app.prefs.auto.keepCardFolders
        let roots = sourceRoots.map { FileWalker.canonical($0.path) }
        let base = keep ? dest.appendingPathComponent(cardName) : dest
        let items = selected.map { e -> TransferItem in
            let rel = keep ? Transfer.relative(e.file.url, roots: roots) : e.file.name
            return TransferItem(source: e.file.url, target: base.appendingPathComponent(rel), size: e.file.size)
        }
        let verify = app.prefs.auto.verifyCopies || move || !confirm // przenoszenie i automat zawsze z weryfikacją
        if !confirm {
            // Reguła „kopiuj automatycznie”: tylko kopiowanie brakujących, bez usuwania i nadpisywania — więc bez okna potwierdzenia.
            app.working = T("Kopiuję brakujące z karty…")
            Task {
                let o = await run(items, verify: verify, move: false)
                app.working = nil
                app.show(o.summary + " → " + Fmt.path(base.path))
                Notifier.send(T("Karta „%@”: skopiowano brakujące", "\(cardName)"), o.summary + " → " + Fmt.path(base.path), mode: .transfer)
            }
            return
        }
        app.confirm(PendingAction(
            title: move ? T("Przenieść %@ z karty?", "\(Fmt.files(items.count))") : T("Skopiować %@ z karty?", "\(Fmt.files(items.count))"),
            verb: move ? T("Przenoszę") : T("Kopiuję"), style: move ? .destructive : .normal,
            items: items.map { ($0.source.lastPathComponent, "→ " + Fmt.path($0.target.deletingLastPathComponent().path), $0.size) },
            notes: [keep ? T("Do: %@ (z zachowaniem folderów karty)", "\(Fmt.path(base.path))") : "Do: \(Fmt.path(dest.path))",
                    T("Nic w celu nie jest nadpisywane — jeśli plik o tej nazwie już tam jest, zostanie pominięty."),
                    verify ? T("Każda kopia zostanie sprawdzona bajt po bajcie.") : T("Kopie nie będą sprawdzane (wyłączone w Ustawieniach).")]
                + (move ? [T("Oryginał trafi do Kosza na karcie dopiero wtedy, gdy kopia przejdzie sprawdzenie. Miejsce na karcie zwolni się po opróżnieniu Kosza albo sformatowaniu.")] : []),
            perform: { [weak self] in await self?.run(items, verify: verify, move: move) ?? FileActions.Outcome(summary: "") }))
    }

    private func run(_ items: [TransferItem], verify: Bool, move: Bool) async -> FileActions.Outcome {
        stage = .working(ScanProgress(phase: .copying, total: items.count))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .working = self?.stage { self?.stage = .working(p) } } }
        let result: Transfer.Result? = await Task.detached { try? Transfer.copy(items, verify: verify, progress: progress) }.value
        var o = FileActions.Outcome(summary: "")
        guard let r = result else { stage = .ready; o.summary = T("Przerwano."); return o }
        o.done = r.copied.map(\.source)
        o.failed = r.failed.map { ($0.0.source, $0.1) } + r.skippedExisting.map { ($0.source, T("w celu jest już plik o tej nazwie — pominięty")) }
        var trashed = 0
        if move {
            for it in r.copied { if (try? FileManager.default.trashItem(at: it.source, resultingItemURL: nil)) != nil { trashed += 1 } }
        }
        o.summary = (move ? T("Przeniesiono: %@", "\(trashed)") : T("Skopiowano: %@", "\(r.copied.count)")) + (verify ? T(" (sprawdzone)") : "")
            + (o.failed.isEmpty ? "" : T(", pominięto: %@", "\(o.failed.count)"))
        lastResult = o.summary
        checked = []
        start() // odśwież stan karty (tylko odczyt), żeby było widać, co jeszcze zostało
        return o
    }
}

// MARK: - Widok

struct CardCheckPanel: View {
    @ObservedObject var job: CardCheckJob
    @ObservedObject var model: TransferModel
    @EnvironmentObject var prefs: Prefs
    @State private var preview: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconCircle(symbol: "sdcard.fill", color: FeatureColor.card, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Karta „%@”", "\(job.cardName)")).font(.system(size: 15, weight: .semibold))
                    Text(T("Szukam kopii w: ") + job.searchRoots.map { Fmt.path($0.path) }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(job.searchRoots.map(\.path).joined(separator: "\n"))
                    CardScanOptions(onChange: { job.start() }, disabled: job.isBusy)
                }
                Spacer()
                if !job.isBusy { Button { model.closeCard() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel(T("Zamknij")).help(T("Zamknij")) }
            }
            switch job.stage {
            case .checking(let p): ProgressCard(progress: p, log: job.log) { job.cancel(); model.closeCard() }
            case .working(let p): ProgressCard(progress: p) { }
            case .failed(let m): Label(m, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warn).font(.system(size: 12))
            case .ready: results
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(FeatureColor.card.opacity(0.35), lineWidth: 1.5))
    }

    enum Tab: Hashable { case missing, unsure, backed }
    @State private var tab: Tab = .missing

    @ViewBuilder var results: some View {
        if let r = job.report {
            VStack(alignment: .leading, spacing: 12) {
                if job.ejected {
                    HStack(spacing: 10) {
                        Image(systemName: "eject.circle.fill").font(.system(size: 18)).foregroundStyle(Theme.warn)
                        Text(T("Karta „%@” została wysunięta — to ostatni widok z jej sprawdzenia.", "\(job.cardName)")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button(T("Zamknij")) { model.closeCard() }.controlSize(.small)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warn.opacity(0.1)))
                }
                HStack(spacing: 22) {
                    StatBadge(value: "\(r.backedUp.count)", label: T("zgrane · %@", "\(Fmt.bytes(r.backedUp.reduce(0) { $0 + $1.file.size }))"), color: Theme.safe)
                    StatBadge(value: "\(r.missing.count)", label: T("nie ma nigdzie · %@", "\(Fmt.bytes(r.missing.reduce(0) { $0 + $1.file.size }))"), color: Theme.missing)
                    if !r.differs.isEmpty { StatBadge(value: "\(r.differs.count)", label: T("niepewne — do sprawdzenia"), color: Theme.warn) }
                }
                if let last = job.lastResult { Label(last, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.safe) }
                if !r.backedUp.isEmpty { copyLevels(r) }

                if !job.backedUpByFolder.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Caption(T("Już zgrane — tutaj"))
                        ForEach(job.backedUpByFolder.prefix(6), id: \.folder) { f in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe).font(.system(size: 11))
                                Text(Fmt.path(f.folder)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.files(f.count)) · \(Fmt.bytes(f.size))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: f.folder)) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help(T("Otwórz folder"))
                            }
                        }
                        if job.backedUpByFolder.count > 6 { Text(T("…i %@ innych folderów", "\(job.backedUpByFolder.count - 6)")).font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                }

                if let rest = job.skippedOthers, !job.ejected {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(T("Sprawdziłem tylko zdjęcia, wideo i audio.")).font(.system(size: 12, weight: .semibold))
                            Text(T("Pozostałe pliki na karcie: %@ (%@) — XML, baza aparatu, miniatury itp. Tych nie sprawdzałem.", "\(Fmt.files(rest.count))", "\(Fmt.bytes(rest.size))"))
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Button(T("Sprawdź też je")) { job.checkRest() }.controlSize(.small)
                            .help(T("Zdjęcia, wideo i audio zostają z wyniku — sprawdzam tylko pozostałe pliki"))
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.blue.opacity(0.08)))
                }

                if r.missing.isEmpty && r.differs.isEmpty && !job.ejected {
                    Label(job.skippedOthers == nil ? T("Wszystko z tej karty ma już kopię.") : T("Wszystkie zdjęcia, wideo i audio z tej karty mają już kopię."), systemImage: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.safe)
                }

                // Lista plików w trzech grupach + zaznaczanie całych grup.
                HStack(spacing: 10) {
                    PillTabs(items: [(Tab.missing, T("Nie ma nigdzie (%@)", "\(r.missing.count)"), "xmark.circle"),
                                     (.unsure, T("Niepewne (%@)", "\(r.differs.count)"), "exclamationmark.circle"),
                                     (.backed, T("Zgrane (%@)", "\(r.backedUp.count)"), "checkmark.circle")],
                             selection: $tab, fontSize: 11)
                        .frame(maxWidth: 520)
                    Spacer()
                    Menu {
                        Button(T("Zaznacz wszystkie bez kopii (do przeniesienia)")) { job.checked.formUnion(r.missing.map(\.id)); tab = .missing }
                        Button(T("Zaznacz niepewne (do sprawdzenia)")) { job.checked.formUnion(r.differs.map(\.id)); tab = .unsure }
                        Button(T("Zaznacz zgrane (mają kopię — np. do usunięcia z karty)")) { job.checked.formUnion(r.backedUp.map(\.id)); tab = .backed }
                        Divider()
                        Button(T("Odznacz wszystko")) { job.checked = [] }
                    } label: { Label(T("Zaznacz"), systemImage: "checklist") }
                        .fixedSize().controlSize(.small)
                }
                let list: [BackupChecker.Entry] = tab == .missing ? r.missing : tab == .unsure ? r.differs : r.backedUp
                if list.isEmpty {
                    Text(tab == .missing ? T("Każdy plik z karty jest już gdzieś zgrany.") : tab == .unsure ? T("Brak niepewnych plików.") : T("Nic z tej karty nie jest jeszcze zgrane."))
                        .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 6)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) { ForEach(list) { e in row(e) } }
                    }
                    .frame(maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
                    .quickLookPreview($preview, in: list.map(\.file.url))
                }
                actions
                if r.missing.isEmpty && r.differs.isEmpty && !job.ejected { formatOffer }
            }
            .disabled(job.ejected && false)
        }
    }

    @ViewBuilder var actions: some View {
        let sel = job.selected, backed = job.selectedBacked
        HStack(spacing: 10) {
            Toggle(T("Zachowaj foldery z karty"), isOn: $prefs.auto.keepCardFolders).toggleStyle(.checkbox).font(.system(size: 11.5))
                .help(T("Tworzy w wybranym miejscu folder z nazwą karty i jej strukturą (DCIM/…). Wyłączone: wszystkie pliki trafiają prosto do wybranego folderu."))
            Spacer()
            let all = sel.count + backed.count
            Text(all == 0 ? T("Nic nie zaznaczono") : T("Zaznaczono %@ · %@", "\(Fmt.files(all))", "\(Fmt.bytes((sel + backed).reduce(0) { $0 + $1.file.size }))"))
                .font(.system(size: 12, weight: .medium)).foregroundStyle(all == 0 ? .secondary : .primary).monospacedDigit()
            if !backed.isEmpty {
                Button { job.trashBacked() } label: { Label(T("Usuń z karty (%@)…", "\(backed.count)"), systemImage: "trash") }
                    .help(T("Tylko pliki, które mają kopię. Trafią do Kosza na karcie."))
            }
            Button { job.transfer(move: false) } label: { Label(T("Skopiuj do…"), systemImage: "doc.on.doc") }.disabled(sel.isEmpty)
            Button { job.transfer(move: true) } label: { Label(T("Przenieś do…"), systemImage: "arrow.right.doc.on.clipboard") }
                .buttonStyle(GradientButtonStyle()).disabled(sel.isEmpty).opacity(sel.isEmpty ? 0.5 : 1)
                .help(T("Kopiuje, sprawdza kopię i dopiero wtedy przenosi oryginał z karty do Kosza."))
        }
        .controlSize(.small)
        .disabled(job.ejected)
    }

    func row(_ e: BackupChecker.Entry) -> some View {
        let on = job.checked.contains(e.id)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { on }, set: { v in if v { job.checked.insert(e.id) } else { job.checked.remove(e.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Thumbnail(url: e.file.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.file.name).font(.system(size: 12, weight: .medium))
                if let note = job.differsNote(e) {
                    Text(T("W %@ jest plik o tej nazwie. %@", "\(Fmt.path(note.other.deletingLastPathComponent().path))", "\(note.text)"))
                        .font(.system(size: 10.5)).foregroundStyle(Theme.warn).fixedSize(horizontal: false, vertical: true)
                    Button(T("Pokaż oba w Finderze")) { FileActions.reveal([e.file.url, note.other]) }.buttonStyle(.borderless).font(.system(size: 10.5))
                } else if let t = CopyText.describe(e, model.app?.drives) {
                    Text(t).font(.system(size: 10.5)).foregroundStyle(e.onlyOffline ? Theme.warn : Theme.safe).lineLimit(1).truncationMode(.middle)
                } else if let a = model.app?.drives.awaitingNote(for: e.file) {
                    Text(a).font(.system(size: 10.5)).foregroundStyle(Theme.warn).lineLimit(1).truncationMode(.middle)
                } else {
                    Text(Fmt.path(e.file.folder)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.date.string(from: e.file.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Fmt.bytes(e.file.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { preview = e.file.url } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help(T("Podgląd"))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if on { job.checked.remove(e.id) } else { job.checked.insert(e.id) } }
    }

    /// Wszystko ma kopię → pytanie o format. DupliKAT nie formatuje — otwiera systemowe Narzędzie dyskowe.
    /// Ile plików ma kopię na dwóch dyskach (np. M + M2), a ile tylko na jednym — „zgrane” nie zawsze znaczy „bezpieczne”.
    func copyLevels(_ r: BackupChecker.Report) -> some View {
        let two = r.backedUp.filter { $0.copyDrives.count >= 2 }
        let one = r.backedUp.filter { $0.copyDrives.count < 2 }
        let offlineOnly = r.backedUp.filter(\.onlyOffline).count
        return HStack(spacing: 14) {
            Label(T("na 2+ dyskach: %@", "\(two.count)"), systemImage: "checkmark.shield.fill").foregroundStyle(two.isEmpty ? Color.secondary : Theme.safe)
            Label(T("tylko na jednym dysku: %@", "\(one.count)"), systemImage: "shield.lefthalf.filled").foregroundStyle(one.isEmpty ? Color.secondary : Theme.warn)
            if offlineOnly > 0 {
                Label(T("w tym tylko na odłączonym: %@ (po nazwie i rozmiarze)", "\(offlineOnly)"), systemImage: "externaldrive.badge.xmark").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11.5, weight: .medium))
        .help(T("Kopia na jednym dysku to wciąż jedna kopia. Na 2+ dyskach (np. M i M2) jesteś bezpieczny, gdy jeden padnie."))
    }

    @ViewBuilder var formatOffer: some View {
        if prefs.auto.askFormatAfterImport, job.isRealCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(T("Sformatować kartę?")).font(.system(size: 12.5, weight: .semibold))
                if !job.exact || prefs.auto.cardMediaOnly || prefs.auto.cardMinSizeMB > 0 {
                    Label(T("Porównanie było szybkie%@%@. Przed formatowaniem możesz sprawdzić dokładnie: włącz „Bajt po bajcie” powyżej.", "\(prefs.auto.cardMediaOnly ? T(" i tylko dla zdjęć, wideo i audio") : "")", "\(prefs.auto.cardMinSizeMB > 0 ? T(", bez małych plików") : "")"), systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text(T("Najzdrowiej dla karty jest sformatować ją w aparacie. Na Macu: otworzę Narzędzie dyskowe — wybierz po lewej „%@”, kliknij Wymaż, format ExFAT. %@ sam nigdy nie formatuje.", "\(job.cardName)", "\(AppInfo.name)"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.openDiskUtility(for: job.card) } label: { Label(T("Otwórz Narzędzie dyskowe"), systemImage: "internaldrive") }
                    Button { model.eject(job.card); model.closeCard() } label: { Label(T("Wysuń (sformatuję w aparacie)"), systemImage: "eject") }
                    Spacer()
                    Button(T("Nie teraz")) { model.closeCard() }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.safe.opacity(0.08)))
        }
    }
}
