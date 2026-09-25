import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

// MARK: - Zaznaczanie według folderów

/// Folder, w którym leżą duplikaty (bezpośrednio): ile plików i ile zajmują.
struct FolderStat: Identifiable, Hashable {
    let path: String
    var count: Int
    var size: Int64
    var id: String { path }
}

/// Dwa foldery, które mają wspólne pliki (np. „KLIZA” i „KLIZA kopia”). a == b = kopie w tym samym folderze.
struct FolderPair: Identifiable {
    let a: String
    let b: String
    var count = 0
    /// Ile miejsca wróci, jeśli z pary zostanie jedna strona.
    var size: Int64 = 0
    var aIDs: Set<String> = []
    var bIDs: Set<String> = []
    var id: String { a + "|" + b }
    var sameFolder: Bool { a == b }
}

extension GroupScanModel {
    var folderStats: [FolderStat] {
        var m: [String: FolderStat] = [:]
        for f in visibleGroups.flatMap(\.files) {
            m[f.folder, default: FolderStat(path: f.folder, count: 0, size: 0)].count += 1
            m[f.folder]!.size += f.size
        }
        return m.values.sorted { $0.size > $1.size }
    }

    var folderPairs: [FolderPair] {
        var m: [String: FolderPair] = [:]
        for g in visibleGroups where g.isExact {
            let byFolder = Dictionary(grouping: g.files, by: \.folder)
            let folders = byFolder.keys.sorted()
            for (i, a) in folders.enumerated() {
                if byFolder[a]!.count > 1 { // kopie w tym samym folderze
                    var p = m[a + "|" + a] ?? FolderPair(a: a, b: a)
                    p.count += byFolder[a]!.count - 1
                    p.size += Int64(byFolder[a]!.count - 1) * g.files[0].size
                    p.aIDs.formUnion(byFolder[a]!.map(\.id))
                    m[p.id] = p
                }
                for b in folders[(i + 1)...] {
                    var p = m[a + "|" + b] ?? FolderPair(a: a, b: b)
                    p.count += 1
                    p.size += g.files[0].size
                    p.aIDs.formUnion(byFolder[a]!.map(\.id))
                    p.bIDs.formUnion(byFolder[b]!.map(\.id))
                    m[p.id] = p
                }
            }
        }
        return m.values.sorted { $0.size > $1.size }
    }

    /// Zaznacz pliki z wybranych folderów. W każdej grupie zostaje przynajmniej jeden plik — jeśli wszystkie leżą
    /// w wybranych folderach, zostaje najstarszy. Zwraca liczbę takich grup.
    @discardableResult
    func select(inFolders folders: Set<String>) -> Int {
        var result = checked
        var kept = 0
        for g in visibleGroups {
            let hit = g.files.filter { folders.contains($0.folder) }
            guard !hit.isEmpty else { continue }
            if hit.count == g.files.count {
                kept += 1
                let keeper = g.files.min { ($0.created ?? $0.modified) < ($1.created ?? $1.modified) }!
                for f in hit where f.id != keeper.id { result.insert(f.id) }
                result.remove(keeper.id)
            } else {
                for f in hit { result.insert(f.id) }
                // pliki spoza wybranych folderów zostają — odznacz je, żeby grupa nie zniknęła w całości
                for f in g.files where !folders.contains(f.folder) { result.remove(f.id) }
            }
        }
        checked = result
        return kept
    }

    /// Zostaw pliki w wybranych folderach, zaznacz ich kopie gdzie indziej (tylko grupy, które mają plik w tych folderach).
    func select(keepingFolders folders: Set<String>) {
        var result = checked
        for g in visibleGroups where g.files.contains(where: { folders.contains($0.folder) }) {
            for f in g.files {
                if folders.contains(f.folder) { result.remove(f.id) } else { result.insert(f.id) }
            }
        }
        checked = result
    }

    /// Para folderów: zaznacz kopie po stronie `side` (a albo b), druga strona zostaje.
    func select(pair p: FolderPair, side: String) {
        if p.sameFolder {
            // w tym samym folderze: zostaw najstarszy plik z każdej grupy
            for g in visibleGroups {
                let here = g.files.filter { $0.folder == p.a }
                guard here.count > 1, let keeper = here.min(by: { ($0.created ?? $0.modified) < ($1.created ?? $1.modified) }) else { continue }
                for f in here where f.id != keeper.id { checked.insert(f.id) }
                checked.remove(keeper.id)
            }
            return
        }
        let (mark, keep) = side == p.a ? (p.aIDs, p.bIDs) : (p.bIDs, p.aIDs)
        checked.formUnion(mark)
        checked.subtract(keep)
    }
}

