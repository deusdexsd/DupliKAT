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

    init(card: URL, searchRoots: [URL]) {
        self.card = card
        self.sourceRoots = CameraCard.isCard(card) ? CameraCard.mediaRoots(card) : [card]
        self.searchRoots = searchRoots
    }

    /// Czy ostatnie sprawdzenie było bajt po bajcie (wpływa na pytanie o formatowanie).
    @Published var exact = false

    var isBusy: Bool { switch stage { case .checking, .working: return true; default: return false } }
    var cardName: String { card.lastPathComponent }
    var isRealCard: Bool { card.path.hasPrefix("/Volumes/") && card.pathComponents.count == 3 }

    /// Pliki z karty już zgrane, pogrupowane według folderu, w którym leży kopia („M ▸ BACKUP KART/karta 3”: 120 plików).
    var backedUpByFolder: [(folder: String, count: Int, size: Int64)] {
        guard let r = report else { return [] }
        var m: [String: (Int, Int64)] = [:]
        for e in r.backedUp {
            guard case .backedUp(let urls) = e.status, let u = urls.first else { continue }
            let f = u.deletingLastPathComponent().path
            m[f, default: (0, 0)].0 += 1
            m[f, default: (0, 0)].1 += e.file.size
        }
        return m.map { ($0.key, $0.value.0, $0.value.1) }.sorted { $0.count > $1.count }
    }

    var missing: [BackupChecker.Entry] { (report?.missing ?? []) + (report?.differs ?? []) }
    var selected: [BackupChecker.Entry] { missing.filter { checked.contains($0.id) } }

    func start() {
        guard let app else { return }
        task?.cancel()
        stage = .checking(ScanProgress(phase: .listing))
        let a = app.prefs.auto
        var walk = app.prefs.walk(minSize: max(1, Int64(a.cardMinSizeMB * 1_000_000)), log: log)
        if a.cardMediaOnly { walk.kinds = [.video, .audio, .image]; walk.skipFolderNames = CameraCard.helperFolders }
        exact = a.cardExact
        let checker = BackupChecker(walk: walk, verifyFullContent: a.cardExact, cache: app.prefs.useCache ? app.cache : nil)
        let (src, dst) = (sourceRoots, searchRoots)
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .checking = self?.stage { self?.stage = .checking(p) } } }
        task = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let r = try await checker.run(sources: src, backups: dst, progress: progress)
                await MainActor.run {
                    guard let self else { return }
                    let firstCheck = self.report == nil
                    self.report = r
                    self.checked = self.checked.intersection(Set(self.missing.map(\.id)))
                    self.stage = .ready
                    if firstCheck { self.afterAutomaticCheck() }
                }
            } catch is CancellationError {
            } catch { await MainActor.run { self?.stage = .failed(error.localizedDescription) } }
        }
    }

    func cancel() { task?.cancel() }

    /// Uruchomione przez regułę „karta podłączona” — wtedy po sprawdzeniu działa ustawienie „co dalej”.
    var automatic = false

    /// Po automatycznym sprawdzeniu: pokaż / zapytaj o kopię do stałego folderu / kopiuj od razu.
    func afterAutomaticCheck() {
        guard automatic, let app, let r = report else { return }
        let missing = self.missing
        Notifier.send("Karta „\(cardName)” sprawdzona",
                      missing.isEmpty ? "Wszystko (\(Fmt.files(r.backedUp.count))) ma już kopię." : "Zgrane: \(r.backedUp.count). Nie ma nigdzie: \(Fmt.files(missing.count)) (\(Fmt.bytes(missing.reduce(0) { $0 + $1.file.size }))).",
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
            panel.message = move ? "Dokąd przenieść zaznaczone pliki z karty?" : "Dokąd skopiować zaznaczone pliki z karty?"
            panel.prompt = move ? "Przenieś tutaj" : "Kopiuj tutaj"
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
            app.working = "Kopiuję brakujące z karty…"
            Task {
                let o = await run(items, verify: verify, move: false)
                app.working = nil
                app.show(o.summary + " → " + Fmt.path(base.path))
                Notifier.send("Karta „\(cardName)”: skopiowano brakujące", o.summary + " → " + Fmt.path(base.path), mode: .transfer)
            }
            return
        }
        app.confirm(PendingAction(
            title: move ? "Przenieść \(Fmt.files(items.count)) z karty?" : "Skopiować \(Fmt.files(items.count)) z karty?",
            verb: move ? "Przenoszę" : "Kopiuję", style: move ? .destructive : .normal,
            items: items.map { ($0.source.lastPathComponent, "→ " + Fmt.path($0.target.deletingLastPathComponent().path), $0.size) },
            notes: [keep ? "Do: \(Fmt.path(base.path)) (z zachowaniem folderów karty)" : "Do: \(Fmt.path(dest.path))",
                    "Nic w celu nie jest nadpisywane — jeśli plik o tej nazwie już tam jest, zostanie pominięty.",
                    verify ? "Każda kopia zostanie sprawdzona bajt po bajcie." : "Kopie nie będą sprawdzane (wyłączone w Ustawieniach)."]
                + (move ? ["Oryginał trafi do Kosza na karcie dopiero wtedy, gdy kopia przejdzie sprawdzenie. Miejsce na karcie zwolni się po opróżnieniu Kosza albo sformatowaniu."] : []),
            perform: { [weak self] in await self?.run(items, verify: verify, move: move) ?? FileActions.Outcome(summary: "") }))
    }

    private func run(_ items: [TransferItem], verify: Bool, move: Bool) async -> FileActions.Outcome {
        stage = .working(ScanProgress(phase: .copying, total: items.count))
        let progress: ProgressHandler = { [weak self] p in Task { @MainActor in if case .working = self?.stage { self?.stage = .working(p) } } }
        let result: Transfer.Result? = await Task.detached { try? Transfer.copy(items, verify: verify, progress: progress) }.value
        var o = FileActions.Outcome(summary: "")
        guard let r = result else { stage = .ready; o.summary = "Przerwano."; return o }
        o.done = r.copied.map(\.source)
        o.failed = r.failed.map { ($0.0.source, $0.1) } + r.skippedExisting.map { ($0.source, "w celu jest już plik o tej nazwie — pominięty") }
        var trashed = 0
        if move {
            for it in r.copied { if (try? FileManager.default.trashItem(at: it.source, resultingItemURL: nil)) != nil { trashed += 1 } }
        }
        o.summary = (move ? "Przeniesiono: \(trashed)" : "Skopiowano: \(r.copied.count)") + (verify ? " (sprawdzone)" : "")
            + (o.failed.isEmpty ? "" : ", pominięto: \(o.failed.count)")
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
                    Text("Karta „\(job.cardName)”").font(.system(size: 15, weight: .semibold))
                    Text("Szukam kopii w: " + job.searchRoots.map { Fmt.path($0.path) }.joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(job.searchRoots.map(\.path).joined(separator: "\n"))
                    CardScanOptions(onChange: { job.start() }, disabled: job.isBusy)
                }
                Spacer()
                if !job.isBusy { Button { model.closeCard() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Zamknij").help("Zamknij") }
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

    @ViewBuilder var results: some View {
        if let r = job.report {
            let missing = job.missing
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 22) {
                    StatBadge(value: "\(r.backedUp.count)", label: "zgrane · \(Fmt.bytes(r.backedUp.reduce(0) { $0 + $1.file.size }))", color: Theme.safe)
                    StatBadge(value: "\(r.missing.count)", label: "nie ma nigdzie · \(Fmt.bytes(r.missing.reduce(0) { $0 + $1.file.size }))", color: Theme.missing)
                    if !r.differs.isEmpty { StatBadge(value: "\(r.differs.count)", label: "ta sama nazwa, inna treść", color: Theme.warn) }
                }
                if let last = job.lastResult { Label(last, systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.safe) }

                if !job.backedUpByFolder.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Caption("Już zgrane — tutaj")
                        ForEach(job.backedUpByFolder.prefix(8), id: \.folder) { f in
                            HStack {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe).font(.system(size: 11))
                                Text(Fmt.path(f.folder)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("\(Fmt.files(f.count)) · \(Fmt.bytes(f.size))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                                Button { NSWorkspace.shared.open(URL(fileURLWithPath: f.folder)) } label: { Image(systemName: "folder") }
                                    .buttonStyle(.borderless).help("Otwórz folder")
                            }
                        }
                        if job.backedUpByFolder.count > 8 { Text("…i \(job.backedUpByFolder.count - 8) innych folderów").font(.system(size: 11)).foregroundStyle(.tertiary) }
                    }
                }

                if missing.isEmpty {
                    Label("Wszystko z tej karty ma już kopię.", systemImage: "checkmark.seal.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.safe)
                    formatOffer
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Caption("Nie ma nigdzie — wybierz, co zabrać")
                            Spacer()
                            Button("Zaznacz wszystkie") { job.checked = Set(missing.map(\.id)) }.buttonStyle(.borderless).font(.system(size: 11.5))
                            if !job.checked.isEmpty { Button("Odznacz") { job.checked = [] }.buttonStyle(.borderless).font(.system(size: 11.5)) }
                        }
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(missing) { e in row(e) }
                            }
                        }
                        .frame(maxHeight: 300)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
                        .quickLookPreview($preview, in: missing.map(\.file.url))
                    }
                    HStack(spacing: 10) {
                        Toggle("Zachowaj foldery z karty", isOn: $prefs.auto.keepCardFolders).toggleStyle(.checkbox).font(.system(size: 11.5))
                            .help("Tworzy w wybranym miejscu folder z nazwą karty i jej strukturą (DCIM/…). Wyłączone: wszystkie pliki trafiają prosto do wybranego folderu.")
                        Spacer()
                        let sel = job.selected
                        Text(sel.isEmpty ? "Nic nie zaznaczono" : "Zaznaczono \(Fmt.files(sel.count)) · \(Fmt.bytes(sel.reduce(0) { $0 + $1.file.size }))")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(sel.isEmpty ? .secondary : .primary).monospacedDigit()
                        Button { job.transfer(move: false) } label: { Label("Skopiuj do…", systemImage: "doc.on.doc") }.disabled(sel.isEmpty)
                        Button { job.transfer(move: true) } label: { Label("Przenieś do…", systemImage: "arrow.right.doc.on.clipboard") }
                            .buttonStyle(GradientButtonStyle()).disabled(sel.isEmpty).opacity(sel.isEmpty ? 0.5 : 1)
                            .help("Kopiuje, sprawdza kopię i dopiero wtedy przenosi oryginał z karty do Kosza.")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    func row(_ e: BackupChecker.Entry) -> some View {
        let on = job.checked.contains(e.id)
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { on }, set: { v in if v { job.checked.insert(e.id) } else { job.checked.remove(e.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Thumbnail(url: e.file.url, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.file.name).font(.system(size: 12, weight: .medium))
                if case .differs(let u) = e.status {
                    Text("Uwaga: w \(Fmt.path(u[0].deletingLastPathComponent().path)) jest plik o tej nazwie, ale z inną treścią").font(.system(size: 10.5)).foregroundStyle(Theme.warn).lineLimit(1)
                } else {
                    Text(Fmt.path(e.file.folder)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.date.string(from: e.file.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Fmt.bytes(e.file.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { preview = e.file.url } label: { Image(systemName: "eye") }.buttonStyle(.borderless).help("Podgląd")
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { if on { job.checked.remove(e.id) } else { job.checked.insert(e.id) } }
    }

    /// Wszystko ma kopię → pytanie o format. DupliKAT nie formatuje — otwiera systemowe Narzędzie dyskowe.
    @ViewBuilder var formatOffer: some View {
        if prefs.auto.askFormatAfterImport, job.isRealCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sformatować kartę?").font(.system(size: 12.5, weight: .semibold))
                if !job.exact || prefs.auto.cardMediaOnly || prefs.auto.cardMinSizeMB > 0 {
                    Label("Porównanie było szybkie\(prefs.auto.cardMediaOnly ? " i tylko dla zdjęć, wideo i audio" : "")\(prefs.auto.cardMinSizeMB > 0 ? ", bez małych plików" : ""). Przed formatowaniem możesz sprawdzić dokładnie: włącz „Bajt po bajcie” powyżej.", systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Najzdrowiej dla karty jest sformatować ją w aparacie. Na Macu: otworzę Narzędzie dyskowe — wybierz po lewej „\(job.cardName)”, kliknij Wymaż, format ExFAT. \(AppInfo.name) sam nigdy nie formatuje.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.openDiskUtility() } label: { Label("Otwórz Narzędzie dyskowe", systemImage: "internaldrive") }
                    Button { model.eject(job.card); model.closeCard() } label: { Label("Wysuń (sformatuję w aparacie)", systemImage: "eject") }
                    Spacer()
                    Button("Nie teraz") { model.closeCard() }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.safe.opacity(0.08)))
        }
    }
}
