import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Przewodnik pierwszego uruchomienia: 5 kroków, wszystko da się potem zmienić w Ustawieniach.
/// Ustawienia zapisują się od razu (bez osobnego „Zapisz”), więc zamknięcie w połowie niczego nie gubi.
struct OnboardingView: View {
    let onFinish: () -> Void
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var app: AppModel
    @State private var step = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let count = 7

    var body: some View {
        OnboardingScaffold(step: $step, count: count,
                           nextTitle: { $0 == count - 1 ? T("Zaczynamy") : $0 == 1 ? T("Ustawmy to") : T("Dalej") },
                           onFinish: onFinish, onSkip: onFinish) { i in page(i) }
            .background(Color(nsColor: .windowBackgroundColor))
            .frame(width: 760, height: 680)
            .onReceive(NotificationCenter.default.publisher(for: .dubelOnboardingStep)) { n in if let i = n.object as? Int { step = i } }
    }

    @ViewBuilder func page(_ i: Int) -> some View {
        switch i {
        case 0: language
        case 1: welcome
        case 2: card
        case 3: rules
        case 4: looks
        case 5: presence
        default: summary
        }
    }

    // MARK: Kroki

    func header(_ symbol: String, _ color: Color, _ title: String, _ sub: String) -> some View {
        OnboardingHeader(symbol: symbol, color: color, title: title, subtitle: sub)
    }

