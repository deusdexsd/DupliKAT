import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

struct FCPScreen: View {
    @ObservedObject var model: FCPModel
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ModeHeader(mode: .fcp) { StatusFooter(status: model.status) }
                LocationsCard(title: "Gdzie są biblioteki i projekty", hint: "Np. ~/Filmy albo dysk M z folderem BIBLIOTEKI", urls: $model.roots)
                HStack {
                    Text("Tylko liczy i pokazuje. Cache Adobe i CapCut sprawdzam zawsze, niezależnie od folderów. Oryginalne media, projekty i autozapisy nigdy nie są brane pod uwagę.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    ScanButton(title: "Policz", enabled: !model.roots.isEmpty && !model.status.isRunning) { model.start() }
                }
                .controlSize(.small)
                if case .running(let p) = model.status { ProgressCard(progress: p) { model.cancel() } }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            if !model.libraries.isEmpty { results } else if case .finished = model.status {
                EmptyHint(symbol: "checkmark.circle", title: "Brak plików do odzyskania", text: "W wybranych miejscach nie ma renderów, podglądów, proxy ani cache programów do montażu.")
            } else {
                EmptyHint(symbol: "film", title: "Ile zajmują pliki robocze programów do montażu?",
                          text: "Rendery, podglądy, proxy i cache z Final Cut, Premiere Pro, After Effects, DaVinci Resolve i CapCut. Każdy program potrafi je utworzyć ponownie. Tu widzisz je naraz i sam wybierasz, co usunąć.")
            }
        }
    }

    var results: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 24) {
                HeroNumber(caption: "Pliki generowane", value: Fmt.bytes(model.total),
                           sub: Set(model.libraries.map(\.app)).sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: " · ")).fixedSize()
                VStack(alignment: .leading, spacing: 10) {
                    BreakdownBar(parts: GeneratedKind.allCases.map { ($0.title, Theme.color($0), model.total($0)) })
                    HStack(spacing: 6) {
                        Text("Zaznacz we wszystkich:").font(.system(size: 11)).foregroundStyle(.secondary)
                        ForEach(GeneratedKind.allCases.filter { model.total($0) > 0 }) { k in
                            Toggle(k.title, isOn: Binding(get: { model.isSelected(kind: k) }, set: { model.select(kind: k, on: $0) }))
                                .toggleStyle(.button).controlSize(.small)
                                .help(k.consequence)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            List {
                ForEach(EditorApp.allCases.filter { a in model.libraries.contains { $0.app == a } }) { app in
                    Section {
                        ForEach(model.libraries.filter { $0.app == app }) { lib in
                            if lib.folders.count > 1 {
                                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(lib.id) }, set: { if $0 { expanded.insert(lib.id) } else { expanded.remove(lib.id) } })) {
                                    ForEach(lib.folders) { f in FolderRow(folder: f, model: model) }
                                } label: { LibraryRow(lib: lib, model: model) }
                            } else {
                                LibraryRow(lib: lib, model: model)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            if let icon = EditorIcon.image(app) { Image(nsImage: icon).resizable().frame(width: 18, height: 18) }
                            Text(app.title).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(Fmt.bytes(model.libraries.filter { $0.app == app }.reduce(0) { $0 + $1.total })).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
    }

    var bar: some View {
        let sel = model.checkedFolders
        return HStack(spacing: 10) {
            if !sel.isEmpty { Button("Odznacz wszystko") { model.checked = [] }.buttonStyle(.borderless) }
            Spacer()
            Text(sel.isEmpty ? "Nic nie zaznaczono" : "Zaznaczono \(Fmt.bytes(sel.reduce(0) { $0 + $1.size }))")
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(sel.isEmpty ? .secondary : .primary)
            Button { FileActions.reveal(sel.map(\.url)) } label: { Image(systemName: "folder") }
                .disabled(sel.isEmpty).help("Pokaż zaznaczone w Finderze").accessibilityLabel("Pokaż w Finderze")
            Button("Przenieś zaznaczone do Kosza…") { model.askTrash() }.disabled(sel.isEmpty)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct LibraryRow: View {
    let lib: LibraryReport
    @ObservedObject var model: FCPModel

    var body: some View {
        let ids = lib.folders.map(\.id)
        let n = ids.filter { model.checked.contains($0) }.count
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { n == ids.count && n > 0 }, set: { on in if on { model.checked.formUnion(ids) } else { model.checked.subtract(ids) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: lib.isExternalFolder ? "folder" : "film.stack").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(lib.name).font(.system(size: 12.5, weight: .semibold))
                    Text(lib.volumeName).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1.5).background(Capsule().fill(Color.primary.opacity(0.06)))
                    if n > 0 && n < ids.count { Text("częściowo").font(.system(size: 10.5)).foregroundStyle(.tertiary) }
                }
                HStack(spacing: 10) {
                    ForEach(GeneratedKind.allCases.filter { lib.size(of: $0) > 0 }) { k in
                        HStack(spacing: 4) {
                            Circle().fill(Theme.color(k)).frame(width: 6, height: 6)
                            Text("\(k.title) \(Fmt.bytes(lib.size(of: k)))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer()
            Text(Fmt.bytes(lib.total)).font(.system(size: 12, weight: .semibold)).monospacedDigit()
        }
        .padding(.vertical, 3)
    }
}

struct FolderRow: View {
    let folder: GeneratedFolder
    @ObservedObject var model: FCPModel

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { model.checked.contains(folder.id) }, set: { on in if on { model.checked.insert(folder.id) } else { model.checked.remove(folder.id) } }))
                .toggleStyle(.checkbox).labelsHidden()
            Image(systemName: folder.kind.symbol).foregroundStyle(Theme.color(folder.kind)).frame(width: 16)
            Text(folder.kind.title).font(.system(size: 12, weight: .medium))
            if let e = folder.event { Text(e).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            Text(Fmt.bytes(folder.size)).font(.system(size: 11)).monospacedDigit()
        }
        .help(folder.kind.consequence)
    }
}

/// Ikona programu (z zainstalowanej aplikacji), żeby grupy było widać na pierwszy rzut oka.
enum EditorIcon {
    @MainActor static func image(_ app: EditorApp) -> NSImage? {
        let ws = NSWorkspace.shared
        for id in app.bundlePrefixes { if let u = ws.urlForApplication(withBundleIdentifier: id) { return ws.icon(forFile: u.path) } }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        let prefix: [String] = app == .adobe ? ["Adobe Premiere", "Adobe After Effects"] : app == .davinci ? ["DaVinci Resolve"] : app == .capcut ? ["CapCut", "剪映"] : ["Final Cut Pro"]
        if let n = names.first(where: { n in prefix.contains { n.hasPrefix($0) } }) {
            let dir = "/Applications/" + n
            if n.hasSuffix(".app") { return ws.icon(forFile: dir) }
            if let inner = try? FileManager.default.contentsOfDirectory(atPath: dir).first(where: { $0.hasSuffix(".app") }) { return ws.icon(forFile: dir + "/" + inner) }
        }
        return nil
    }
}
