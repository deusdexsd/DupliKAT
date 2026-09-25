import AppKit
import DubelCore
import MidniteUIKit
import QuickLook
import SwiftUI

/// Ekran duplikatów / podobnych zdjęć / podobnego wideo i audio.
struct GroupsScreen: View {
    @ObservedObject var model: GroupScanModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs

    /// Po wynikach górna część się zwija do jednego wiersza — wyniki dostają resztę okna.
    @State private var showSetup = false
    var hasResults: Bool { !model.groups.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            if hasResults && !showSetup {
                VStack(alignment: .leading, spacing: 10) {
                    compactTop
                    if case .running(let p) = model.status { ProgressCard(progress: p, log: model.log) { model.cancel() } }
                }
                .padding(.horizontal, 20).padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    ModeHeader(mode: model.mode) {
                        HStack(spacing: 10) {
                            StatusFooter(status: model.status, log: model.log)
                            if hasResults {
                                Button { withAnimation(.snappy) { showSetup = false } } label: { Label(T("Zwiń"), systemImage: "chevron.up") }
                                    .controlSize(.small).help(T("Schowaj ustawienia skanu — więcej miejsca na wyniki"))
                            }
                        }
                    }
                    LocationsCard(title: T("Gdzie szukać"), urls: $model.roots)
                    options
                    if case .running(let p) = model.status { ProgressCard(progress: p, log: model.log) { model.cancel() } }
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            }

            Divider()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.groups.isEmpty { ActionBar(model: model) }
        }
        .onChange(of: model.status.isRunning) { _, running in if running { showSetup = false } }
    }

    /// Jeden wiersz zamiast nagłówka, miejsc i opcji: „Duplikaty w: Downloads · Zmień … Szukaj”.
    var compactTop: some View {
        HStack(spacing: 10) {
            IconCircle(symbol: model.mode.symbol, color: model.mode.color, size: 26)
            Text(model.mode.title).font(.system(size: 15, weight: .bold))
            Text(T("w: %@", "\(model.roots.map(\.lastPathComponent).joined(separator: ", "))"))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Button(T("Zmień…")) { withAnimation(.snappy) { showSetup = true } }.buttonStyle(.borderless).font(.system(size: 12))
                .help(T("Pokaż miejsca i opcje skanu"))
            StatusFooter(status: model.status, log: model.log)
            options
        }
    }

    @ViewBuilder var options: some View {
        HStack(spacing: 14) {
            switch model.mode {
            case .duplicates:
                Menu {
                    ForEach(MediaKind.allCases) { k in
                        Toggle(isOn: Binding(get: { model.kinds.contains(k) }, set: { on in if on { model.kinds.insert(k) } else if model.kinds.count > 1 { model.kinds.remove(k) } })) {
                            Label(k.title, systemImage: k.symbol)
                        }
                    }
                } label: {
                    Text(model.kinds.count == MediaKind.allCases.count ? T("Wszystkie rodzaje plików") : model.kinds.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))
                }
                .fixedSize()
                Toggle(T("Tryb szybki"), isOn: $prefs.quickMode)
                    .help(T("Porównuje tylko fragmenty z początku, środka i końca pliku. Dużo szybciej na dyskach USB, wynik „prawie na pewno”."))
            case .photos:
                Picker(T("Czułość"), selection: $prefs.photoSensitivity) { ForEach(Sensitivity.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Text(prefs.photoSensitivity.photoHint()).font(.system(size: 11)).foregroundStyle(.secondary)
            case .media:
                Toggle(T("Wideo"), isOn: kindBinding(.video))
                Toggle("Audio", isOn: kindBinding(.audio))
                Picker(T("Czułość"), selection: $prefs.mediaSensitivity) { ForEach(Sensitivity.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Text(prefs.mediaSensitivity.mediaHint()).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            default: EmptyView()
            }
            Spacer(minLength: 8)
            ScanButton(title: T("Szukaj"), enabled: !model.roots.isEmpty && !model.status.isRunning) { model.start() }
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    func kindBinding(_ k: MediaKind) -> Binding<Bool> {
        Binding(get: { model.mediaKinds.contains(k) }, set: { on in if on { model.mediaKinds.insert(k) } else if model.mediaKinds.count > 1 { model.mediaKinds.remove(k) } })
    }

    @ViewBuilder var content: some View {
        if !model.groups.isEmpty {
            ResultsList(model: model)
        } else if case .finished = model.status {
            EmptyHint(symbol: "checkmark.circle", title: T("Nic nie znaleziono"), text: model.mode == .duplicates
                      ? T("W wybranych miejscach nie ma plików o identycznej zawartości (pomijane są biblioteki FCP, szablony Motion i pliki mniejsze niż %@ MB).", "\(Int(prefs.minSizeMB))")
                      : T("Brak podobnych plików przy tej czułości. Możesz spróbować poziomu „Luźne”."))
        } else if model.status.isRunning {
            EmptyHint(symbol: "hourglass", title: T("Szukam…"), text: T("Możesz przełączyć się na inny tryb — skan będzie trwał w tle."))
        } else {
            EmptyHint(symbol: model.mode.symbol, title: model.roots.isEmpty ? T("Wskaż, gdzie szukać") : T("Gotowe do szukania"),
                      text: T("Aplikacja tylko pokazuje wyniki. Niczego nie usuwa ani nie przenosi sama — każdą akcję potwierdzasz osobno."))
        }
    }
}

// MARK: - Lista wyników

struct ResultsList: View {
    @ObservedObject var model: GroupScanModel
    @EnvironmentObject var prefs: Prefs
    @State private var selection: Set<String> = []
    @State private var preview: URL?

    var files: [ScannedFile] { model.visibleGroups.flatMap(\.files) }

    var body: some View {
        VStack(spacing: 0) {
            Summary(model: model).padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if prefs.resultsLayout == "grid" { grid } else { list }
        }
        .quickLookPreview($preview, in: files.map(\.url))
    }

    var list: some View {
        List(selection: $selection) {
            ForEach(model.visibleGroups) { g in
                Section { ForEach(g.files) { f in FileRow(file: f, group: g, model: model, large: prefs.resultsLayout == "list").tag(f.id) } } header: { GroupHeader(group: g, model: model) }
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            let urls = files.filter { ids.contains($0.id) }.map(\.url)
            Button(T("Pokaż w Finderze")) { FileActions.reveal(urls) }
            Button(T("Podgląd (spacja)")) { preview = urls.first }
            Divider()
            Button(T("Zaznacz do akcji")) { model.checked.formUnion(ids) }
            Button(T("Odznacz")) { model.checked.subtract(ids) }
        } primaryAction: { ids in
            preview = files.first { ids.contains($0.id) }?.url
        }
        .onKeyPress(.space) {
            guard preview == nil, let f = files.first(where: { selection.contains($0.id) }) else { preview = nil; return .handled }
            preview = f.url
            return .handled
        }
    }

    /// Siatka: każda grupa to rząd dużych miniatur — od razu widać, co jest czym.
    var grid: some View {
        let tile = CGFloat(prefs.gridTile)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                ForEach(model.visibleGroups) { g in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: tile, maximum: tile), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                            ForEach(g.files) { f in GridTile(file: f, model: model, width: tile) { preview = f.url } }
                        }
                        .padding(.horizontal, 20)
                    } header: {
                        GroupHeader(group: g, model: model)
                            .padding(.horizontal, 20).padding(.vertical, 6)
                            .background(.bar)
                    }
                }
            }
            .padding(.vertical, 10)
        }
    }
}

