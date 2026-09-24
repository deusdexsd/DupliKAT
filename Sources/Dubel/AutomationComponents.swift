import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Kolory funkcji automatycznych — każda ma swój, stały (zasada z MidniteUIKit: osobny kolor dla osobnej rzeczy).
enum FeatureColor {
    static let card = Color(nsColor: .systemBlue)
    static let volume = Color(nsColor: .systemTeal)
    static let pair = Color(nsColor: .systemIndigo)
    static let space = Color(nsColor: .systemRed)
    static let system = Color(nsColor: .systemPurple)
    static let weekly = Color(nsColor: .systemGreen)
}

/// Wybór dysków do sprawdzania po podłączeniu (chipy: podłączone teraz + zapamiętane).
struct VolumeChips: View {
    @Binding var selected: [String]
    @EnvironmentObject var app: AppModel

    var body: some View {
        let names = Array(Set(app.volumes.filter { $0.url.path != "/" && !$0.isCard }.map(\.name) + selected)).sorted()
        if names.isEmpty {
            Text("Podłącz dysk zewnętrzny, żeby go tu wybrać.").font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(names, id: \.self) { n in
                    let on = selected.contains(n)
                    Button { if on { selected.removeAll { $0 == n } } else { selected.append(n) } } label: {
                        Label(n, systemImage: on ? "checkmark.circle.fill" : "externaldrive")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(on ? FeatureColor.volume.opacity(0.2) : Color.primary.opacity(0.06)))
                            .overlay(Capsule().strokeBorder(on ? FeatureColor.volume.opacity(0.6) : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Podgląd wzoru nazwy folderu: „{data} {karta}” → „2026-09-24 SONY A7”.
struct TemplateField: View {
    @Binding var template: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Nazwa folderu").font(.system(size: 11.5))
                TextField("{data} {karta}", text: $template).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced)).frame(maxWidth: 220)
            }
            Text("np. „\(CameraCard.folderName(template: template, cardName: "SONY A7"))” · dostępne: {data} {rok} {miesiac} {dzien} {karta}")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

/// Gdzie szukać kopii plików z karty: automatycznie (wszystkie podłączone dyski + typowe foldery) albo własna lista.
struct SearchLocationsEditor: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let auto = prefs.auto.searchLocations.isEmpty
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { auto }, set: { a in
                if a { prefs.auto.searchLocations = [] }
                else if prefs.auto.searchLocations.isEmpty { prefs.auto.searchLocations = prefs.auto.copySearchRoots(excluding: nil).map(\.path) }
            })) {
                Text("Wszędzie (automatycznie)").tag(true)
                Text("Tylko wybrane miejsca").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if auto {
                Text("Wszystkie podłączone dyski (poza samą kartą) + Filmy, Obrazy, Biurko i Pobrane. Teraz: " +
                     prefs.auto.copySearchRoots(excluding: nil).map { Fmt.path($0.path) }.joined(separator: ", "))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(prefs.auto.searchLocations, id: \.self) { p in
                    HStack {
                        Image(systemName: p.hasPrefix("/Volumes/") ? "externaldrive" : "folder").foregroundStyle(.secondary)
                        Text(Fmt.path(p)).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        if !FileManager.default.fileExists(atPath: p) { Text("niepodłączony").font(.system(size: 10.5)).foregroundStyle(Theme.warn) }
                        Spacer()
                        Button { prefs.auto.searchLocations.removeAll { $0 == p } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Usuń").help("Usuń z listy")
                    }
                }
                Button { prefs.auto.searchLocations += FileActions.chooseFolder(title: "Gdzie szukać kopii?", prompt: "Dodaj", multiple: true).map(\.path).filter { !prefs.auto.searchLocations.contains($0) } } label: {
                    Label("Dodaj dysk lub folder…", systemImage: "plus")
                }.controlSize(.small)
            }
        }
    }
}

/// Co zrobić po automatycznym sprawdzeniu karty.
struct CardAfterCheckPicker: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Gdy czegoś nie ma nigdzie:").font(.system(size: 12, weight: .medium))
            Picker("", selection: $prefs.auto.cardAfterCheck) {
                Text("Tylko pokaż").tag("show")
                Text("Zapytaj, czy skopiować").tag("ask")
                Text("Kopiuj automatycznie").tag("auto")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if prefs.auto.cardAfterCheck != "show" {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(prefs.auto.cardAutoFolder.map { Fmt.path($0) } ?? "Wybierz folder, do którego kopiować…")
                        .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(prefs.auto.cardAutoFolder == nil ? Theme.warn : .primary)
                    Spacer()
                    Button("Wybierz…") {
                        if let u = FileActions.chooseFolder(title: "Dokąd kopiować brakujące pliki z kart?", prompt: "Wybierz").first { prefs.auto.cardAutoFolder = u.path }
                    }.controlSize(.small)
                }
                Text(prefs.auto.cardAfterCheck == "auto"
                     ? "Kopiuje tylko to, czego nie ma nigdzie, do folderu z nazwą karty. Niczego nie usuwa ani nie nadpisuje, każdą kopię sprawdza bajt po bajcie. Dostaniesz powiadomienie z wynikiem."
                     : "Po sprawdzeniu pokażę okno z listą brakujących plików i pytaniem, czy skopiować je do tego folderu.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Jak sprawdzać kartę: tylko media, minimalny rozmiar, szybko / bajt po bajcie. Zmiana w oknie karty od razu sprawdza ponownie.
struct CardScanOptions: View {
    var onChange: (() -> Void)? = nil
    var disabled = false
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        HStack(spacing: 14) {
            Toggle("Tylko zdjęcia, wideo i audio", isOn: bind(\.cardMediaOnly))
                .help("Pomija pliki pomocnicze aparatu: XML, bazę karty, miniatury. Na kartach Sony to setki małych plików.")
            Picker("Pomijaj mniejsze niż", selection: bind(\.cardMinSizeMB)) {
                Text("—").tag(0.0); Text("100 KB").tag(0.1); Text("1 MB").tag(1.0); Text("10 MB").tag(10.0)
            }
            .fixedSize()
            Toggle("Bajt po bajcie", isOn: bind(\.cardExact))
                .help("Wolno przez USB — czyta całe pliki z karty i z archiwum. Wyłączone: rozmiar + fragmenty z początku, środka i końca (przy wideo praktycznie pewne).")
        }
        .toggleStyle(.checkbox)
        .font(.system(size: 11.5))
        .controlSize(.small)
        .disabled(disabled)
    }

    private func bind<T: Equatable>(_ kp: WritableKeyPath<Automation, T>) -> Binding<T> {
        Binding(get: { prefs.auto[keyPath: kp] }, set: { v in
            guard prefs.auto[keyPath: kp] != v else { return }
            prefs.auto[keyPath: kp] = v
            onChange?()
        })
    }
}
