import DubelCore
import MidniteUIKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 290)
        } detail: {
            detail
                .frame(minWidth: 640)
                .background {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor)
                        if prefs.auto.richUI { AccentGlow(tint: app.mode.color, strength: 0.8) }
                    }
                    .ignoresSafeArea()
                }
        }
        .environment(\.richUI, prefs.auto.richUI)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { (NSApp.delegate as? AppDelegate)?.startTour() } label: { Label("Co jest co", systemImage: "questionmark.circle") }
                    .help("Pokaż, co jest co — samouczek")
                Button { (NSApp.delegate as? AppDelegate)?.showSettings() } label: { Label("Ustawienia", systemImage: "gearshape") }
                    .help("Ustawienia (⌘,)")
            }
        }

        .coachMarks(Tour.steps, isPresented: $app.tourActive, step: $app.tourStep) { prefs.auto.tourDone = true }
        .sheet(item: $app.pending) { ConfirmSheet(action: $0) }
        .overlay(alignment: .bottom) { toast }
        .springy(app.toast, reduceMotion: reduceMotion)
        .springy(app.working, reduceMotion: reduceMotion)
    }

    @ViewBuilder var detail: some View {
        switch app.mode {
        case .duplicates: GroupsScreen(model: app.duplicates).id(Mode.duplicates)
        case .photos: GroupsScreen(model: app.photos).id(Mode.photos)
        case .media: GroupsScreen(model: app.media).id(Mode.media)
        case .backup: BackupScreen(model: app.backup)
        case .transfer: TransferScreen(model: app.transfer)
        case .fcp: FCPScreen(model: app.fcp)
        case .system: SystemScreen(model: app.system)
        }
    }

    @ViewBuilder var toast: some View {
        if let text = app.working ?? app.toast {
            HStack(spacing: 8) {
                if app.working != nil { ProgressView().controlSize(.small) } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.safe) }
                Text(text).font(.system(size: 12, weight: .medium)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(VisualEffect(material: .hudWindow, blending: .withinWindow).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.bottom, 64)
            .frame(maxWidth: 520)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onTapGesture { app.toast = nil }
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let modes = app.visibleModes
        let sections = modes.map(\.section).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        List(selection: Binding(get: { app.mode }, set: { if let m = $0 { app.mode = m } })) {
            ForEach(sections, id: \.self) { sec in
                Section(sec) { ForEach(modes.filter { $0.section == sec }) { row($0) } }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) { DisksPanel() }
    }

    @Environment(\.richUI) private var rich

    func row(_ m: Mode) -> some View {
        HStack(spacing: 8) {
            if rich {
                IconCircle(symbol: m.symbol, color: m.color, size: 22)
                Text(m.title)
            } else {
                Label(m.title, systemImage: m.symbol)
            }
            Spacer()
            switch m {
            case .duplicates: ModeBadge(mode: m, model: app.duplicates)
            case .photos: ModeBadge(mode: m, model: app.photos)
            case .media: ModeBadge(mode: m, model: app.media)
            case .backup: ModeBadge(mode: m, model: app.backup)
            case .transfer: ModeBadge(mode: m, model: app.transfer)
            case .fcp: ModeBadge(mode: m, model: app.fcp)
            case .system: ModeBadge(mode: m, model: app.system)
            }
        }
        .tag(m)
        .coachAnchor("mode-\(m.rawValue)")
    }
}

/// Znaczek przy trybie: obserwuje WŁASNY model, więc odświeża się, gdy skan się kończy (AppModel sam by tego nie zauważył).
struct ModeBadge<M: ObservableObject>: View {
    let mode: Mode
    @ObservedObject var model: M
    @EnvironmentObject var app: AppModel
    var body: some View {
        if app.isRunning(mode) {
            ProgressView().controlSize(.mini)
        } else if let b = app.badge(mode) {
            Text(b).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Zajętość dysków — widać od razu, gdzie brakuje miejsca.
struct DisksPanel: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Caption("Dyski")
                Spacer()
                Button { app.refreshVolumes() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Odśwież").accessibilityLabel("Odśwież dyski")
            }
            ForEach(app.volumes) { v in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(v.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Spacer()
                        Text("wolne \(Fmt.bytes(v.free))").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Theme.fullness(v.used).gradient).frame(width: g.size.width * v.used)
                        }
                    }
                    .frame(height: 5)
                }
                .help("\(v.name): zajęte \(Fmt.percent(v.used)) z \(Fmt.bytes(v.total))")
            }
        }
        .padding(12)
        .coachAnchor("disks")
    }
}

