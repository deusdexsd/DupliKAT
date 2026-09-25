import DubelCore
import MidniteUIKit
import QuickLook
import SwiftUI

struct BackupScreen: View {
    @ObservedObject var model: BackupModel
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var app: AppModel
    @State private var showPairs = true
    @State private var tab: Tab = .missing
    @State private var preview: URL?

    enum Tab: Hashable { case backedUp, missing, differs }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                ModeHeader(mode: .backup) { StatusFooter(status: model.status, log: model.log) }
                HStack(alignment: .top, spacing: 12) {
                    LocationsCard(title: T("Źródło — co sprawdzić"), hint: T("Np. folder roboczy albo karta"), urls: $model.sources)
                    Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 34)
                    LocationsCard(title: T("Archiwum — gdzie powinno być"), hint: T("Np. dysk M albo folder „BACKUP KART”"), urls: $model.backups)
                        .coachAnchor("archive")
                }
                HStack {
                    Toggle(T("Sprawdzaj całą zawartość plików"), isOn: $prefs.backupVerify)
                        .help(T("Wolniej, ale dopiero wtedy „zgrane” znaczy „identyczne bajt po bajcie”. Zalecane, jeśli potem kasujesz kartę."))
                    Spacer()
                    ScanButton(title: T("Sprawdź"), enabled: !model.sources.isEmpty && !model.backups.isEmpty && !model.status.isRunning) { model.start() }
                }
                .font(.system(size: 12)).controlSize(.small)
                if case .running(let p) = model.status { ProgressCard(progress: p, log: model.log) { model.cancel() } }
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 12)
            Divider()
            if let r = model.report { results(r) } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        PairsSection(model: app.transfer)
                        EmptyHint(symbol: "arrow.left.arrow.right", title: T("Czy wszystko z A jest w B?"),
                                  text: T("Wskaż źródło i archiwum albo użyj zapisanej pary. Każdy plik ze źródła jest szukany w archiwum po zawartości — także jeśli ma tam inną nazwę albo leży w innym folderze."))
                            .frame(height: 200)
                    }
                    .padding(20)
                }
            }
        }
    }

    func results(_ r: BackupChecker.Report) -> some View {
        let list: [BackupChecker.Entry] = tab == .backedUp ? r.backedUp : tab == .missing ? r.missing : r.differs
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                StatTile(title: T("Zgrane"), value: r.backedUp.count, size: r.backedUp.reduce(0) { $0 + $1.file.size }, color: Theme.safe, symbol: "checkmark.circle.fill", selected: tab == .backedUp) { tab = .backedUp }
                StatTile(title: T("Brakuje w archiwum"), value: r.missing.count, size: r.missing.reduce(0) { $0 + $1.file.size }, color: Theme.missing, symbol: "xmark.circle.fill", selected: tab == .missing) { tab = .missing }
                StatTile(title: T("Ta sama nazwa, inna treść"), value: r.differs.count, size: r.differs.reduce(0) { $0 + $1.file.size }, color: Theme.warn, symbol: "exclamationmark.circle.fill", selected: tab == .differs) { tab = .differs }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            if list.isEmpty {
                EmptyHint(symbol: tab == .missing ? "checkmark.seal" : "tray", title: tab == .missing ? T("Wszystko jest w archiwum") : T("Pusto"), text: tab == .missing ? T("Każdy plik ze źródła ma kopię w archiwum.") : "")
            } else {
                List {
                    ForEach(list) { e in BackupRow(entry: e, checkable: tab != .differs, model: model) }
                }
                .listStyle(.inset).scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in preview = list.first { ids.contains($0.id) }?.file.url }
                .quickLookPreview($preview, in: list.map(\.file.url))
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !list.isEmpty && tab != .differs { bar(list) }
        }
    }

    func bar(_ list: [BackupChecker.Entry]) -> some View {
        let sel = list.filter { model.checked.contains($0.id) }
        return HStack(spacing: 10) {
            Button(T("Zaznacz wszystkie")) { model.checked.formUnion(list.map(\.id)) }.buttonStyle(.borderless)
            if !sel.isEmpty { Button(T("Odznacz")) { model.checked.subtract(list.map(\.id)) }.buttonStyle(.borderless) }
            Spacer()
            Text(sel.isEmpty ? T("Nic nie zaznaczono") : T("Zaznaczono %@ · %@", "\(Fmt.files(sel.count))", "\(Fmt.bytes(sel.reduce(0) { $0 + $1.file.size }))"))
                .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(sel.isEmpty ? .secondary : .primary)
            Button { FileActions.reveal(sel.map(\.file.url)) } label: { Image(systemName: "folder") }
                .disabled(sel.isEmpty).help(T("Pokaż zaznaczone w Finderze")).accessibilityLabel(T("Pokaż w Finderze"))
            if tab == .backedUp {
                Button(T("Przenieś ze źródła do Kosza…")) { model.askTrashBackedUp() }.disabled(sel.isEmpty)
                    .help(T("Tylko pliki, które mają identyczną kopię w archiwum."))
            } else {
                Button(T("Skopiuj do archiwum…")) { model.askCopyMissing() }.disabled(sel.isEmpty)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

struct StatTile: View {
    let title: String
    let value: Int
    let size: Int64
    let color: Color
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(value)").font(.system(size: 20, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(Fmt.bytes(size)).font(.system(size: 10.5)).foregroundStyle(.tertiary).monospacedDigit()
                }
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? color.opacity(0.12) : Color.primary.opacity(hover ? 0.09 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? color.opacity(0.6) : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct BackupRow: View {
    let entry: BackupChecker.Entry
    let checkable: Bool
    @ObservedObject var model: BackupModel

    var body: some View {
        let isChecked = model.checked.contains(entry.id)
        HStack(spacing: 10) {
            if checkable {
                Toggle("", isOn: Binding(get: { isChecked }, set: { on in if on { model.checked.insert(entry.id) } else { model.checked.remove(entry.id) } }))
                    .toggleStyle(.checkbox).labelsHidden()
            }
            Thumbnail(url: entry.file.url, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.file.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(Fmt.path(entry.file.folder)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let other = counterpart {
                    Label(other, systemImage: "arrow.turn.down.right").font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            Text(Fmt.date.string(from: entry.file.modified)).font(.system(size: 11)).foregroundStyle(.secondary)
            Text(Fmt.bytes(entry.file.size)).font(.system(size: 11)).monospacedDigit().frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    var counterpart: String? {
        switch entry.status {
        case .backedUp: return CopyText.describe(entry, nil)
        case .differs(let u): return T("inna treść: ") + Fmt.path(u[0].path)
        case .missing: return nil
        }
    }
}
