import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Stan dla okienka przy pasku menu: odświeżany co 0,3 s (zbiera postęp ze wszystkich modeli naraz).
@MainActor
final class MenuBarStatus: ObservableObject {
    @Published var tasks: [RunningTask] = []
    /// Dysk rozwinięty w okienku (klik w dysk pokazuje jego szybkie akcje — jak ekran dysku w oknie).
    @Published var openDrive: String?
    /// Największy pokazany procent dla zadania — pasek nigdy się nie cofa, nawet gdy zmienia się etap.
    private var shown: [String: Double] = [:]
    weak var app: AppModel?
    private var timer: Timer?

    init(app: AppModel) {
        self.app = app
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    func refresh() {
        guard let app else { return }
        let t = app.tasks
        let ids = Set(t.map(\.id))
        shown = shown.filter { ids.contains($0.key) }
        for task in t { shown[task.id] = max(shown[task.id] ?? 0, task.progress.overall) }
        tasks = t
    }

    func percent(_ t: RunningTask) -> Double { shown[t.id] ?? t.progress.overall }
    var headline: Double? { tasks.first.map(percent) }
}

/// Okienko po kliknięciu ikony w pasku menu: co trwa (z procentem), a gdy nic — szybkie akcje i dyski.
struct MenuBarPanel: View {
    @ObservedObject var status: MenuBarStatus
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs
    let openApp: () -> Void
    let openSettings: () -> Void
    let run: (QuickAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if status.tasks.isEmpty { idle } else {
                ForEach(status.tasks) { t in TaskCard(task: t, percent: status.percent(t)) { app.mode = t.mode; openApp() } }
            }
            if let n = app.quickNote { note(n) }
            ForEach(app.drives.allPending, id: \.ingest) { p in PendingBackupRow(p: p, memory: app.drives, compact: true) }
            if let c = app.transfer.card, c.stage == .ready, let r = c.report { cardResult(c, r) }
            Divider()
            disks
        }
        .padding(14)
        .frame(width: 340)
        .environment(\.richUI, prefs.auto.richUI)
    }

    var header: some View {
        HStack(spacing: 10) {
            if let img = AppIconChoice.current(prefs.auto.appIcon).image { Image(nsImage: img).resizable().frame(width: 28, height: 28) }
            VStack(alignment: .leading, spacing: 0) {
                Text(AppInfo.name).font(.system(size: 13, weight: .semibold))
                Text(status.tasks.isEmpty ? T("Nic teraz nie skanuję") : status.tasks.count == 1 ? T("Pracuję w tle") : T("Pracuję w tle (%@)", "\(status.tasks.count)"))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: openApp) { Image(systemName: "macwindow") }.help(T("Otwórz okno aplikacji (albo kliknij ikonę dwa razy)")).accessibilityLabel(T("Otwórz aplikację"))
            Button(action: openSettings) { Image(systemName: "gearshape") }.help(T("Ustawienia")).accessibilityLabel(T("Ustawienia"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
    }

    @ViewBuilder var idle: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(T("Szybkie akcje"))
            if let card = app.volumes.first(where: \.isCard) {
                quick("sdcard.fill", FeatureColor.card, T("Co jest zgrane z „%@”?", "\(card.name)"), T("Które pliki z karty mają już kopię i gdzie")) { run(.checkCard) }
            }
            quick("folder.fill", FeatureColor.volume, T("Sprawdź zaznaczone w Finderze"), T("Czy mają gdzieś kopię — i gdzie")) { run(.checkSelection) }
            quick("doc.on.doc.fill", Theme.accent.primary, T("Duplikaty w zaznaczonym folderze"), T("Identyczne pliki wewnątrz zaznaczenia")) { run(.duplicatesSelection) }
            quick("gauge.with.dots.needle.67percent", FeatureColor.system, T("Zmierz dane systemowe"), T("Co zjada miejsce na dysku startowym")) { run(.measureSystem) }
        }
    }

    func quick(_ symbol: String, _ color: Color, _ title: String, _ subtitle: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconCircle(symbol: symbol, color: color, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.vertical, 4).padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickRowStyle())
    }

