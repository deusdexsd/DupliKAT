# MidniteUIKit

Komponenty UI wyjęte z Ogara, ogólne (nie znają Ogara), gotowe do wklejenia jako lokalna zależność w innym projekcie —
Papla, MidniteDock, SnapCaps, cokolwiek następnego. Działa na macOS 13+ i iOS 16+ (czyste SwiftUI, bez AppKit).

## Jak dodać do projektu

**Xcode:** File → Add Package Dependencies… → Add Local… → wskaż ten folder.
**SwiftPM (Package.swift):** `.package(path: "../MidniteUIKit")` w `dependencies`, `"MidniteUIKit"` w `dependencies` targetu.

```swift
import MidniteUIKit
```

## Zasada nr 1: jeden akcent, reszta to system

Nie ustawiaj własnych kolorów tła, ramek czy tekstu — wszystkie karty i kontrolki używają `Color.primary.opacity(...)`,
więc jasny/ciemny tryb działają same, za darmo. Jedyny kolor, który wybierasz, to **akcent marki**: dwa odcienie,
z których buduje się gradient używany w przyciskach, zakładkach i pierścieniach.

```swift
ContentView()
    .midniteAccent(.purple, .teal)   // albo AccentPalette(primary:secondary:)
```

Ustaw to raz, na najwyższym widoku. Każdy komponent poniżej czyta go z environment.

## Zasada nr 2: osobny kolor dla osobnej metryki

To była poprawka, którą dostał Ogar: jeśli pokazujesz kilka pierścieni/liczników obok siebie (jak w Aplikacji
Zdrowie — Ruch, Ćwiczenie, Stanie, każdy innym kolorem), **nie** używaj do wszystkich gradientu akcentu marki.
Zlewają się w jedną plamę i nie da się ich rozróżnić kątem oka. Zamiast tego:

- Akcent marki (`midniteAccent`) zarezerwuj dla **głównej metryki** (ta jedna duża liczba na ekranie) i dla
  przycisków/zakładek — to on tworzy tożsamość aplikacji.
- Każda **drugorzędna metryka** (osobny pierścień, osobna karta postępu) dostaje **swój własny, ustalony kolor**,
  niezależny od `midniteAccent`. W Ogarze: wzrok = niebieski, ruch = zielony, posiłek = pomarańczowy, przekroczony
  limit = czerwony — zawsze, w każdym motywie.
- Trzymaj te kolory w jednym miejscu (`enum Theme` w danym projekcie), nie w komponencie: `Ring` i `NextTile`-podobne
  widoki przyjmują gradient jako parametr, nie mają go zaszytego.

```swift
enum Theme {
    static let eye = LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let move = LinearGradient(colors: [.green, Color(red: 0.55, green: 0.85, blue: 0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

Ring(progress: eyeProgress, gradient: Theme.eye)
Ring(progress: moveProgress, gradient: Theme.move)
```

Kolor marki (`midniteAccent`) i kolor ostrzeżenia (zwykle czerwień, niezależna od reszty) są jedynymi kolorami,
które powtarzają się w wielu miejscach na raz — reszta metryk ma swój jeden, stały kolor.

## Katalog komponentów