/// Kafelek siatki: duża miniatura, nazwa, folder, dysk, data, rozmiar. Klik = zaznacz, dwuklik = podgląd.
struct GridTile: View {
    let file: ScannedFile
    @ObservedObject var model: GroupScanModel
    let width: CGFloat
    let preview: () -> Void
    @State private var hover = false

    var body: some View {
        let checked = model.checked.contains(file.id)
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                Thumbnail(url: file.url, size: width - 16, height: (width - 16) * 0.66, radius: 9)
                    .overlay(alignment: .bottomTrailing) {
                        Text(file.volumeName).font(.system(size: 9.5, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(.ultraThinMaterial)).padding(5)
                    }
                Toggle("", isOn: Binding(get: { checked }, set: { _ in model.toggle(file) }))
                    .toggleStyle(.checkbox).labelsHidden().padding(6)
                    .accessibilityLabel(checked ? T("Odznacz %@", "\(file.name)") : T("Zaznacz %@", "\(file.name)"))
            }
            Text(file.name).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                .strikethrough(checked, color: .secondary)
            Text(Fmt.path(file.folder)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            HStack {
                Text(Fmt.date.string(from: file.modified))
                Spacer()
                Text(Fmt.bytes(file.size)).monospacedDigit()
            }
            .font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(checked ? Theme.missing.opacity(0.8) : Color.primary.opacity(0.06), lineWidth: checked ? 2 : 1))
        .opacity(checked ? 0.75 : 1)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture(count: 2, perform: preview)
        .onTapGesture { model.toggle(file) }
        .contextMenu {
            Button(T("Pokaż w Finderze")) { FileActions.reveal([file.url]) }
            Button(T("Podgląd (spacja)"), action: preview)
        }
        .help(file.url.path)
    }
}