/// Samouczek „co jest co” — pokazywany raz po przewodniku, potem z menu Pomoc / Ustawień.
enum Tour {
    static let steps: [CoachStep] = [
        CoachStep(anchor: "mode-duplicates", symbol: "doc.on.doc", title: "Szukaj duplikatów",
                  text: "Trzy sposoby: identyczne pliki (Duplikaty), ten sam obraz w innym rozmiarze albo serie zdjęć (Podobne zdjęcia) i ten sam materiał w innym eksporcie (Podobne wideo i audio)."),
        CoachStep(anchor: "mode-transfer", symbol: "sdcard", title: "Karty z aparatu",
                  text: "Podłączasz kartę i widzisz, co z niej jest już zgrane (i w jakim folderze), a czego nie ma nigdzie. Zaznaczasz pliki → Skopiuj albo Przenieś."),
        CoachStep(anchor: "mode-backup", symbol: "arrow.left.arrow.right", title: "Porównaj foldery",
                  text: "Czy wszystko z jednego miejsca jest w drugim? Np. folder roboczy vs dysk z archiwum. Tu też zapisujesz stałe pary, które porównujesz regularnie."),
        CoachStep(anchor: "mode-system", symbol: "gauge.with.dots.needle.67percent", title: "Miejsce na dysku",
                  text: "Pliki montażowe (rendery, podglądy, proxy i cache z Final Cut, Premiere, DaVinci, CapCut) i Dane systemowe — co po cichu zjada miejsce. Niczego tam nie usuwam sam."),
        CoachStep(anchor: "disks", symbol: "internaldrive", title: "Twoje dyski",
                  text: "Ile miejsca zostało na każdym podłączonym dysku. Pasek robi się czerwony, gdy dysk jest prawie pełny."),
        CoachStep(anchor: "locations", symbol: "plus.circle", title: "Gdzie szukać",
                  text: "Tu wskazujesz foldery albo dyski: przycisk „Dodaj miejsce” albo przeciągnij folder z Findera."),
        CoachStep(anchor: "scan", symbol: "magnifyingglass", title: "Szukaj",
                  text: "Start skanu. Skan tylko czyta — nic nie usuwam ani nie przenoszę bez Twojego potwierdzenia w osobnym oknie."),
        CoachStep(anchor: nil, symbol: "gearshape", title: "Ustawienia i pomoc",
                  text: "Zębatka w prawym górnym rogu okna otwiera Ustawienia (⌘,), a „?” obok — ten samouczek."),
        CoachStep(anchor: nil, symbol: "menubar.rectangle", title: "Ikona w pasku menu",
                  text: "Przy zegarze jest ikona DupliKAT. Kliknięcie otwiera albo chowa okno, prawy przycisk — menu z regułami. Escape też chowa okno; DupliKAT działa dalej w tle."),
    ]
}

// MARK: - Potwierdzenie

struct ConfirmSheet: View {
    let action: PendingAction
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: action.style == .destructive ? "trash" : "arrow.right.doc.on.clipboard")
                    .font(.system(size: 22)).foregroundStyle(action.style == .destructive ? Theme.warn : Theme.accent.primary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.system(size: 15, weight: .semibold))
                    Text("Razem \(Fmt.bytes(action.totalSize))").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(action.items.indices, id: \.self) { i in
                        let it = action.items[i]
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(it.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(it.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(Fmt.bytes(it.size)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(i % 2 == 0 ? Color.primary.opacity(0.035) : .clear)
                    }
                }
            }
            .frame(minHeight: 80, maxHeight: 260)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                ForEach(action.notes, id: \.self) { n in
                    Label(n, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(action.blockers, id: \.self) { b in
                    Label(b, systemImage: "exclamationmark.octagon.fill").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.missing).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action.verb.replacingOccurrences(of: "Przenoszę", with: "Przenieś").replacingOccurrences(of: "Kopiuję", with: "Kopiuj").replacingOccurrences(of: "Tworzę", with: "Utwórz")) {
                    app.run(action)
                }
                .buttonStyle(.borderedProminent)
                .tint(action.style == .destructive ? Theme.warn : Theme.accent.primary)
                .disabled(!action.blockers.isEmpty || action.items.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
