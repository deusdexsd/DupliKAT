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

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ModeHeader(mode: model.mode) { StatusFooter(status: model.status, log: model.log) }
                LocationsCard(title: "Gdzie szukać", urls: $model.roots)
                options
                if case .running(let p) = model.status { ProgressCard(progress: p, log: model.log) { model.cancel() } }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)

            Divider()
            content
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !model.groups.isEmpty { ActionBar(model: model) }
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
                    Text(model.kinds.count == MediaKind.allCases.count ? "Wszystkie rodzaje plików" : model.kinds.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))
                }
                .fixedSize()
                Toggle("Tryb szybki", isOn: $prefs.quickMode)
                    .help("Porównuje tylko fragmenty z początku, środka i końca pliku. Dużo szybciej na dyskach USB, wynik „prawie na pewno”.")
            case .photos:
                Picker("Czułość", selection: $prefs.photoSensitivity) { ForEach(Sensitivity.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Text(prefs.photoSensitivity.photoHint()).font(.system(size: 11)).foregroundStyle(.secondary)
            case .media:
                Toggle("Wideo", isOn: kindBinding(.video))
                Toggle("Audio", isOn: kindBinding(.audio))
                Picker("Czułość", selection: $prefs.mediaSensitivity) { ForEach(Sensitivity.allCases) { Text($0.title).tag($0) } }
                    .pickerStyle(.segmented).fixedSize()
                Text(prefs.mediaSensitivity.mediaHint()).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            default: EmptyView()
            }
            Spacer(minLength: 8)
            ScanButton(title: "Szukaj", enabled: !model.roots.isEmpty && !model.status.isRunning) { model.start() }
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
            EmptyHint(symbol: "checkmark.circle", title: "Nic nie znaleziono", text: model.mode == .duplicates
                      ? "W wybranych miejscach nie ma plików o identycznej zawartości (pomijane są biblioteki FCP, szablony Motion i pliki mniejsze niż \(Int(prefs.minSizeMB)) MB)."
                      : "Brak podobnych plików przy tej czułości. Możesz spróbować poziomu „Luźne”.")
        } else if model.status.isRunning {
            EmptyHint(symbol: "hourglass", title: "Szukam…", text: "Możesz przełączyć się na inny tryb — skan będzie trwał w tle.")
        } else {
            EmptyHint(symbol: model.mode.symbol, title: model.roots.isEmpty ? "Wskaż, gdzie szukać" : "Gotowe do szukania",
                      text: "Aplikacja tylko pokazuje wyniki. Niczego nie usuwa ani nie przenosi sama — każdą akcję potwierdzasz osobno.")
        }
    }
}

// MARK: - Lista wyników

struct ResultsList: View {
    @ObservedObject var model: GroupScanModel
    @State private var selection: Set<String> = []
    @State private var preview: URL?

    var files: [ScannedFile] { model.visibleGroups.flatMap(\.files) }

    var body: some View {
        VStack(spacing: 0) {
            Summary(model: model).padding(.horizontal, 20).padding(.vertical, 12)
            List(selection: $selection) {
                ForEach(model.visibleGroups) { g in
                    Section { ForEach(g.files) { f in FileRow(file: f, group: g, model: model).tag(f.id) } } header: { GroupHeader(group: g, model: model) }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                let urls = files.filter { ids.contains($0.id) }.map(\.url)
                Button("Pokaż w Finderze") { FileActions.reveal(urls) }
                Button("Podgląd (spacja)") { preview = urls.first }
                Divider()
                Button("Zaznacz do akcji") { model.checked.formUnion(ids) }
                Button("Odznacz") { model.checked.subtract(ids) }
            } primaryAction: { ids in
                preview = files.first { ids.contains($0.id) }?.url
            }
            .onKeyPress(.space) {
                guard preview == nil, let f = files.first(where: { selection.contains($0.id) }) else { preview = nil; return .handled }
                preview = f.url
                return .handled
            }
            .quickLookPreview($preview, in: files.map(\.url))
        }
    }
}

struct Summary: View {
    @ObservedObject var model: GroupScanModel