    /// Krok 0: język. Dwujęzyczny nagłówek, bo jeszcze nie wiemy, który wybierzesz.
    var language: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 0)
            OnboardingHeader(symbol: "globe", color: Theme.accent.primary, title: "Wybierz język · Choose your language",
                             subtitle: "Możesz go później zmienić w Ustawieniach. · You can change it later in Settings.")
            HStack(spacing: 14) {
                ChoiceTile(symbol: "character.bubble", title: "Polski", subtitle: "interfejs po polsku", selected: prefs.auto.language == "pl") {
                    (NSApp.delegate as? AppDelegate)?.setLanguage("pl")
                }
                ChoiceTile(symbol: "character.bubble", title: "English", subtitle: "English interface", selected: prefs.auto.language == "en") {
                    (NSApp.delegate as? AppDelegate)?.setLanguage("en")
                }
            }
            .frame(maxWidth: 460)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
    }

    var welcome: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 0)
            if let img = AppIconChoice.current(prefs.auto.appIcon).image {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: 120, height: 120)
                    .shadow(color: Theme.accent.primary.opacity(0.35), radius: 24, y: 8)
            } else { AppLogo(size: 104) }
            VStack(spacing: 8) {
                Text(T("Cześć, tu %@", "\(AppInfo.name)")).font(.system(size: 28, weight: .bold))
                Text(T("Pilnuję porządku na Twoich dyskach: duplikaty, zgrywanie kart, rendery Final Cut i to, co po cichu zjada miejsce."))
                    .font(.system(size: 13.5)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
            }
            VStack(alignment: .leading, spacing: 12) {
                promise("hand.raised.fill", Theme.accent.primary, T("Niczego nie robię sam"), T("Automatycznie tylko czytam i pytam. Każdą zmianę na dysku potwierdzasz, widząc listę plików."))
                promise("film.fill", FeatureColor.card, T("Biblioteki i projekty montażowe są bezpieczne"), T("Nie ruszam wnętrza bibliotek Final Cut, folderów roboczych Premiere Pro ani baz i cache DaVinci Resolve."))
                promise("icloud.slash.fill", FeatureColor.system, T("Nie ściągam plików z iCloud"), T("Pliki trzymane tylko w chmurze pomijam i pokazuję, co pominąłem."))
            }
            .frame(maxWidth: 500)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    func promise(_ s: String, _ c: Color, _ t: String, _ d: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            IconCircle(symbol: s, color: c, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 13, weight: .semibold))
                Text(d).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var card: some View {
        VStack(spacing: 18) {
            header("sdcard.fill", FeatureColor.card, T("Karta z aparatu"), T("Podłączasz kartę, a ja pokazuję, co z niej jest już zgrane i gdzie — i czego nie ma nigdzie. Ty wybierasz pliki i decydujesz, gdzie je skopiować albo przenieść."))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CardPreview()
                    FeatureRow(symbol: "sdcard.fill", color: FeatureColor.card, title: T("Sprawdzaj kartę od razu po podłączeniu"),
                               subtitle: T("Otworzę okno z wynikiem sam. Wyłączone — sprawdzisz ręcznie z menu albo z okna."), isOn: $prefs.auto.cardImportEnabled) {
                        CardAfterCheckPicker()
                    }
                    Card(padding: 14, radius: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(T("Gdzie szukać kopii")).font(.system(size: 13, weight: .semibold))
                            SearchLocationsEditor()
                        }
                    }
                    Card(padding: 14, radius: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(T("Co sprawdzać na karcie")).font(.system(size: 13, weight: .semibold))
                            CardScanOptions()
                        }
                    }
                    Card(padding: 14, radius: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle(T("Sprawdzaj kopie bajt po bajcie (zalecane)"), isOn: $prefs.auto.verifyCopies)
                            Toggle(T("Gdy wszystko z karty jest zgrane, zapytaj o formatowanie (otworzę systemowe Narzędzie dyskowe — sam nie formatuję)"), isOn: $prefs.auto.askFormatAfterImport)
                        }
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
                .padding(.horizontal, 60).padding(.bottom, 12)
            }
        }
    }

    var rules: some View {
        VStack(spacing: 18) {
            header("bolt.fill", Theme.accent.primary, T("Co jeszcze mam robić sam?"), T("Wszystko opcjonalne i domyślnie wyłączone. Włączone reguły tylko liczą i pytają — nigdy nie kasują."))
            ScrollView {
                VStack(spacing: 10) {
                    FeatureRow(symbol: "externaldrive.fill.badge.checkmark", color: FeatureColor.volume, title: T("Dysk podłączony → sprawdź duplikaty"),
                               subtitle: T("Wybierz dyski — po podłączeniu przeskanuję je (tylko odczyt) i dam znać, co znalazłem."),
                               isOn: Binding(get: { !prefs.auto.checkVolumesOnMount.isEmpty || volumesOpen }, set: { v in volumesOpen = v; if !v { prefs.auto.checkVolumesOnMount = [] } })) {
                        VolumeChips(selected: $prefs.auto.checkVolumesOnMount)
                    }
                    FeatureRow(symbol: "exclamationmark.triangle.fill", color: FeatureColor.space, title: T("Alarm zajętego miejsca"),
                               subtitle: T("Powiadomię, gdy dysk przekroczy próg — i podpowiem, co zajmuje miejsce."), isOn: $prefs.auto.spaceAlarmEnabled) {
                        SettingRow(title: T("Próg")) { ValueStepper(value: $prefs.auto.spaceAlarmPercent, range: 50...99, step: 1) { "\(Int($0))%" } }
                    }
                    FeatureRow(symbol: "gauge.with.dots.needle.67percent", color: FeatureColor.system, title: T("Pilnuj danych systemowych"),
                               subtitle: T("Cache, symulatory, kopie iPhone'a… Dam znać, gdy coś nagle urośnie albo pojawi się duży plik nieznanego pochodzenia."), isOn: $prefs.auto.systemWatchEnabled) {
                        SettingRow(title: T("Alarm, gdy urośnie o")) { ValueStepper(value: $prefs.auto.systemWatchGrowthGB, range: 1...100, step: 1) { "\(Int($0)) GB" } }
                    }
                    FeatureRow(symbol: "calendar", color: FeatureColor.weekly, title: T("Tygodniowy przegląd"),
                               subtitle: T("Raz w tygodniu: ile zajmują rendery FCP i ile masz wolnego miejsca."), isOn: $prefs.auto.weeklyReportEnabled)
                }
                .padding(.horizontal, 60).padding(.bottom, 24)
            }
        }
    }
    @State private var volumesOpen = false

    var looks: some View {
        VStack(spacing: 22) {
            header("paintbrush.fill", Theme.accent.secondary, T("Jak mam wyglądać?"), T("Wybierz ikonę aplikacji i ikonę do paska menu. Zmienisz je później w Ustawieniach."))
            VStack(alignment: .leading, spacing: 8) {
                Caption(T("Ikona aplikacji"))
                AppIconPicker(selection: $prefs.auto.appIcon)
            }
            VStack(alignment: .leading, spacing: 8) {
                Caption(T("Ikona w pasku menu"))
                MenuBarIconPicker(selection: $prefs.auto.menuBarIcon).frame(maxWidth: 560)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
    }

    var presence: some View {
        VStack(spacing: 22) {
            header("menubar.rectangle", Theme.accent.secondary, T("Gdzie mam mieszkać?"), T("Żeby reguły działały, gdy podłączysz kartę, muszę być uruchomiony. Najwygodniej jako mała ikona przy zegarze."))
            HStack(spacing: 12) {
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
            .frame(maxWidth: 560)
            if prefs.auto.showMenuBarIcon {
                HStack(spacing: 16) {
                    MenuBarPreview()
                    VStack(alignment: .leading, spacing: 4) {
                        Label(T("Lewy przycisk — otwiera okno"), systemImage: "cursorarrow.click")
                        Label(T("Prawy przycisk — menu z regułami i ustawieniami"), systemImage: "cursorarrow.click.2")
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Toggle(T("Uruchamiaj przy logowaniu"), isOn: $prefs.auto.launchAtLogin).toggleStyle(.switch).tint(Theme.accent.primary).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
    }

    var summary: some View {
        let a = prefs.auto
        let items: [(String, Color, String, Bool)] = [
            ("sdcard.fill", FeatureColor.card, T("Karta podłączona → pokaż, co jest zgrane i gdzie"), a.cardImportEnabled),
            ("magnifyingglass", FeatureColor.card, a.searchLocations.isEmpty ? T("Kopii szukam wszędzie (wszystkie dyski + Filmy, Obrazy, Biurko, Pobrane)") : T("Kopii szukam w: ") + a.searchLocations.map { Fmt.path($0) }.joined(separator: ", "), true),
            ("externaldrive.fill.badge.checkmark", FeatureColor.volume, a.checkVolumesOnMount.isEmpty ? T("Sprawdzanie dysków po podłączeniu") : T("Sprawdzam po podłączeniu: ") + a.checkVolumesOnMount.joined(separator: ", "), !a.checkVolumesOnMount.isEmpty),
            ("exclamationmark.triangle.fill", FeatureColor.space, T("Alarm miejsca od %@%", "\(Int(a.spaceAlarmPercent))"), a.spaceAlarmEnabled),
            ("gauge.with.dots.needle.67percent", FeatureColor.system, T("Pilnowanie danych systemowych"), a.systemWatchEnabled),
            ("calendar", FeatureColor.weekly, T("Tygodniowy przegląd"), a.weeklyReportEnabled),
            ("menubar.rectangle", Theme.accent.secondary, (a.showMenuBarIcon ? (a.showInDock ? T("Pasek menu i Dock") : T("Tylko pasek menu")) : T("Tylko okno")) + " · ikona: \(AppIconChoice.current(a.appIcon).title)", true),
        ]
        return VStack(spacing: 18) {
            header("checkmark", Theme.safe, T("Gotowe"), T("Oto Twoje ustawienia. Na koniec wybierz wygląd okna — wszystko zmienisz w Ustawieniach (⌘,)."))
            UIStylePicker(selection: $prefs.auto.uiStyle).frame(maxWidth: 540)
            Card(padding: 16, radius: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack(spacing: 10) {
                            IconCircle(symbol: items[i].0, color: items[i].1, on: items[i].3, size: 26)
                            Text(items[i].2).font(.system(size: 12.5)).foregroundStyle(items[i].3 ? .primary : .secondary)
                            Spacer()
                            Image(systemName: items[i].3 ? "checkmark.circle.fill" : "circle").foregroundStyle(items[i].3 ? Theme.safe : Color.secondary.opacity(0.5))
                        }
                    }
                }
            }
            .frame(maxWidth: 540)
            if a.anyRuleEnabled {
                Text(T("Na koniec macOS zapyta o zgodę na powiadomienia — przez nie daję znać o wynikach reguł."))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
    }
}

/// Mały podgląd paska menu z ikoną Dubla.
struct MenuBarPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi")
            Image(systemName: "doc.on.doc").padding(4).background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.14)))
            Image(systemName: "battery.75percent")
            Text("12:34").monospacedDigit()
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Logo Dubla rysowane w SwiftUI (ikona .icns w ciemnym motywie macOS 26 bywa przyciemniana przez system).
struct AppLogo: View {
    var size: CGFloat = 96
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous).fill(Theme.accent.gradient)
            Image(systemName: "doc.on.doc.fill").font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.secondary.opacity(0.35), radius: size * 0.2, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

/// Mały podgląd tego, co zobaczysz po podłączeniu karty.
struct CardPreview: View {
    var body: some View {
        HStack(spacing: 12) {
            previewTile(value: "412", label: T("zgrane"), sub: T("M ▸ BACKUP KART/karta 3"), color: Theme.safe, symbol: "checkmark.circle.fill")
            previewTile(value: "37", label: T("nie ma nigdzie"), sub: T("zaznacz → Skopiuj / Przenieś do…"), color: Theme.missing, symbol: "xmark.circle.fill")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(T("Przykład: 412 plików zgranych, 37 bez kopii"))
    }

    func previewTile(value: String, label: String, sub: String, color: Color, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text(label).font(.system(size: 12, weight: .medium))
                }
                Text(sub).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.3)))
    }
}

/// Wybór stylu interfejsu: „jak przewodnik” (poświata, kolorowe ikony trybów) albo klasyczny, natywny.
struct UIStylePicker: View {
    @Binding var selection: String
    var body: some View {
        HStack(spacing: 12) {
            ChoiceTile(symbol: "sparkles", title: T("Jak przewodnik"), subtitle: T("poświata, kolorowe ikony trybów"), selected: selection != "classic") { selection = "rich" }
            ChoiceTile(symbol: "macwindow", title: T("Klasyczny"), subtitle: T("stonowany, jak natywne aplikacje"), selected: selection == "classic") { selection = "classic" }
        }
    }
}