/// Przełącznik widoku wyników: lista / gęsta lista / siatka (+ wielkość kafelków).
struct LayoutPicker: View {
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        HStack(spacing: 8) {
            if prefs.resultsLayout == "grid" {
                Slider(value: $prefs.gridTile, in: 120...300).frame(width: 90).controlSize(.mini)
                    .help(T("Wielkość miniatur"))
            }
            Picker("", selection: $prefs.resultsLayout) {
                Image(systemName: "list.bullet.rectangle").help(T("Lista")).tag("list")
                Image(systemName: "list.dash").help(T("Kompaktowa lista")).tag("compact")
                Image(systemName: "square.grid.2x2").help(T("Siatka miniatur")).tag("grid")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .accessibilityLabel(T("Widok wyników"))
        }
    }
}

struct Summary: View {
    @ObservedObject var model: GroupScanModel

    var body: some View {
        let kinds = MediaKind.allCases.filter { k in model.groups.contains { $0.kind == k } }
        HStack(alignment: .center, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                Text(Fmt.bytes(model.reclaimable)).font(.system(size: 22, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(Theme.accent.gradient)
                Text(T("do odzyskania · %@ · %@", "\(Fmt.groups(model.groups.count))", "\(Fmt.files(model.allFiles.count))"))
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .fixedSize()
            if kinds.count > 1 {
                PillTabs(items: [(value: MediaKind?.none, title: T("Wszystko"), symbol: nil)] + kinds.map { (value: MediaKind?.some($0), title: $0.title, symbol: $0.symbol) },
                         selection: $model.filter, fontSize: 11)
                    .frame(maxWidth: 440)
            }
            Spacer(minLength: 8)
            LayoutPicker()
        }
    }
}

struct GroupHeader: View {
    let group: DuplicateGroup
    @ObservedObject var model: GroupScanModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: group.kind.symbol).foregroundStyle(Theme.color(group.kind)).font(.system(size: 11))
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.primary)
            matchBadge
            Spacer()
            Text(T("odzyskasz %@", "\(Fmt.bytes(group.reclaimable))")).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Menu {
                Button(T("Zaznacz wszystkie oprócz pierwszej")) {
                    group.files.forEach { model.checked.remove($0.id) }
                    group.files.dropFirst().forEach { model.checked.insert($0.id) }
                }
                Button(T("Odznacz grupę")) { group.files.forEach { model.checked.remove($0.id) } }
                Divider()
                Button(T("Pokaż wszystkie w Finderze")) { FileActions.reveal(group.files.map(\.url)) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(T("Opcje grupy")).help(T("Opcje grupy"))
        }
        .padding(.vertical, 2)
    }

    var title: String {
        let n = group.files.count
        if group.isExact { return T("%@ · %@ każda", "\(Fmt.copies(n))", "\(Fmt.bytes(group.files[0].size))") }
        return "\(Fmt.files(n)) · razem \(Fmt.bytes(group.totalSize))"
    }