    var body: some View {
        let kinds = MediaKind.allCases.filter { k in model.groups.contains { $0.kind == k } }
        HStack(alignment: .top, spacing: 24) {
            HeroNumber(caption: "Do odzyskania", value: Fmt.bytes(model.reclaimable),
                       sub: "\(Fmt.groups(model.groups.count)) · \(Fmt.files(model.allFiles.count))")
                .fixedSize()
            VStack(alignment: .leading, spacing: 10) {
                BreakdownBar(parts: kinds.map { k in (k.title, Theme.color(k), model.groups.filter { $0.kind == k }.reduce(0) { $0 + $1.reclaimable }) })
                if kinds.count > 1 {
                    PillTabs(items: [(value: MediaKind?.none, title: "Wszystko", symbol: nil)] + kinds.map { (value: MediaKind?.some($0), title: $0.title, symbol: $0.symbol) },
                             selection: $model.filter, fontSize: 11.5)
                        .frame(maxWidth: 520)
                }
            }
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
            Text("odzyskasz \(Fmt.bytes(group.reclaimable))").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Menu {
                Button("Zaznacz wszystkie oprócz pierwszej") {
                    group.files.forEach { model.checked.remove($0.id) }
                    group.files.dropFirst().forEach { model.checked.insert($0.id) }
                }
                Button("Odznacz grupę") { group.files.forEach { model.checked.remove($0.id) } }
                Divider()
                Button("Pokaż wszystkie w Finderze") { FileActions.reveal(group.files.map(\.url)) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Opcje grupy").help("Opcje grupy")
        }
        .padding(.vertical, 2)
    }

    var title: String {
        let n = group.files.count
        if group.isExact { return "\(Fmt.copies(n)) · \(Fmt.bytes(group.files[0].size)) każda" }
        return "\(Fmt.files(n)) · razem \(Fmt.bytes(group.totalSize))"
    }

    @ViewBuilder var matchBadge: some View {
        switch group.match {
        case .identical: EmptyView()
        case .sampled:
            Text("prawie na pewno").font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.warn)
                .help("Porównane fragmenty z początku, środka i końca. Wyłącz tryb szybki, żeby porównać całość.")
        case .similar(let s):
            Text("podobieństwo \(Fmt.percent(s))").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
        }
    }
}

struct FileRow: View {
    let file: ScannedFile
    let group: DuplicateGroup
    @ObservedObject var model: GroupScanModel

    var body: some View {
        let isChecked = model.checked.contains(file.id)
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in model.toggle(file) }))
                .toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(isChecked ? "Odznacz \(file.name)" : "Zaznacz \(file.name)")
            Thumbnail(url: file.url, size: file.kind == .image || file.kind == .video ? 40 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    .strikethrough(isChecked, color: .secondary)
                Text(Fmt.path(file.folder)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(file.volumeName).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.06)))
            Text(Fmt.date.string(from: file.modified)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 92, alignment: .trailing)
            Text(Fmt.bytes(file.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .opacity(isChecked ? 0.7 : 1)
        .padding(.vertical, 2)
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
                Button("Zostaw kopię w wybranym folderze…") {
                    if let f = FileActions.chooseFolder(title: "W którym folderze zostawić kopie?", prompt: "Wybierz").first { model.select(keeping: .inFolder(FileWalker.canonical(f.path))) }
                }
            } label: { Label("Zaznacz według reguły", systemImage: "checklist") }
                .fixedSize()
                .help("Tylko zaznacza — nic nie jest usuwane, dopóki nie wybierzesz akcji i jej nie potwierdzisz.")
            if count > 0 { Button("Odznacz wszystko") { model.checked = [] }.buttonStyle(.borderless) }

            Spacer()
            Text(count == 0 ? "Nic nie zaznaczono" : "Zaznaczono \(Fmt.files(count)) · \(Fmt.bytes(model.checkedSize))")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(count == 0 ? .secondary : .primary)

            Button { FileActions.reveal(model.checkedFiles.map(\.url)) } label: { Image(systemName: "folder") }
                .disabled(count == 0).help("Pokaż zaznaczone w Finderze").accessibilityLabel("Pokaż w Finderze")
            Menu {
                Button("Przenieś do Kosza…") { model.askTrash() }
                Button("Przenieś do folderu…") { model.askMove() }
                if model.mode == .duplicates {
                    Button("Zastąp klonami APFS…") { model.askClone() }
                }
                Divider()
                Button("Eksportuj całą listę (CSV)…") { model.exportCSV() }
            } label: { Text("Co zrobić z zaznaczonymi…") }
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
