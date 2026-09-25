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
    @State private var languageChanged = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 12) {
            PillTabs(items: [(SettingsTab.general, T("Ogólne"), "gearshape"), (.transfer, T("Zgrywanie"), "sdcard"), (.rules, T("Reguły"), "bolt"),
                             (.alarms, T("Alarmy"), "bell"), (.shortcuts, T("Skróty"), "keyboard"), (.scanning, T("Skanowanie"), "magnifyingglass"), (.exclusions, T("Wykluczenia"), "nosign")],
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
            SectionCard(title: "Język · Language", footer: languageChanged ? T("Zmiana języka obejmie wszystkie okna po ponownym uruchomieniu.") : nil) {
                HStack {
                    Picker("", selection: Binding(get: { prefs.auto.language }, set: { v in
                        (NSApp.delegate as? AppDelegate)?.setLanguage(v); languageChanged = true
                    })) {
                        Text("Polski").tag("pl")
                        Text("English").tag("en")
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Spacer()
                    if languageChanged {
                        Button(T("Uruchom ponownie")) { (NSApp.delegate as? AppDelegate)?.relaunch() }.buttonStyle(GradientButtonStyle())
                    }
                }
            }
            SectionCard(title: T("Wygląd okna"), footer: T("„Jak przewodnik” — poświata i kolorowe ikony trybów. „Klasyczny” — stonowany, jak natywne aplikacje macOS.")) {
                UIStylePicker(selection: $prefs.auto.uiStyle).padding(.vertical, 4)
            }
            SectionCard(title: T("Sekcje w pasku bocznym"), footer: app.hasFinalCut ? T("Pliki montażowe — wykryte programy: ") + app.installedEditors.map(\.title).joined(separator: ", ") + "." : T("Nie widzę Final Cut, Premiere, DaVinci ani CapCut, więc „Pliki montażowe” są domyślnie ukryte.")) {
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
            SectionCard(title: T("Ikona aplikacji"), footer: T("Zmienia ikonę w Docku i w oknach. W Finderze zostaje ikona z kartami — zmiana pliku aplikacji zepsułaby jej podpis.")) {
                AppIconPicker(selection: $prefs.auto.appIcon).padding(.vertical, 4)
            }
            SectionCard(title: T("Ikona w pasku menu")) {
                MenuBarIconPicker(selection: $prefs.auto.menuBarIcon).padding(.vertical, 4)
            }
            SectionCard(title: T("Gdzie mieszka DupliKAT"), footer: T("Reguły automatyczne (karty, alarmy) działają tylko, gdy DupliKAT jest uruchomiony — najwygodniej w pasku menu. Lewy przycisk ikony otwiera okno, prawy — menu z regułami.")) {
                HStack(spacing: 10) {
                    ChoiceTile(symbol: "menubar.dock.rectangle", title: T("Pasek menu + Dock"), selected: prefs.auto.showMenuBarIcon && prefs.auto.showInDock) {
                        prefs.auto.showMenuBarIcon = true; prefs.auto.showInDock = true
                    }
                    ChoiceTile(symbol: "menubar.rectangle", title: T("Tylko pasek menu"), subtitle: T("bez ikony w Docku"), selected: prefs.auto.showMenuBarIcon && !prefs.auto.showInDock) {
                        prefs.auto.showMenuBarIcon = true; prefs.auto.showInDock = false
                    }
                    ChoiceTile(symbol: "dock.rectangle", title: T("Tylko okno"), subtitle: T("reguły działają, gdy otwarte"), selected: !prefs.auto.showMenuBarIcon) {
                        prefs.auto.showMenuBarIcon = false; prefs.auto.showInDock = true
                    }
                }
                .padding(.vertical, 4)
                Divider()
                SwitchRow(title: T("Uruchamiaj przy logowaniu"), subtitle: T("DupliKAT startuje po cichu w pasku menu"),
                          isOn: Binding(get: { prefs.auto.launchAtLogin }, set: { prefs.auto.launchAtLogin = $0; AutomationEngine.applyLoginItem($0) }))
            }
            SectionCard(title: T("Przewodnik")) {
                SettingRow(title: T("Przewodnik konfiguracji"), subtitle: T("Przejdź jeszcze raz przez pierwsze ustawienia")) {
                    Button(T("Otwórz")) { (NSApp.delegate as? AppDelegate)?.showOnboarding() }
                }
                Divider()
                SettingRow(title: T("Pokaż, co jest co"), subtitle: T("Samouczek z podświetleniem elementów okna")) {
                    Button(T("Pokaż")) { (NSApp.delegate as? AppDelegate)?.startTour() }
                }
            }
            SectionCard(title: T("Zasada"), footer: nil) {
                Label(T("DupliKAT niczego nie usuwa, nie kopiuje i nie formatuje sam. Automatycznie tylko czyta i pyta — każdą zmianę na dysku potwierdzasz w oknie z listą plików."), systemImage: "hand.raised.fill")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Zgrywanie

    var transfer: some View {
        Group {
            DrivesSettings()
            SectionCard(title: T("Gdzie szukać kopii plików z karty"), footer: T("Po podłączeniu karty DupliKAT sprawdza, co z niej już jest w tych miejscach (po zawartości — nazwa nie ma znaczenia).")) {
                SearchLocationsEditor()
            }
            SectionCard(title: T("Co sprawdzać na karcie"), footer: T("„Tylko zdjęcia, wideo i audio” pomija pliki pomocnicze aparatu (XML, baza karty, miniatury). „Bajt po bajcie” jest wolne przez USB; bez niego porównuję rozmiar i fragmenty plików.")) {
                CardScanOptions()
            }
            SectionCard(title: T("Kopiowanie i przenoszenie"), footer: T("Nic w miejscu docelowym nie jest nadpisywane. Przy „Przenieś” oryginał z karty idzie do Kosza dopiero po sprawdzonej kopii.")) {
                SwitchRow(title: T("Zachowaj foldery z karty"), subtitle: T("W wybranym miejscu powstanie folder z nazwą karty i jej strukturą (DCIM/…)"), isOn: $prefs.auto.keepCardFolders)
                Divider()
                SwitchRow(title: T("Sprawdzaj kopie bajt po bajcie"), subtitle: T("Wolniej, ale masz pewność, że kopia jest identyczna (przy przenoszeniu zawsze włączone)"), isOn: $prefs.auto.verifyCopies)
                Divider()
                SwitchRow(title: T("Gdy wszystko jest zgrane, zapytaj o formatowanie"), subtitle: T("DupliKAT tylko otwiera systemowe Narzędzie dyskowe — sam nigdy nie formatuje"), isOn: $prefs.auto.askFormatAfterImport)
                Divider()
                SwitchRow(title: T("Ostrzegaj przed formatowaniem"), subtitle: T("Pokazuje nazwę, pojemność i identyfikator karty, bo Narzędzie dyskowe zaznacza na starcie dysk główny"), isOn: $prefs.auto.formatWarnings)
            }
        }
    }

    // MARK: Reguły

    var rules: some View {
        VStack(spacing: 10) {
            FeatureRow(symbol: "sdcard.fill", color: FeatureColor.card, title: T("Karta podłączona → sprawdź, co jest zgrane"),
                       subtitle: T("Pokażę, co z karty ma już kopię (i gdzie), a czego nie ma nigdzie."), isOn: ruleBinding(\.cardImportEnabled)) {
                CardAfterCheckPicker()
            }
            FeatureRow(symbol: "externaldrive.fill.badge.checkmark", color: FeatureColor.volume, title: T("Dysk podłączony → sprawdź duplikaty"),
                       subtitle: T("Tylko odczyt. Po skanie dostajesz powiadomienie z wynikiem."),
                       isOn: Binding(get: { !prefs.auto.checkVolumesOnMount.isEmpty || showVolumePicker }, set: { v in showVolumePicker = v; if !v { prefs.auto.checkVolumesOnMount = [] } else { Notifier.request() } })) {
                VolumeChips(selected: $prefs.auto.checkVolumesOnMount)
            }
            FeatureRow(symbol: "arrow.left.arrow.right", color: FeatureColor.pair, title: T("Stałe pary porównań"),
                       subtitle: T("„Zawsze porównuj to z tym” — edytujesz je w oknie, w trybie Zgrywanie i kopie."),
                       isOn: .constant(!prefs.auto.pairs.isEmpty)) {
                ForEach(prefs.auto.pairs) { p in
                    Toggle(T("%@: porównuj po podłączeniu", "\(p.name.isEmpty ? T("Para") : p.name)"), isOn: Binding(get: { p.runOnMount }, set: { v in
                        if let i = prefs.auto.pairs.firstIndex(where: { $0.id == p.id }) { prefs.auto.pairs[i].runOnMount = v }
                    })).toggleStyle(.checkbox).font(.system(size: 11.5))
                }
            }
            .disabled(prefs.auto.pairs.isEmpty)
            .help(prefs.auto.pairs.isEmpty ? T("Najpierw dodaj parę w oknie → Zgrywanie i kopie") : "")
        }
    }
    @State private var showVolumePicker = false

    // MARK: Alarmy

    var alarms: some View {
        VStack(spacing: 10) {
            FeatureRow(symbol: "exclamationmark.triangle.fill", color: FeatureColor.space, title: T("Alarm zajętego miejsca"),
                       subtitle: T("Powiadomienie, gdy któryś dysk przekroczy próg (najwyżej raz na dobę na dysk)."), isOn: ruleBinding(\.spaceAlarmEnabled)) {
                SettingRow(title: T("Próg")) { ValueStepper(value: $prefs.auto.spaceAlarmPercent, range: 50...99, step: 1) { "\(Int($0))%" } }
            }
            FeatureRow(symbol: "gauge.with.dots.needle.67percent", color: FeatureColor.system, title: T("Pilnuj danych systemowych"),
                       subtitle: T("Cache, symulatory, kopie iPhone'a, logi… Powiadomienie, gdy coś nagle urośnie albo pojawi się duży plik nieznanego pochodzenia."), isOn: ruleBinding(\.systemWatchEnabled)) {
                VStack(spacing: 6) {
                    SettingRow(title: T("Alarm, gdy urośnie o")) { ValueStepper(value: $prefs.auto.systemWatchGrowthGB, range: 1...100, step: 1) { "\(Int($0)) GB" } }
                    SettingRow(title: T("Nowy plik większy niż")) { ValueStepper(value: $prefs.auto.systemWatchBigFileGB, range: 0.5...50, step: 0.5) { String(format: "%.1f GB", $0).replacingOccurrences(of: ".", with: ",") } }
                    SettingRow(title: T("Mierz co"), subtitle: T("Pomiar trwa kilka minut, w tle, z niskim priorytetem")) {
                        ValueStepper(value: $prefs.auto.systemWatchIntervalHours, range: 6...168, step: 6) { "\(Int($0)) h" }
                    }
                }
            }
            FeatureRow(symbol: "calendar", color: FeatureColor.weekly, title: T("Tygodniowy przegląd"),
                       subtitle: T("Raz w tygodniu: ile zajmują pliki generowane FCP i ile jest wolnego miejsca na dyskach."), isOn: ruleBinding(\.weeklyReportEnabled))
        }
    }

    // MARK: Skanowanie

    var scanning: some View {
        Group {
            SectionCard(title: T("Duplikaty")) {
                SettingRow(title: T("Pomijaj pliki mniejsze niż")) {
                    Picker("", selection: $prefs.minSizeMB) {
                        Text("100 KB").tag(0.1); Text("1 MB").tag(1.0); Text("10 MB").tag(10.0); Text("100 MB").tag(100.0); Text("1 GB").tag(1000.0)
                    }.labelsHidden().fixedSize()
                }
                Divider()
                SwitchRow(title: T("Tryb szybki"), subtitle: T("Porównuje tylko fragmenty plików — dużo szybciej na dyskach USB, wynik „prawie na pewno”"), isOn: $prefs.quickMode)
                Divider()
                SwitchRow(title: T("Wchodź do podfolderów"), subtitle: T("Wyłączone — tylko pliki leżące bezpośrednio w wybranych folderach"), isOn: $prefs.includeSubfolders)
                Divider()
                SwitchRow(title: T("Uwzględniaj ukryte pliki i foldery"), isOn: $prefs.includeHidden)
            }
            SectionCard(title: "Backup") {
                SwitchRow(title: T("Sprawdzaj całą zawartość plików"), subtitle: T("Zalecane, jeśli potem kasujesz kartę"), isOn: $prefs.backupVerify)
            }
            SectionCard(title: "iCloud", footer: T("Pliki z Biurka i Dokumentów, które macOS trzyma tylko w iCloud, są zawsze pomijane — ich odczyt wymusiłby pobieranie na dysk. Pominięte widzisz w trakcie skanu („Pominięto…”).")) {
                Label(T("Pomijam pliki niepobrane z iCloud"), systemImage: "icloud.slash").font(.system(size: 12))
            }
            SectionCard(title: T("Pamięć wyników"), footer: T("Drugi skan tych samych dysków nie czyta niezmienionych plików od nowa.")) {
                SwitchRow(title: T("Zapamiętuj odciski plików"), isOn: $prefs.useCache)
                Divider()
                SettingRow(title: T("Zapamiętane pliki: %@", "\(app.cache.count)")) {
                    Button(cacheCleared ? T("Wyczyszczono") : T("Wyczyść")) { app.resetCache(); cacheCleared = true }.disabled(cacheCleared)
                }
            }
        }
    }

    // MARK: Wykluczenia

    var exclusions: some View {
        Group {
            SectionCard(title: T("Pomijane foldery")) {
                if prefs.excludedPaths.isEmpty {
                    Text(T("Brak — skanowane jest wszystko w wybranych miejscach.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(prefs.excludedPaths, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text(Fmt.path(p)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { prefs.excludedPaths.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel(T("Usuń wykluczenie")).help(T("Usuń wykluczenie"))
                    }
                }
                Button(T("Dodaj folder…")) {
                    prefs.excludedPaths += FileActions.chooseFolder(title: T("Foldery, do których DupliKAT ma nie zaglądać"), prompt: T("Wyklucz"), multiple: true).map(\.path).filter { !prefs.excludedPaths.contains($0) }
                }.controlSize(.small)
            }
            SectionCard(title: T("Zawsze chronione")) {
                Text(T("Biblioteki Final Cut (.fcpbundle) i ich cache, foldery proxy/optimized FCP, szablony Motion, kopie zapasowe FCP; foldery podglądów, autozapisu i cache Premiere Pro; bazy projektów, cache i proxy DaVinci Resolve; biblioteka Zdjęć, aplikacje, projekty Xcode i Logic. Usunięcie „duplikatu” z ich wnętrza zepsułoby bibliotekę albo szablon."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func ruleBinding(_ kp: WritableKeyPath<Automation, Bool>) -> Binding<Bool> {
        Binding(get: { prefs.auto[keyPath: kp] }, set: { prefs.auto[keyPath: kp] = $0; if $0 { Notifier.request() } })
    }
}

/// Dyski: model/prędkość, własne opisy, role w obiegu karta → M → M2 i zapamiętana zawartość odłączonych dysków.
struct DrivesSettings: View {
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var app: AppModel

    var body: some View {
        Group {
            SectionCard(title: T("Dyski i karty"), footer: T("Model i prędkość łącza czytam z systemu (jak Informacje o systemie). Prędkość łącza to maksimum kabla/portu — realny transfer zależy też od dysku. Opis zmienisz też prawym przyciskiem na dysku.")) {
                SwitchRow(title: T("Pokazuj model i prędkość łącza"), subtitle: T("Pod nazwą dysku w oknie i w okienku przy pasku menu"), isOn: $prefs.auto.showDriveDetails)
                ForEach(app.volumes) { v in
                    Divider()
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(v.name).font(.system(size: 12.5, weight: .medium))
                            Text(DriveText.detail(v, prefs) ?? T("brak danych o dysku")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !v.isCard && v.url.path != "/" { DriveRoleMenu(key: v.key, memory: app.drives) }
                        Button(T("Zmień opis…")) { DriveText.rename(v, prefs) }.controlSize(.small)
                    }
                }
            }
            SectionCard(title: T("Backupy i ich kopie"), footer: T("Oznacz dyski, na które zgrywasz materiał (karty, eksporty, projekty), jako „backup”, a dyski z ich kopiami jako „kopia backupu …”. Backupów i kopii może być kilka (np. Backup 1 → Kopia 1, Backup 2 → Kopia 2). Wtedy przy każdym pliku widać, na ilu dyskach jest, a pliki z backupu bez kopii „czekają na kopię” zamiast świecić na czerwono. Po podłączeniu obu dysków DupliKAT policzy, co dograć — z zachowaniem folderów.")) {
                SwitchRow(title: T("Pamiętaj zawartość dysków"), subtitle: T("Lista plików (bez treści) — wiem o kopiach także na odłączonych dyskach"), isOn: $prefs.auto.rememberDrives)
                let offline = app.drives.catalogs.values.filter { !app.drives.isMounted($0.key) }.sorted { $0.name < $1.name }
                ForEach(offline, id: \.key) { c in
                    Divider()
                    HStack {
                        Image(systemName: "externaldrive.badge.xmark").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.system(size: 12.5, weight: .medium))
                            Text(T("odłączony · %@ · stan z %@", "\(Fmt.files(c.items.count))", "\(Fmt.date.string(from: c.date))")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        DriveRoleMenu(key: c.key, memory: app.drives)
                        Button(T("Zapomnij")) { app.drives.forget(c.key) }.controlSize(.small)
                            .help(T("Usuwa tylko zapamiętaną listę plików w DupliKAT — nie dotyka dysku"))
                    }
                }
                ForEach(app.drives.allPending, id: \.ingest) { p in
                    Divider()
                    PendingBackupRow(p: p, memory: app.drives)
                }
            }
        }
    }
}
