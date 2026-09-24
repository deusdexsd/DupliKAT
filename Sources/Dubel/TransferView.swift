import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

struct TransferScreen: View {
    @ObservedObject var model: TransferModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ModeHeader(mode: .transfer)
                if let card = model.card { CardCheckPanel(job: card, model: model) }
                volumes
                searchPlaces
            }
            .padding(20)
        }
    }

    // MARK: Podpięte

    var volumes: some View {
        let external = app.volumes.filter { $0.url.path != "/" }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Podłączone karty i dyski").padding(.leading, 4)
                Spacer()
                Button { model.startFolder() } label: { Label("Sprawdź folder…", systemImage: "folder") }.controlSize(.small)
                    .help("Jak karta, tylko dowolny folder: co z niego ma już kopię i gdzie")
            }
            if external.isEmpty {
                Card(padding: 14, radius: 10) {
                    Label("Podłącz kartę albo dysk. Karty z aparatu (DCIM, Sony M4ROOT) są rozpoznawane automatycznie.", systemImage: "sdcard")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(external) { v in
                Card(padding: 12, radius: 10) {
                    HStack(spacing: 12) {
                        IconCircle(symbol: v.isCard ? "sdcard.fill" : "externaldrive.fill", color: v.isCard ? FeatureColor.card : FeatureColor.volume, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(v.name).font(.system(size: 13, weight: .semibold))
                                if v.isCard { Text("karta z aparatu").font(.system(size: 10.5, weight: .medium)).foregroundStyle(FeatureColor.card) }
                            }
                            Text("\(Fmt.bytes(v.total - v.free)) zajęte z \(Fmt.bytes(v.total)) · wolne \(Fmt.bytes(v.free))").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Co jest zgrane?") { model.startCard(v.url) }.disabled(model.card?.isBusy == true)
                            .help("Sprawdza, które pliki mają już kopię (i gdzie), a których nie ma nigdzie")
                        Button("Duplikaty") { app.duplicates.roots = [v.url]; app.mode = .duplicates; app.duplicates.start() }
                        Button { model.eject(v.url) } label: { Image(systemName: "eject") }
                            .help("Wysuń").accessibilityLabel("Wysuń \(v.name)")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    var searchPlaces: some View {
        SectionCard(title: "Gdzie szukać kopii plików z karty", footer: "Tu DupliKAT sprawdza, czy pliki z karty już gdzieś są — po zawartości, nie po nazwie.") {
            SearchLocationsEditor()
        }
    }
}

// MARK: - Przebieg zgrywania

struct JobPanel: View {
    @ObservedObject var job: TransferJob
    @ObservedObject var model: TransferModel
    @EnvironmentObject var prefs: Prefs

    var title: String {
        switch job.kind {
        case .card: return "Zgrywanie „\(job.sourceName)”"
        case .pairAdd: return "Dogrywanie brakujących — \(job.sourceName)"
        case .mirror: return "Lustro — \(job.sourceName)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconCircle(symbol: job.kind == .mirror ? "rectangle.on.rectangle.angled" : "sdcard.fill", color: job.kind == .mirror ? Theme.missing : FeatureColor.card, size: 34)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !job.isBusy { Button { model.close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Zamknij").help("Zamknij") }
            }
            if job.kind == .card { destinationRow }
            switch job.stage {
            case .planning(let p): ProgressCard(progress: p, log: job.log) { job.cancel(); model.close() }
            case .ready: ready
            case .working(let p): ProgressCard(progress: p, log: job.log) { job.cancel() }
            case .done: report
            case .failed(let msg): Label(msg, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.warn)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder((job.kind == .mirror ? Theme.missing : FeatureColor.card).opacity(0.35), lineWidth: 1.5))
    }

    var destinationRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Dokąd:").font(.system(size: 12))
                Menu {
                    ForEach(prefs.auto.destinations) { d in
                        Button { job.destination = d; job.replan() } label: { Text(d.title + (d.isAvailable ? "" : " (niepodłączony)")) }.disabled(!d.isAvailable)
                    }
                    Divider()
                    Button("Inny folder…") {
                        if let u = FileActions.chooseFolder(title: "Dokąd zgrać tę kartę?", prompt: "Wybierz").first {
                            let d = Destination(path: u.path)
                            if !prefs.auto.destinations.contains(where: { $0.path == d.path }) { prefs.auto.destinations.append(d) }
                            job.destination = prefs.auto.destinations.first { $0.path == d.path }; job.replan()
                        }
                    }
                } label: { Text(job.destination?.title ?? "Wybierz cel…") }
                    .fixedSize()
                    .disabled(job.isBusy)
                if let t = job.targetFolder { Text("→ \(Fmt.path(t.path))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            HStack(spacing: 14) {
                TemplateField(template: Binding(get: { job.template }, set: { job.template = $0 }))
                    .onSubmit { job.replan() }
                    .disabled(job.isBusy)
                Toggle("Sprawdź kopie bajt po bajcie", isOn: Binding(get: { job.verify }, set: { job.verify = $0 })).toggleStyle(.checkbox).font(.system(size: 11.5))
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder var ready: some View {
        if job.kind == .mirror, let m = job.mirror { mirrorReady(m) } else if let p = job.plan {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    StatBadge(value: "\(p.toCopy.count)", label: "nowych plików · \(Fmt.bytes(p.bytes))", color: FeatureColor.card)
                    StatBadge(value: "\(p.alreadyThere.count)", label: "już jest w celu (pomijam)", color: Theme.safe)
                }
                if p.toCopy.isEmpty {
                    Label("Wszystko już jest w celu — nie ma czego kopiować.", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.safe).font(.system(size: 12.5, weight: .medium))
                    if job.kind == .card { formatOffer }
                } else {
                    FileListPreview(items: p.toCopy.map { ($0.source.lastPathComponent, Fmt.path($0.target.deletingLastPathComponent().path), $0.size) })
                    HStack {
                        Text("Niczego nie nadpisuję ani nie usuwam — tylko dodaję nowe pliki.").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Anuluj") { model.close() }
                        Button { job.run() } label: { Label("Zgraj \(Fmt.files(p.toCopy.count))", systemImage: "arrow.down.doc") }
                            .buttonStyle(GradientButtonStyle())
                    }
                }
            }
        }
    }

    func mirrorReady(_ m: Transfer.MirrorPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                StatBadge(value: "\(m.toCopy.count)", label: "do skopiowania", color: FeatureColor.card)
                StatBadge(value: "\(m.toReplace.count)", label: "zmienionych — stara wersja do Kosza", color: Theme.warn)
                StatBadge(value: "\(m.toTrash.count)", label: "nadmiarowych w celu — do Kosza", color: Theme.missing)
            }
            if !m.toTrash.isEmpty || !m.toReplace.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Lustro usuwa z celu wszystko, czego nie ma w źródle. Te pliki trafią do Kosza celu:", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.missing)
                    FileListPreview(items: m.toTrash.map { ($0.name, Fmt.path($0.folder), $0.size) } + m.toReplace.map { ($0.lastPathComponent + " (stara wersja)", Fmt.path($0.deletingLastPathComponent().path), 0) })
                    Toggle("Rozumiem — \(Fmt.files(m.toTrash.count + m.toReplace.count)) z celu trafi do Kosza", isOn: Binding(get: { job.mirrorConfirmed }, set: { job.mirrorConfirmed = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.missing.opacity(0.08)))
            }
            HStack {
                Spacer()
                Button("Anuluj") { model.close() }
                Button { job.run() } label: { Label("Zrób lustro", systemImage: "rectangle.on.rectangle.angled") }
                    .buttonStyle(.borderedProminent).tint(Theme.missing)
                    .disabled((m.toCopy.isEmpty && m.toTrash.isEmpty && m.toReplace.isEmpty) || (!(m.toTrash.isEmpty && m.toReplace.isEmpty) && !job.mirrorConfirmed))
            }
        }
    }

    @ViewBuilder var report: some View {
        if let r = job.result {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    StatBadge(value: "\(r.copied.count)", label: job.verify ? "skopiowanych i sprawdzonych" : "skopiowanych", color: Theme.safe)
                    if !r.failed.isEmpty { StatBadge(value: "\(r.failed.count)", label: "nieudanych", color: Theme.missing) }
                    if !r.skippedExisting.isEmpty { StatBadge(value: "\(r.skippedExisting.count)", label: "już istniało w celu", color: .secondary) }
                    if job.mirrorTrashed > 0 { StatBadge(value: "\(job.mirrorTrashed)", label: "przeniesionych do Kosza", color: Theme.warn) }
                }
                ForEach(r.failed.prefix(8), id: \.0.id) { f in
                    Label("\(f.0.source.lastPathComponent): \(f.1)", systemImage: "xmark.octagon").font(.system(size: 11)).foregroundStyle(Theme.missing)
                }
                HStack {
                    if let t = job.targetFolder { Button { NSWorkspace.shared.open(t) } label: { Label("Otwórz folder", systemImage: "folder") } }
                    Spacer()
                    Button("Gotowe") { model.close() }
                }
                .controlSize(.small)
                if job.cardFullyBackedUp { formatOffer }
            }
        }
    }

    /// Pytanie o formatowanie — Dubel NIE formatuje. Tylko otwiera systemowe Narzędzie dyskowe albo wysuwa kartę.
    @ViewBuilder var formatOffer: some View {
        if prefs.auto.askFormatAfterImport, let vol = job.cardVolume {
            VStack(alignment: .leading, spacing: 8) {
                Label("Karta „\(vol.lastPathComponent)” jest w całości zgrana. Sformatować ją?", systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.safe)
                Text("Najzdrowiej dla karty jest sformatować ją w aparacie. Jeśli wolisz na Macu: otworzę systemowe Narzędzie dyskowe — wybierz po lewej „\(vol.lastPathComponent)”, kliknij Wymaż i format ExFAT. DupliKAT sam niczego nie formatuje.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.openDiskUtility() } label: { Label("Otwórz Narzędzie dyskowe", systemImage: "internaldrive") }
                    Button { model.eject(vol); model.close() } label: { Label("Wysuń kartę (sformatuję w aparacie)", systemImage: "eject") }
                    Spacer()
                    Button("Nie teraz") { model.close() }
                }
                .controlSize(.small)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.safe.opacity(0.08)))
        }
    }
}

