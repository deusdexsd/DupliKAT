import DubelCore
import MidniteUIKit
import SwiftUI

enum SettingsTab: Hashable { case general, transfer, rules, alarms, shortcuts, scanning, exclusions }

/// Ustawienia w stylu Ogara/Handy: zakładki-pigułki u góry, karty sekcji, wiersze z opisami.
struct SettingsView: View {
    var initial: SettingsTab = .general
    var onChange: () -> Void = {}
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var app: AppModel
    @State private var tab: SettingsTab = .general
    @State private var cacheCleared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            PillTabs(items: [(SettingsTab.general, "Ogólne", "gearshape"), (.transfer, "Zgrywanie", "sdcard"), (.rules, "Reguły", "bolt"),
                             (.alarms, "Alarmy", "bell"), (.shortcuts, "Skróty", "keyboard"), (.scanning, "Skanowanie", "magnifyingglass"), (.exclusions, "Wykluczenia", "nosign")],
                     selection: $tab, fontSize: 11)
                .focusEffectDisabled()
                .padding(.horizontal, 16).padding(.top, 14)
            ScrollView {
                VStack(spacing: 16) {
                    switch tab {
                    case .general: general
                    case .transfer: transfer
                    case .rules: rules
                    case .alarms: alarms
                    case .shortcuts: ShortcutsSettings()
                    case .scanning: scanning
                    case .exclusions: exclusions
                    }
                }
                .padding(.horizontal, 16).padding(.bottom, 16)
                .springy(tab, reduceMotion: reduceMotion)
            }
            .scrollIndicators(.hidden)
        }
        .frame(minWidth: 600, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { tab = initial }
        .onReceive(NotificationCenter.default.publisher(for: .dubelSettingsTab)) { n in if let t = n.object as? SettingsTab { tab = t } }
        .onChange(of: prefs.auto) { _, _ in onChange() }
    }

    // MARK: Ogólne

    var general: some View {
        Group {
            SectionCard(title: "Wygląd okna", footer: "„Jak przewodnik” — poświata i kolorowe ikony trybów. „Klasyczny” — stonowany, jak natywne aplikacje macOS.") {
                UIStylePicker(selection: $prefs.auto.uiStyle).padding(.vertical, 4)
            }
            SectionCard(title: "Sekcje w pasku bocznym", footer: app.hasFinalCut ? "Pliki montażowe — wykryte programy: " + app.installedEditors.map(\.title).joined(separator: ", ") + "." : "Nie widzę Final Cut, Premiere, DaVinci ani CapCut, więc „Pliki montażowe” są domyślnie ukryte.") {
                ForEach(Mode.allCases) { m in
                    SwitchRow(title: m.title, subtitle: m.section, isOn: Binding(
                        get: { m == .fcp && !app.hasFinalCut ? prefs.auto.fcpForced && !prefs.auto.hiddenModes.contains(m.rawValue) : !prefs.auto.hiddenModes.contains(m.rawValue) },
                        set: { on in
                            if m == .fcp && !app.hasFinalCut { prefs.auto.fcpForced = on }
                            if on { prefs.auto.hiddenModes.removeAll { $0 == m.rawValue } } else if app.visibleModes.count > 1 { prefs.auto.hiddenModes.append(m.rawValue) }
                            if !app.visibleModes.contains(app.mode), let f = app.visibleModes.first { app.mode = f }
                        }))
                    if m != Mode.allCases.last { Divider() }
                }
            }
            SectionCard(title: "Ikona aplikacji", footer: "Zmienia ikonę w Docku i w oknach. W Finderze zostaje ikona z kartami — zmiana pliku aplikacji zepsułaby jej podpis.") {
                AppIconPicker(selection: $prefs.auto.appIcon).padding(.vertical, 4)
            }
            SectionCard(title: "Ikona w pasku menu") {
                MenuBarIconPicker(selection: $prefs.auto.menuBarIcon).padding(.vertical, 4)
            }
            SectionCard(title: "Gdzie mieszka DupliKAT", footer: "Reguły automatyczne (karty, alarmy) działają tylko, gdy DupliKAT jest uruchomiony — najwygodniej w pasku menu. Lewy przycisk ikony otwiera okno, prawy — menu z regułami.") {
                HStack(spacing: 10) {
                    ChoiceTile(symbol: "menubar.dock.rectangle", title: "Pasek menu + Dock", selected: prefs.auto.showMenuBarIcon && prefs.auto.showInDock) {
                        prefs.auto.showMenuBarIcon = true; prefs.auto.showInDock = true
                    }
                    ChoiceTile(symbol: "menubar.rectangle", title: "Tylko pasek menu", subtitle: "bez ikony w Docku", selected: prefs.auto.showMenuBarIcon && !prefs.auto.showInDock) {
                        prefs.auto.showMenuBarIcon = true; prefs.auto.showInDock = false
                    }
                    ChoiceTile(symbol: "dock.rectangle", title: "Tylko okno", subtitle: "reguły działają, gdy otwarte", selected: !prefs.auto.showMenuBarIcon) {
                        prefs.auto.showMenuBarIcon = false; prefs.auto.showInDock = true
                    }
                }
                .padding(.vertical, 4)
                Divider()
                SwitchRow(title: "Uruchamiaj przy logowaniu", subtitle: "DupliKAT startuje po cichu w pasku menu",
                          isOn: Binding(get: { prefs.auto.launchAtLogin }, set: { prefs.auto.launchAtLogin = $0; AutomationEngine.applyLoginItem($0) }))
            }
            SectionCard(title: "Przewodnik") {
                SettingRow(title: "Przewodnik konfiguracji", subtitle: "Przejdź jeszcze raz przez pierwsze ustawienia") {
                    Button("Otwórz") { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
                }
                Divider()
                SettingRow(title: "Pokaż, co jest co", subtitle: "Samouczek z podświetleniem elementów okna") {
                    Button("Pokaż") { (NSApp.delegate as? AppDelegate)?.startTour() }
                }
            }
            SectionCard(title: "Zasada", footer: nil) {
                Label("DupliKAT niczego nie usuwa, nie kopiuje i nie formatuje sam. Automatycznie tylko czyta i pyta — każdą zmianę na dysku potwierdzasz w oknie z listą plików.", systemImage: "hand.raised.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Zgrywanie

    var transfer: some View {
        Group {
            SectionCard(title: "Gdzie szukać kopii plików z karty", footer: "Po podłączeniu karty DupliKAT sprawdza, co z niej już jest w tych miejscach (po zawartości — nazwa nie ma znaczenia).") {
                SearchLocationsEditor()
            }
            SectionCard(title: "Co sprawdzać na karcie", footer: "„Tylko zdjęcia, wideo i audio” pomija pliki pomocnicze aparatu (XML, baza karty, miniatury). „Bajt po bajcie” jest wolne przez USB; bez niego porównuję rozmiar i fragmenty plików.") {
                CardScanOptions()
            }
            SectionCard(title: "Kopiowanie i przenoszenie", footer: "Nic w miejscu docelowym nie jest nadpisywane. Przy „Przenieś” oryginał z karty idzie do Kosza dopiero po sprawdzonej kopii.") {
                SwitchRow(title: "Zachowaj foldery z karty", subtitle: "W wybranym miejscu powstanie folder z nazwą karty i jej strukturą (DCIM/…)", isOn: $prefs.auto.keepCardFolders)
                Divider()
                SwitchRow(title: "Sprawdzaj kopie bajt po bajcie", subtitle: "Wolniej, ale masz pewność, że kopia jest identyczna (przy przenoszeniu zawsze włączone)", isOn: $prefs.auto.verifyCopies)
                Divider()
                SwitchRow(title: "Gdy wszystko jest zgrane, zapytaj o formatowanie", subtitle: "DupliKAT tylko otwiera systemowe Narzędzie dyskowe — sam nigdy nie formatuje", isOn: $prefs.auto.askFormatAfterImport)
            }
        }
    }

    // MARK: Reguły

    var rules: some View {
        VStack(spacing: 10) {
            FeatureRow(symbol: "sdcard.fill", color: FeatureColor.card, title: "Karta podłączona → sprawdź, co jest zgrane",
                       subtitle: "Pokażę, co z karty ma już kopię (i gdzie), a czego nie ma nigdzie.", isOn: ruleBinding(\.cardImportEnabled)) {
                CardAfterCheckPicker()
            }
            FeatureRow(symbol: "externaldrive.fill.badge.checkmark", color: FeatureColor.volume, title: "Dysk podłączony → sprawdź duplikaty",
                       subtitle: "Tylko odczyt. Po skanie dostajesz powiadomienie z wynikiem.",
                       isOn: Binding(get: { !prefs.auto.checkVolumesOnMount.isEmpty || showVolumePicker }, set: { v in showVolumePicker = v; if !v { prefs.auto.checkVolumesOnMount = [] } else { Notifier.request() } })) {
                VolumeChips(selected: $prefs.auto.checkVolumesOnMount)
            }
            FeatureRow(symbol: "arrow.left.arrow.right", color: FeatureColor.pair, title: "Stałe pary porównań",
                       subtitle: "„Zawsze porównuj to z tym” — edytujesz je w oknie, w trybie Zgrywanie i kopie.",
                       isOn: .constant(!prefs.auto.pairs.isEmpty)) {
                ForEach(prefs.auto.pairs) { p in
                    Toggle("\(p.name.isEmpty ? "Para" : p.name): porównuj po podłączeniu", isOn: Binding(get: { p.runOnMount }, set: { v in
                        if let i = prefs.auto.pairs.firstIndex(where: { $0.id == p.id }) { prefs.auto.pairs[i].runOnMount = v }
                    })).toggleStyle(.checkbox).font(.system(size: 11.5))
                }
            }
            .disabled(prefs.auto.pairs.isEmpty)
            .help(prefs.auto.pairs.isEmpty ? "Najpierw dodaj parę w oknie → Zgrywanie i kopie" : "")
        }
    }
    @State private var showVolumePicker = false

    // MARK: Alarmy

    var alarms: some View {
        VStack(spacing: 10) {
            FeatureRow(symbol: "exclamationmark.triangle.fill", color: FeatureColor.space, title: "Alarm zajętego miejsca",
                       subtitle: "Powiadomienie, gdy któryś dysk przekroczy próg (najwyżej raz na dobę na dysk).", isOn: ruleBinding(\.spaceAlarmEnabled)) {
                SettingRow(title: "Próg") { ValueStepper(value: $prefs.auto.spaceAlarmPercent, range: 50...99, step: 1) { "\(Int($0))%" } }
            }
            FeatureRow(symbol: "gauge.with.dots.needle.67percent", color: FeatureColor.system, title: "Pilnuj danych systemowych",
                       subtitle: "Cache, symulatory, kopie iPhone'a, logi… Powiadomienie, gdy coś nagle urośnie albo pojawi się duży plik nieznanego pochodzenia.", isOn: ruleBinding(\.systemWatchEnabled)) {
                VStack(spacing: 6) {
                    SettingRow(title: "Alarm, gdy urośnie o") { ValueStepper(value: $prefs.auto.systemWatchGrowthGB, range: 1...100, step: 1) { "\(Int($0)) GB" } }
                    SettingRow(title: "Nowy plik większy niż") { ValueStepper(value: $prefs.auto.systemWatchBigFileGB, range: 0.5...50, step: 0.5) { String(format: "%.1f GB", $0).replacingOccurrences(of: ".", with: ",") } }
                    SettingRow(title: "Mierz co", subtitle: "Pomiar trwa kilka minut, w tle, z niskim priorytetem") {
                        ValueStepper(value: $prefs.auto.systemWatchIntervalHours, range: 6...168, step: 6) { "\(Int($0)) h" }
                    }
                }
            }
            FeatureRow(symbol: "calendar", color: FeatureColor.weekly, title: "Tygodniowy przegląd",
                       subtitle: "Raz w tygodniu: ile zajmują pliki generowane FCP i ile jest wolnego miejsca na dyskach.", isOn: ruleBinding(\.weeklyReportEnabled))
        }
    }

    // MARK: Skanowanie

    var scanning: some View {
        Group {
            SectionCard(title: "Duplikaty") {
                SettingRow(title: "Pomijaj pliki mniejsze niż") {
                    Picker("", selection: $prefs.minSizeMB) {
                        Text("100 KB").tag(0.1); Text("1 MB").tag(1.0); Text("10 MB").tag(10.0); Text("100 MB").tag(100.0); Text("1 GB").tag(1000.0)
                    }.labelsHidden().fixedSize()
                }
                Divider()
                SwitchRow(title: "Tryb szybki", subtitle: "Porównuje tylko fragmenty plików — dużo szybciej na dyskach USB, wynik „prawie na pewno”", isOn: $prefs.quickMode)
                Divider()
                SwitchRow(title: "Uwzględniaj ukryte pliki i foldery", isOn: $prefs.includeHidden)
            }
            SectionCard(title: "Backup") {
                SwitchRow(title: "Sprawdzaj całą zawartość plików", subtitle: "Zalecane, jeśli potem kasujesz kartę", isOn: $prefs.backupVerify)
            }
            SectionCard(title: "iCloud", footer: "Pliki z Biurka i Dokumentów, które macOS trzyma tylko w iCloud, są zawsze pomijane — ich odczyt wymusiłby pobieranie na dysk. Pominięte widzisz w trakcie skanu („Pominięto…”).") {
                Label("Pomijam pliki niepobrane z iCloud", systemImage: "icloud.slash").font(.system(size: 12))
            }
            SectionCard(title: "Pamięć wyników", footer: "Drugi skan tych samych dysków nie czyta niezmienionych plików od nowa.") {
                SwitchRow(title: "Zapamiętuj odciski plików", isOn: $prefs.useCache)
                Divider()
                SettingRow(title: "Zapamiętane pliki: \(app.cache.count)") {
                    Button(cacheCleared ? "Wyczyszczono" : "Wyczyść") { app.resetCache(); cacheCleared = true }.disabled(cacheCleared)
                }
            }
        }
    }

    // MARK: Wykluczenia

    var exclusions: some View {
        Group {
            SectionCard(title: "Pomijane foldery") {
                if prefs.excludedPaths.isEmpty {
                    Text("Brak — skanowane jest wszystko w wybranych miejscach.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(prefs.excludedPaths, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(Fmt.path(p)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { prefs.excludedPaths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Usuń wykluczenie").help("Usuń wykluczenie")
                    }
                }
                Button("Dodaj folder…") {
                    prefs.excludedPaths += FileActions.chooseFolder(title: "Foldery, do których DupliKAT ma nie zaglądać", prompt: "Wyklucz", multiple: true).map(\.path).filter { !prefs.excludedPaths.contains($0) }
                }.controlSize(.small)
            }
            SectionCard(title: "Zawsze chronione") {
                Text("Biblioteki Final Cut (.fcpbundle) i ich cache, foldery proxy/optimized FCP, szablony Motion, kopie zapasowe FCP; foldery podglądów, autozapisu i cache Premiere Pro; bazy projektów, cache i proxy DaVinci Resolve; biblioteka Zdjęć, aplikacje, projekty Xcode i Logic. Usunięcie „duplikatu” z ich wnętrza zepsułoby bibliotekę albo szablon.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ruleBinding(_ kp: WritableKeyPath<Automation, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.auto[keyPath: kp] }, set: { prefs.auto[keyPath: kp] = $0; if $0 { Notifier.request() } })
    }
}