// MARK: - Pasek zaznaczania nad wynikami

/// „Zaznacz ▾” + „Odznacz wszystko” — zawsze na wierzchu, nad wynikami.
struct SelectionControls: View {
    @ObservedObject var model: GroupScanModel
    @State private var sheet: FolderPickSheet.Kind?

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                Section(T("Zaznacz wszystkie kopie — w każdej grupie zostaje jeden plik")) {
                    Button(T("Zostaw najstarszy")) { model.select(keeping: .oldest) }
                    Button(T("Zostaw najnowszy")) { model.select(keeping: .newest) }
                    Button(T("Zostaw ten z najkrótszą ścieżką")) { model.select(keeping: .shortestPath) }
                    if model.volumesInResults.count > 1 {
                        ForEach(model.volumesInResults, id: \.self) { v in Button(T("Zostaw ten na dysku „%@”", "\(v)")) { model.select(keeping: .onVolume(v)) } }
                    }
                }
                Section(T("Według folderów")) {
                    Button(T("Zaznacz pliki z folderów…")) { sheet = .select }
                    Button(T("Zostaw pliki w folderach, zaznacz ich kopie…")) { sheet = .keep }
                }
            } label: { Label(T("Zaznacz"), systemImage: "checklist") }
                .fixedSize()
                .help(T("Tylko zaznacza — nic nie jest usuwane, dopóki nie wybierzesz akcji i jej nie potwierdzisz."))
            Button(T("Odznacz wszystko")) { model.checked = [] }
                .disabled(model.checked.isEmpty)
        }
        .controlSize(.small)
        .sheet(item: $sheet) { k in FolderPickSheet(model: model, kind: k) }
    }
}

/// Wybór folderów z wyników (z liczbą plików i rozmiarem) — do zaznaczania albo zostawiania.
struct FolderPickSheet: View {
    enum Kind: String, Identifiable { case select, keep; var id: String { rawValue } }
    @ObservedObject var model: GroupScanModel
    let kind: Kind
    @Environment(\.dismiss) private var dismiss
    @State private var picked: Set<String> = []
    @State private var query = ""