struct StatBadge: View {
    let value: String
    let label: String
    let color: Color
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }
}

struct FileListPreview: View {
    let items: [(String, String, Int64)]
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items.indices, id: \.self) { i in
                    HStack {
                        Text(items[i].0).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Text(items[i].1).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if items[i].2 > 0 { Text(Fmt.bytes(items[i].2)).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(i % 2 == 0 ? Color.primary.opacity(0.03) : .clear)
                }
            }
        }
        .frame(maxHeight: 160)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.03)))
    }
}

struct PairEditor: View {
    @State var pair: ComparePair
    let onSave: (ComparePair) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pair.source.isEmpty ? "Nowa para" : "Edytuj parę").font(.system(size: 15, weight: .semibold))
            TextField("Nazwa, np. „Karty → M”", text: $pair.name).textFieldStyle(.roundedBorder)
            pathRow("Źródło (np. karta, folder roboczy)", $pair.source)
            pathRow("Cel (archiwum)", $pair.target)
            Toggle("Porównuj automatycznie po podłączeniu dysku (tylko odczyt, potem powiadomienie)", isOn: $pair.runOnMount).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Zapisz") { onSave(pair); dismiss() }.keyboardShortcut(.defaultAction)
                    .disabled(pair.source.isEmpty || pair.target.isEmpty || pair.source == pair.target)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 520)
    }

    func pathRow(_ label: String, _ path: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Text(path.wrappedValue.isEmpty ? "nie wybrano" : Fmt.path(path.wrappedValue)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(path.wrappedValue.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Wybierz…") { if let u = FileActions.chooseFolder(title: label, prompt: "Wybierz").first { path.wrappedValue = u.path } }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// Stałe pary „zawsze porównuj to z tym” — w trybie Porównaj foldery.
struct PairsSection: View {
    @ObservedObject var model: TransferModel
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs
    @State private var editingPair: ComparePair?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let job = model.job { JobPanel(job: job, model: model) }
            pairs
        }
        .sheet(item: $editingPair) { p in PairEditor(pair: p) { saved in
            if let i = prefs.auto.pairs.firstIndex(where: { $0.id == saved.id }) { prefs.auto.pairs[i] = saved } else { prefs.auto.pairs.append(saved) }
        } }
    }

    // MARK: Pary

    var pairs: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Caption("Zapisane pary — porównuj jednym kliknięciem").padding(.leading, 4)
                Spacer()
                Button { editingPair = ComparePair(name: "", source: app.backup.sources.first?.path ?? "", target: app.backup.backups.first?.path ?? "") } label: {
                    Label("Zapisz parę…", systemImage: "plus")
                }.controlSize(.small).help("Zapisuje źródło i archiwum jako stałą parę (możesz je zmienić)")
            }
            if prefs.auto.pairs.isEmpty {
                Card(padding: 14, radius: 10) {
                    Text("Porównujesz coś regularnie, np. „T7-2 ▸ karta 1” z „M ▸ BACKUP KART”? Zapisz to jako parę — potem jednym kliknięciem porównasz, dograsz brakujące albo zrobisz lustro.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(prefs.auto.pairs) { p in
                Card(padding: 12, radius: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconCircle(symbol: "arrow.left.arrow.right", color: FeatureColor.pair, on: p.isAvailable, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name.isEmpty ? "Para" : p.name).font(.system(size: 13, weight: .semibold))
                                Text("\(Fmt.path(p.source))  →  \(Fmt.path(p.target))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if !p.isAvailable { Text("Któryś dysk jest niepodłączony").font(.system(size: 10.5)).foregroundStyle(Theme.warn) }
                            }
                            Spacer()
                            Menu {
                                Button("Edytuj…") { editingPair = p }
                                Button("Usuń parę", role: .destructive) { prefs.auto.pairs.removeAll { $0.id == p.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Opcje pary")
                        }
                        HStack(spacing: 8) {
                            Button { app.automation.runPairCompare(p, notify: false) } label: { Label("Porównaj", systemImage: "magnifyingglass") }
                                .help("Tylko odczyt — pokazuje, czego brakuje w celu")
                            Button { model.startPair(p, mirror: false) } label: { Label("Dograj brakujące…", systemImage: "plus.square.on.square") }
                                .help("Kopiuje do celu tylko to, czego tam nie ma. Niczego w celu nie usuwa.")
                            Button { model.startPair(p, mirror: true) } label: { Label("Lustro…", systemImage: "rectangle.on.rectangle.angled") }
                                .help("Cel = dokładna kopia źródła. Nadmiarowe pliki w celu trafią do Kosza — zobaczysz listę przed startem.")
                            Spacer()
                            Toggle("Porównuj po podłączeniu", isOn: Binding(get: { p.runOnMount }, set: { v in
                                if let i = prefs.auto.pairs.firstIndex(where: { $0.id == p.id }) { prefs.auto.pairs[i].runOnMount = v; if v { Notifier.request() } }
                            })).toggleStyle(.checkbox).font(.system(size: 11.5))
                        }
                        .controlSize(.small)
                        .disabled(!p.isAvailable || model.job?.isBusy == true)
                    }
                }
            }
        }
    }

}