    func note(_ n: QuickNote) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: n.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(n.isError ? Color.orange : Theme.safe)
            VStack(alignment: .leading, spacing: 5) {
                Text(n.text).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    if n.privacyLink {
                        Button(T("Otwórz Ustawienia systemowe")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                        }
                    }
                    if let m = n.mode {
                        Button(T("Pokaż wynik")) { app.mode = m; app.quickNote = nil; openApp() }
                            .buttonStyle(.borderedProminent).controlSize(.small).tint(Theme.accent.primary)
                    }
                    Spacer()
                    Button(T("Zamknij")) { app.quickNote = nil }.foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless).font(.system(size: 11))
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }

    func cardResult(_ c: CardCheckJob, _ r: BackupChecker.Report) -> some View {
        let missing = c.missing
        let backed = r.backedUp
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption(c.isSelection ? T("Sprawdzone: %@", "\(c.cardName)") : T("Ostatnio sprawdzona karta"))
                Spacer()
                Button { app.transfer.closeCard() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(T("Zamknij")).accessibilityLabel(T("Zamknij"))
            }
            HStack(spacing: 14) {
                Label(c.isSelection ? T("Z kopią: %@", "\(backed.count)") : T("%@ zgrane", "\(backed.count)"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.safe)
                Label(c.isSelection ? T("Bez kopii: %@", "\(missing.count)") : T("%@ nie ma nigdzie", "\(missing.count)"), systemImage: "xmark.circle.fill").foregroundStyle(missing.isEmpty ? Color.secondary : Theme.missing)
            }
            .font(.system(size: 12, weight: .medium))
            if r.entries.isEmpty {
                Text(T("Nie znalazłem plików do sprawdzenia (mogą być mniejsze niż próg w Ustawieniach → Skanowanie).")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Gdzie leżą kopie — kilka pierwszych plików.
            ForEach(Array(r.entries.prefix(5))) { e in
                VStack(alignment: .leading, spacing: 1) {
                    Text(e.file.name).font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    Group {
                        switch e.status {
                        case .backedUp: Text(CopyText.describe(e, app.drives) ?? "").foregroundStyle(e.onlyOffline ? Theme.warn : Theme.safe)
                        case .differs: Text(T("ta sama nazwa, inna treść")).foregroundStyle(.orange)
                        case .missing:
                            if let a = app.drives.awaitingNote(for: e.file) { Text(a).foregroundStyle(Theme.warn) }
                            else { Text(T("nie ma nigdzie")).foregroundStyle(Theme.missing) }
                        }
                    }
                    .font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                }
            }
            if let rest = c.skippedOthers {
                Button(T("Pominięte pozostałe pliki: %@ — sprawdź też je", "\(Fmt.files(rest.count))")) { c.checkRest() }.buttonStyle(.borderless).font(.system(size: 11))
            }
            if r.entries.count > 5 { Text(T("…i %@ więcej", "\(r.entries.count - 5)")).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            Button(T("Pokaż szczegóły")) { app.mode = .transfer; openApp() }.buttonStyle(.borderless).font(.system(size: 11.5))
        }
    }


    var disks: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(app.volumes) { v in
                Button { withAnimation(.snappy(duration: 0.2)) { status.openDrive = status.openDrive == v.key ? nil : v.key } } label: { DriveRow(volume: v, barHeight: 4) }
                    .buttonStyle(DriveButtonStyle(selected: status.openDrive == v.key))
                    .accessibilityLabel(T("Pokaż dysk %@", "\(v.name)"))
                if status.openDrive == v.key { driveActions(v).transition(.opacity.combined(with: .move(edge: .top))) }
            }
        }
    }

    /// Szybkie akcje dysku: startują od razu w tle, postęp i wynik w tym okienku.
    func driveActions(_ v: VolumeUsage) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if v.isCard {
                quick("sdcard.fill", FeatureColor.card, T("Co jest zgrane?"), T("Które pliki z karty mają już kopię i gdzie")) { background { app.transfer.startCard(v.url, automatic: true) } }
            } else {
                quick("questionmark.folder.fill", FeatureColor.card, T("Czy ma kopie gdzie indziej?"), T("Pliki z tego dysku, których nie ma na innych dyskach")) { background { app.transfer.startCard(v.url) } }
            }
            quick(Mode.duplicates.symbol, Mode.duplicates.color, T("Szukaj duplikatów"), T("Identyczne pliki na tym dysku")) {
                guard !app.duplicates.status.isRunning else { app.quickNote = QuickNote(text: T("Już szukam duplikatów — poczekaj, aż skończy się poprzedni skan.")); return }
                app.duplicates.roots = [v.url]; app.duplicates.start()
            }
            if !v.isCard && v.url.path != "/" && prefs.auto.rememberDrives {
                quick("brain", FeatureColor.pair, T("Zapamiętaj zawartość teraz"), T("Odśwież listę plików (tylko odczyt, w tle)")) { app.drives.remember(v, force: true) }
            }
            HStack(spacing: 14) {
                Button(T("Pokaż w oknie")) { app.selectedDrive = v.key; openApp() }
                Button(T("Pokaż w Finderze")) { NSWorkspace.shared.activateFileViewerSelecting([v.url]) }
                Spacer()
                if v.url.path != "/" { Button(T("Wysuń")) { app.transfer.eject(v.url); status.openDrive = nil } }
            }
            .buttonStyle(.borderless).font(.system(size: 11.5)).padding(.horizontal, 6).padding(.top, 2)
        }
        .padding(.leading, 8).padding(.bottom, 6)
    }

    /// Start zadania bez przełączania widoku w oknie.
    func background(_ start: () -> Void) {
        guard app.transfer.card?.isBusy != true else { app.quickNote = QuickNote(text: T("Już sprawdzam — poczekaj, aż skończy się poprzednie sprawdzanie.")); return }
        let (mode, drive) = (app.mode, app.selectedDrive)
        start()
        if app.mode != mode { app.mode = mode }
        app.selectedDrive = drive
    }
}

struct TaskCard: View {
    let task: RunningTask
    let percent: Double
    let open: () -> Void
    @Environment(\.midniteAccent) private var accent

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                IconCircle(symbol: task.mode.symbol, color: task.mode.color, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(T(task.progress.phase.rawValue)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int((percent * 100).rounded()))%").font(.system(size: 17, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(accent.gradient)
            }
            // Pasek w kolorze procentu (gradient akcentu) — szary kolor trybu „Dane systemowe” był prawie niewidoczny.
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: [accent.primary, accent.secondary], startPoint: .leading, endPoint: .trailing)).frame(width: max(6, g.size.width * min(1, percent)))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.3), value: percent)
            Text(task.progress.current.isEmpty ? " " : Fmt.path(task.progress.current))
                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            HStack {
                Button(T("Pokaż w oknie"), action: open)
                Spacer()
                Button(T("Przerwij"), action: task.cancel)
            }
            .buttonStyle(.borderless).font(.system(size: 11.5))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(task.mode.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(task.mode.color.opacity(0.25)))
    }
}

struct QuickRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.0)))
            .modifier(HoverFill())
    }
}

private struct HoverFill: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .onHover { hover = $0 }
    }
}