    @ViewBuilder var matchBadge: some View {
        switch group.match {
        case .identical: EmptyView()
        case .sampled:
            Text(T("prawie na pewno")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.warn)
                .help(T("Porównane fragmenty z początku, środka i końca. Wyłącz tryb szybki, żeby porównać całość."))
        case .similar(let s):
            Text(T("podobieństwo %@", "\(Fmt.percent(s))")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

struct FileRow: View {
    let file: ScannedFile
    let group: DuplicateGroup
    @ObservedObject var model: GroupScanModel
    /// Większe wiersze (widok „Lista”); false = gęsta lista.
    var large = false

    var body: some View {
        let isChecked = model.checked.contains(file.id)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in model.toggle(file) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(isChecked ? T("Odznacz %@", "\(file.name)") : T("Zaznacz %@", "\(file.name)"))
            let visual = file.kind == .image || file.kind == .video
            Thumbnail(url: file.url, size: large ? (visual ? 72 : 44) : (visual ? 32 : 24), height: large && visual ? 50 : nil)
            VStack(alignment: .leading, spacing: large ? 3 : 1) {
                Text(file.name).font(.system(size: large ? 13.5 : 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(isChecked, color: .secondary)
                Text(Fmt.path(file.folder)).font(.system(size: large ? 11.5 : 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(file.volumeName).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Text(Fmt.date.string(from: file.modified)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            Text(Fmt.bytes(file.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .opacity(isChecked ? 0.7 : 1)
        .padding(.vertical, large ? 5 : 0)
        .contentShape(Rectangle())
    }
}

// MARK: - Pasek akcji

struct ActionBar: View {
    @ObservedObject var model: GroupScanModel

    var body: some View {
        let count = model.checked.count
        HStack(spacing: 10) {
            Menu {
                Button(GroupScanModel.KeepRule.oldest.title) { model.select(keeping: .oldest) }
                Button(GroupScanModel.KeepRule.newest.title) { model.select(keeping: .newest) }
                Button(GroupScanModel.KeepRule.shortestPath.title) { model.select(keeping: .shortestPath) }
                if model.volumesInResults.count > 1 {
                    Divider()
                    ForEach(model.volumesInResults, id: \.self) { v in Button(GroupScanModel.KeepRule.onVolume(v).title) { model.select(keeping: .onVolume(v)) } }
                }
                Divider()
                Button(T("Zostaw kopię w wybranym folderze…")) {
                    if let f = FileActions.chooseFolder(title: T("W którym folderze zostawić kopie?"), prompt: T("Wybierz")).first { model.select(keeping: .inFolder(FileWalker.canonical(f.path))) }
                }
            } label: { Label(T("Zaznacz według reguły"), systemImage: "checklist") }
                .fixedSize()
                .help(T("Tylko zaznacza — nic nie jest usuwane, dopóki nie wybierzesz akcji i jej nie potwierdzisz."))
            if count > 0 { Button(T("Odznacz wszystko")) { model.checked = [] }.buttonStyle(.borderless) }

            Spacer()
            Text(count == 0 ? T("Nic nie zaznaczono") : T("Zaznaczono %@ · %@", "\(Fmt.files(count))", "\(Fmt.bytes(model.checkedSize))"))
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(count == 0 ? .secondary : .primary)

            Button { FileActions.reveal(model.checkedFiles.map(\.url)) } label: { Image(systemName: "folder") }
                .disabled(count == 0).help(T("Pokaż zaznaczone w Finderze")).accessibilityLabel(T("Pokaż w Finderze"))
            Menu {
                Button(T("Przenieś do Kosza…")) { model.askTrash() }
                Button(T("Przenieś do folderu…")) { model.askMove() }
                if model.mode == .duplicates {
                    Button(T("Zastąp klonami APFS…")) { model.askClone() }
                }
                Divider()
                Button(T("Eksportuj całą listę (CSV)…")) { model.exportCSV() }
            } label: { Text(T("Co zrobić z zaznaczonymi…")) }
                .fixedSize()
                .disabled(count == 0)
        }
        .controlSize(.regular)
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}