| Komponent | Do czego | Przykład |
|---|---|---|
| `Card` | Podstawowa karta na dowolną treść | `Card { Text("Cześć") }` |
| `Caption` | Mały nagłówek sekcji, WERSALIKAMI | `Caption("Dziś")` |
| `SectionCard` | Nagłówek + karta + opis pod spodem — budulec ekranu ustawień | `SectionCard(title: "Przerwy", footer: "...") { ... }` |
| `Ring` | Pierścień postępu (patrz zasada nr 2 wyżej) | `Ring(progress: 0.6, lineWidth: 10, gradient: Theme.eye)` |
| `PillTabs` | Zakładki-pigułki z jeżdżącym podświetleniem | `PillTabs(items: [(Tab.a, "A", nil)], selection: $tab)` |
| `SettingRow` | Wiersz: tytuł po lewej, kontrolka po prawej | `SettingRow(title: "Interwał") { Stepper(...) }` |
| `SwitchRow` | `SettingRow` z gotowym przełącznikiem | `SwitchRow(title: "Włącz", isOn: $on)` |
| `ValueStepper` | Stepper w pigułce: `− 20 min +` | `ValueStepper(value: $v, range: 1...60, step: 1) { "\(Int($0)) min" }` |
| `GradientButtonStyle` | Przycisk w akcencie marki albo cichy | `.buttonStyle(GradientButtonStyle(prominent: true))` |
| `FlowLayout` | Zawijane chipy/tagi zamiast przewijania w poziomie | `FlowLayout(spacing: 6) { ForEach(tags) { ... } }` |
| `OnboardingScaffold` | Przewodnik pierwszego uruchomienia: poświata, kropki, przejścia, Wstecz/Dalej/Pomiń | `OnboardingScaffold(step: $s, count: 5, onFinish: done) { i in ... }` |
| `OnboardingHeader` | Duża ikona z poświatą + tytuł + opis kroku | `OnboardingHeader(symbol: "bolt.fill", color: .pink, title: "…", subtitle: "…")` |
| `FeatureRow` | Wiersz funkcji: kolorowa ikona, opis, przełącznik, szczegóły po włączeniu | `FeatureRow(symbol: "bell", color: .red, title: "Alarm", subtitle: "…", isOn: $on) { ... }` |
| `ChoiceTile` | Kafelek wyboru jednej z kilku opcji | `ChoiceTile(symbol: "menubar.rectangle", title: "Pasek menu", selected: x) { ... }` |
| `IconCircle`, `StepDots`, `AccentGlow` | Kolorowe kółko z symbolem, kropki kroków, poświata marki | `IconCircle(symbol: "sdcard", color: .blue)` |
| `.coachAnchor` + `.coachMarks` | Samouczek „co jest co”: przyciemnienie, podświetlenie elementu, dymek | `view.coachAnchor("x")`, `root.coachMarks(steps, isPresented: $on)` |

Pełny wzorzec przewodnika (kolejność kroków, zasady, kod): `Projects/Poradnik – przewodnik pierwszego uruchomienia.html`.

Czego tu **nie ma** (bo są specyficzne dla aplikacji, nie dla UI): ikony aplikacji z NSWorkspace, odtwarzacz
dźwięków, kontroler nakładki na ekranie. Te zostają w projekcie źródłowym i kopiuje się je ręcznie, jeśli pasują.

## Pozostałe nawyki z Ogara, warte powtórzenia

- **Zaokrąglenie 14 pt** na kartach, **Capsule** (pełne zaokrąglenie) na przyciskach i polach liczbowych.
- **SF Symbols** wszędzie, nigdy własne ikony do prostych rzeczy typu strzałka czy przełącznik.
- **`.monospacedDigit()`** na każdej liczbie, która się zmienia (czas, minuty, procenty) — bez tego tekst "skacze"
  przy każdej aktualizacji.
- **Renderuj widoki do PNG zamiast zgadywać jak wyglądają**: `NSHostingView` + `bitmapImageRepForCachingDisplay`,
  osobno dla jasnego i ciemnego trybu, z `environment(\.colorScheme, ...)`. Wzorzec jest w `DevSupport.swift` w
  Ogarze — działa bez żadnych uprawnień do nagrywania ekranu i bez klikania w prawdziwą aplikację.
- **Ustawienia w jednym `Codable` structcie** z ręcznym `init(from:)`, który dla brakującego klucza bierze wartość
  domyślną zamiast wysypać cały odczyt. Dzięki temu dodanie nowego ustawienia w kolejnej wersji nie kasuje
  starych, zapisanych danych użytkownika.

## Skąd to jest

Wyjęte z `Projects/Ogar` 2026-09-22, po tym jak David zauważył, że wszystkie pierścienie i kafelki w jednym
kolorze się zlewają. Kolory tu nie ma celowo — to inny wybór w każdej aplikacji, patrz zasada nr 2.