    var body: some View {
        let all = model.folderStats
        let shown = query.isEmpty ? all : all.filter { $0.path.localizedCaseInsensitiveContains(query) }
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == .select ? T("Zaznacz pliki z folderów") : T("Zostaw pliki w folderach"))
                .font(.system(size: 17, weight: .bold))
            Text(kind == .select
                 ? T("Zaznaczę duplikaty leżące w wybranych folderach. Ich kopie w innych folderach zostają. Gdy cała grupa jest w wybranych folderach, zostawię najstarszy plik.")
                 : T("Pliki w wybranych folderach zostają, a ich kopie w innych folderach zaznaczę."))
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(T("Szukaj folderu"), text: $query).textFieldStyle(.roundedBorder)
            List(shown) { f in
                Toggle(isOn: Binding(get: { picked.contains(f.path) }, set: { if $0 { picked.insert(f.path) } else { picked.remove(f.path) } })) {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text((f.path as NSString).lastPathComponent).font(.system(size: 12.5, weight: .medium))
                            Text(Fmt.path(f.path)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        }
                        Spacer()
                        Text(Fmt.files(f.count)).font(.system(size: 11)).foregroundStyle(.secondary)
                        Text(Fmt.bytes(f.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 280)
            HStack {
                Button(T("Wszystkie")) { picked = Set(shown.map(\.path)) }.buttonStyle(.borderless)
                Button(T("Żadne")) { picked = [] }.buttonStyle(.borderless)
                Spacer()
                Button(T("Anuluj")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(kind == .select ? T("Zaznacz") : T("Zostaw i zaznacz kopie")) {
                    if kind == .select {
                        let kept = model.select(inFolders: picked)
                        if kept > 0 { model.app?.show(T("W %@ wszystkie pliki były w wybranych folderach — zostawiłem po jednym (najstarszym).", "\(Fmt.groups(kept))")) }
                    } else {
                        model.select(keepingFolders: picked)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 620, height: 520)
    }
}

// MARK: - Widok „Foldery”

/// Pary folderów ze wspólnymi plikami: „KLIZA ⇄ KLIZA kopia — 34 wspólne pliki, 2,1 GB” + co zrobić z całym folderem.
struct FolderPairsView: View {
    @ObservedObject var model: GroupScanModel

    var body: some View {
        let pairs = model.folderPairs
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text(T("Foldery, które mają wspólne pliki. Zdecyduj od razu o całym folderze: zaznacz kopie po jednej stronie, druga zostaje."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(pairs) { p in FolderPairCard(pair: p, model: model) }
            }
            .padding(20)
        }
    }
}

struct FolderPairCard: View {
    let pair: FolderPair
    @ObservedObject var model: GroupScanModel
    /// Ile plików leży w folderze (bezpośrednio) — żeby wiedzieć, czy kopią jest CAŁY folder.
    @State private var totals: [String: Int] = [:]

    var body: some View {
        let p = pair
        Card(padding: 12, radius: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: p.sameFolder ? "doc.on.doc.fill" : "arrow.left.arrow.right").foregroundStyle(Theme.accent.primary)
                    Text(p.sameFolder ? T("Kopie w tym samym folderze: %@", "\(Fmt.files(p.count))") : T("Wspólne pliki: %@", "\(Fmt.files(p.count))"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(T("odzyskasz %@", "\(Fmt.bytes(p.size))")).font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
                folderLine(p.a, ids: p.aIDs, other: p.sameFolder ? nil : p.b)
                if !p.sameFolder { folderLine(p.b, ids: p.bIDs, other: p.a) }
                HStack(spacing: 8) {
                    if p.sameFolder {
                        Button(T("Zaznacz kopie (zostaw najstarsze)")) { model.select(pair: p, side: p.a) }
                    } else {
                        Button(T("Zaznacz w „%@”", "\(name(p.a))")) { model.select(pair: p, side: p.a) }
                            .help(T("Kopie w „%@” do zaznaczenia, „%@” zostaje", "\(name(p.a))", "\(name(p.b))"))
                        Button(T("Zaznacz w „%@”", "\(name(p.b))")) { model.select(pair: p, side: p.b) }
                            .help(T("Kopie w „%@” do zaznaczenia, „%@” zostaje", "\(name(p.b))", "\(name(p.a))"))
                    }
                    Button(T("Odznacz")) { model.checked.subtract(p.aIDs.union(p.bIDs)) }.buttonStyle(.borderless)
                    Spacer()
                    Button { FileActions.reveal(p.sameFolder ? [URL(fileURLWithPath: p.a)] : [URL(fileURLWithPath: p.a), URL(fileURLWithPath: p.b)]) } label: { Label(T("Pokaż w Finderze"), systemImage: "folder") }
                        .buttonStyle(.borderless)
                }
                .controlSize(.small)
            }
        }
        .task(id: p.id) {
            var t: [String: Int] = [:]
            for f in [p.a, p.b] { t[f] = Self.directFileCount(f) }
            totals = t
        }
    }

    func name(_ path: String) -> String { (path as NSString).lastPathComponent }

    func folderLine(_ path: String, ids: Set<String>, other: String?) -> some View {
        let checkedHere = ids.filter { model.checked.contains($0) }.count
        let shared = ids.count
        let total = totals[path]
        return HStack(spacing: 8) {
            Image(systemName: "folder.fill").foregroundStyle(FeatureColor.volume)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(name(path)).font(.system(size: 12.5, weight: .medium))
                    if let total, other != nil, total > 0, total == shared {
                        Text(T("cały folder ma kopię")).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.safe)
                            .padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(Theme.safe.opacity(0.12)))
                    }
                }
                Text(Fmt.path(path)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            }
            Spacer()
            if let total, other != nil { Text(T("%@ z %@ w folderze", "\(shared)", "\(total)")).font(.system(size: 11)).foregroundStyle(.secondary) }
            if checkedHere > 0 { Text(T("zaznaczono %@", "\(checkedHere)")).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.missing) }
        }
    }

    /// Pliki leżące bezpośrednio w folderze (bez ukrytych i podfolderów).
    static func directFileCount(_ path: String) -> Int {
        let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }.count
    }
}
