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
                Caption(T("Podłączone karty i dyski")).padding(.leading, 4)
                Spacer()
                Button { model.startFolder() } label: { Label(T("Sprawdź folder…"), systemImage: "folder") }.controlSize(.small)
                    .help(T("Jak karta, tylko dowolny folder: co z niego ma już kopię i gdzie"))
            }
            if external.isEmpty {
                Card(padding: 14, radius: 10) {
                    Label(T("Podłącz kartę albo dysk. Karty z aparatu (DCIM, Sony M4ROOT) są rozpoznawane automatycznie."), systemImage: "sdcard")
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
                                if v.isCard { Text(T("karta z aparatu")).font(.system(size: 10.5, weight: .medium)).foregroundStyle(FeatureColor.card) }
                            }
                            Text(T("%@ zajęte z %@ · wolne %@", "\(Fmt.bytes(v.total - v.free))", "\(Fmt.bytes(v.total))", "\(Fmt.bytes(v.free))")).font(.system(size: 11)).foregroundStyle(.secondary)
                            if prefs.auto.showDriveDetails, let d = DriveText.detail(v, prefs) {
                                Text(d).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            if prefs.auto.showDriveDetails, let w = DriveText.slowWarning(v) {
                                Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(.orange)
                            }
                        }
                        .contextMenu { Button(T("Zmień opis dysku…")) { DriveText.rename(v, prefs) } }
                        Spacer()
                        Button(T("Co jest zgrane?")) { model.startCard(v.url) }.disabled(model.card?.isBusy == true)
                            .help(T("Sprawdza, które pliki mają już kopię (i gdzie), a których nie ma nigdzie"))
                        Button(T("Duplikaty")) { app.duplicates.roots = [v.url]; app.mode = .duplicates; app.duplicates.start() }
                        Button { model.eject(v.url) } label: { Image(systemName: "eject") }
                            .help(T("Wysuń")).accessibilityLabel(T("Wysuń %@", "\(v.name)"))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    var searchPlaces: some View {
        SectionCard(title: T("Gdzie szukać kopii plików z karty"), footer: T("Tu DupliKAT sprawdza, czy pliki z karty już gdzieś są — po zawartości, nie po nazwie.")) {
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
        case .card: return T("Zgrywanie „%@”", "\(job.sourceName)")
        case .pairAdd: return T("Dogrywanie brakujących — %@", "\(job.sourceName)")
        case .mirror: return T("Lustro — %@", "\(job.sourceName)")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                IconCircle(symbol: job.kind == .mirror ? "rectangle.on.rectangle.angled" : "sdcard.fill", color: job.kind == .mirror ? Theme.missing : FeatureColor.card, size: 34)
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer()
                if !job.isBusy { Button { model.close() } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 16)) }.buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel(T("Zamknij")).help(T("Zamknij")) }
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
                Text(T("Dokąd:")).font(.system(size: 12))
                Menu {
                    ForEach(prefs.auto.destinations) { d in
                        Button { job.destination = d; job.replan() } label: { Text(d.title + (d.isAvailable ? "" : T(" (niepodłączony)"))) }.disabled(!d.isAvailable)
                    }
                    Divider()
                    Button(T("Inny folder…")) {
                        if let u = FileActions.chooseFolder(title: T("Dokąd zgrać tę kartę?"), prompt: T("Wybierz")).first {
                            let d = Destination(path: u.path)
                            if !prefs.auto.destinations.contains(where: { $0.path == d.path }) { prefs.auto.destinations.append(d) }
                            job.destination = prefs.auto.destinations.first { $0.path == d.path }; job.replan()
                        }
                    }
                } label: { Text(job.destination?.title ?? T("Wybierz cel…")) }
                    .fixedSize()
                    .disabled(job.isBusy)
                if let t = job.targetFolder { Text("→ \(Fmt.path(t.path))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            HStack(spacing: 14) {
                TemplateField(template: Binding(get: { job.template }, set: { job.template = $0 }))
                    .onSubmit { job.replan() }
                    .disabled(job.isBusy)
                Toggle(T("Sprawdź kopie bajt po bajcie"), isOn: Binding(get: { job.verify }, set: { job.verify = $0 })).toggleStyle(.checkbox).font(.system(size: 11.5))
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder var ready: some View {
        if job.kind == .mirror, let m = job.mirror { mirrorReady(m) } else if let p = job.plan {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    StatBadge(value: "\(p.toCopy.count)", label: T("nowych plików · %@", "\(Fmt.bytes(p.bytes))"), color: FeatureColor.card)
                    StatBadge(value: "\(p.alreadyThere.count)", label: T("już jest w celu (pomijam)"), color: Theme.safe)
                }
                if p.toCopy.isEmpty {
                    Label(T("Wszystko już jest w celu — nie ma czego kopiować."), systemImage: "checkmark.seal.fill").foregroundStyle(Theme.safe).font(.system(size: 12.5, weight: .medium))
                    if job.kind == .card { formatOffer }
                } else {
                    FileListPreview(items: p.toCopy.map { ($0.source.lastPathComponent, Fmt.path($0.target.deletingLastPathComponent().path), $0.size) })
                    HStack {
                        Text(T("Niczego nie nadpisuję ani nie usuwam — tylko dodaję nowe pliki.")).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button(T("Anuluj")) { model.close() }
                        Button { job.run() } label: { Label(T("Zgraj %@", "\(Fmt.files(p.toCopy.count))"), systemImage: "arrow.down.doc") }
                            .buttonStyle(GradientButtonStyle())
                    }
                }
            }
        }
    }

    func mirrorReady(_ m: Transfer.MirrorPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 18) {
                StatBadge(value: "\(m.toCopy.count)", label: T("do skopiowania"), color: FeatureColor.card)
                StatBadge(value: "\(m.toReplace.count)", label: T("zmienionych — stara wersja do Kosza"), color: Theme.warn)
                StatBadge(value: "\(m.toTrash.count)", label: T("nadmiarowych w celu — do Kosza"), color: Theme.missing)
            }
            if !m.toTrash.isEmpty || !m.toReplace.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(T("Lustro usuwa z celu wszystko, czego nie ma w źródle. Te pliki trafią do Kosza celu:"), systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.missing)
                    FileListPreview(items: m.toTrash.map { ($0.name, Fmt.path($0.folder), $0.size) } + m.toReplace.map { ($0.lastPathComponent + T(" (stara wersja)"), Fmt.path($0.deletingLastPathComponent().path), 0) })
                    Toggle(T("Rozumiem — %@ z celu trafi do Kosza", "\(Fmt.files(m.toTrash.count + m.toReplace.count))"), isOn: Binding(get: { job.mirrorConfirmed }, set: { job.mirrorConfirmed = $0 }))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.missing.opacity(0.08)))
            }
            HStack {
                Spacer()
                Button(T("Anuluj")) { model.close() }
                Button { job.run() } label: { Label(T("Zrób lustro"), systemImage: "rectangle.on.rectangle.angled") }
                    .buttonStyle(.borderedProminent).tint(Theme.missing)
                    .disabled((m.toCopy.isEmpty && m.toTrash.isEmpty && m.toReplace.isEmpty) || (!(m.toTrash.isEmpty && m.toReplace.isEmpty) && !job.mirrorConfirmed))
            }
        }
    }

    @ViewBuilder var report: some View {
        if let r = job.result {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 18) {
                    StatBadge(value: "\(r.copied.count)", label: job.verify ? T("skopiowanych i sprawdzonych") : "skopiowanych", color: Theme.safe)
                    if !r.failed.isEmpty { StatBadge(value: "\(r.failed.count)", label: T("nieudanych"), color: Theme.missing) }
                    if !r.skippedExisting.isEmpty { StatBadge(value: "\(r.skippedExisting.count)", label: T("już istniało w celu"), color: .secondary) }
                    if job.mirrorTrashed > 0 { StatBadge(value: "\(job.mirrorTrashed)", label: T("przeniesionych do Kosza"), color: Theme.warn) }
                }
                ForEach(r.failed.prefix(8), id: \.0.id) { f in
                    Label("\(f.0.source.lastPathComponent): \(f.1)", systemImage: "xmark.octagon").font(.system(size: 11)).foregroundStyle(Theme.missing)
                }
                HStack {
                    if let t = job.targetFolder { Button { NSWorkspace.shared.open(t) } label: { Label(T("Otwórz folder"), systemImage: "folder") } }
                    Spacer()
                    Button(T("Gotowe")) { model.close() }
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
                Label(T("Karta „%@” jest w całości zgrana. Sformatować ją?", "\(vol.lastPathComponent)"), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.safe)
                Text(T("Najzdrowiej dla karty jest sformatować ją w aparacie. Jeśli wolisz na Macu: otworzę systemowe Narzędzie dyskowe — wybierz po lewej „%@”, kliknij Wymaż i format ExFAT. DupliKAT sam niczego nie formatuje.", "\(vol.lastPathComponent)"))
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button { model.openDiskUtility(for: job.cardVolume) } label: { Label(T("Otwórz Narzędzie dyskowe"), systemImage: "internaldrive") }
                    Button { model.eject(vol); model.close() } label: { Label(T("Wysuń kartę (sformatuję w aparacie)"), systemImage: "eject") }
                    Spacer()
                    Button(T("Nie teraz")) { model.close() }
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
            Text(pair.source.isEmpty ? T("Nowa para") : T("Edytuj parę")).font(.system(size: 15, weight: .semibold))
            TextField(T("Nazwa, np. „Karty → M”"), text: $pair.name).textFieldStyle(.roundedBorder)
            pathRow(T("Źródło (np. karta, folder roboczy)"), $pair.source)
            pathRow("Cel (archiwum)", $pair.target)
            Toggle(T("Porównuj automatycznie po podłączeniu dysku (tylko odczyt, potem powiadomienie)"), isOn: $pair.runOnMount).toggleStyle(.checkbox)
            HStack {
                Spacer()
                Button(T("Anuluj")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(T("Zapisz")) { onSave(pair); dismiss() }.keyboardShortcut(.defaultAction)
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
                Text(path.wrappedValue.isEmpty ? T("nie wybrano") : Fmt.path(path.wrappedValue)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(path.wrappedValue.isEmpty ? .secondary : .primary)
                Spacer()
                Button(T("Wybierz…")) { if let u = FileActions.chooseFolder(title: label, prompt: T("Wybierz")).first { path.wrappedValue = u.path } }
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
                Caption(T("Zapisane pary — porównuj jednym kliknięciem")).padding(.leading, 4)
                Spacer()
                Button { editingPair = ComparePair(name: "", source: app.backup.sources.first?.path ?? "", target: app.backup.backups.first?.path ?? "") } label: {
                    Label(T("Zapisz parę…"), systemImage: "plus")
                }.controlSize(.small).help(T("Zapisuje źródło i archiwum jako stałą parę (możesz je zmienić)"))
            }
            if prefs.auto.pairs.isEmpty {
                Card(padding: 14, radius: 10) {
                    Text(T("Porównujesz coś regularnie, np. „T7-2 ▸ karta 1” z „M ▸ BACKUP KART”? Zapisz to jako parę — potem jednym kliknięciem porównasz, dograsz brakujące albo zrobisz lustro."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(prefs.auto.pairs) { p in
                Card(padding: 12, radius: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconCircle(symbol: "arrow.left.arrow.right", color: FeatureColor.pair, on: p.isAvailable, size: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name.isEmpty ? T("Para") : p.name).font(.system(size: 13, weight: .semibold))
                                Text("\(Fmt.path(p.source))  →  \(Fmt.path(p.target))").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                if !p.isAvailable { Text(T("Któryś dysk jest niepodłączony")).font(.system(size: 10.5)).foregroundStyle(Theme.warn) }
                            }
                            Spacer()
                            Menu {
                                Button(T("Edytuj…")) { editingPair = p }
                                Button(T("Usuń parę"), role: .destructive) { prefs.auto.pairs.removeAll { $0.id == p.id } }
                            } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(T("Opcje pary"))
                        }
                        HStack(spacing: 8) {
                            Button { app.automation.runPairCompare(p, notify: false) } label: { Label(T("Porównaj"), systemImage: "magnifyingglass") }
                                .help(T("Tylko odczyt — pokazuje, czego brakuje w celu"))
                            Button { model.startPair(p, mirror: false) } label: { Label(T("Dograj brakujące…"), systemImage: "plus.square.on.square") }
                                .help(T("Kopiuje do celu tylko to, czego tam nie ma. Niczego w celu nie usuwa."))
                            Button { model.startPair(p, mirror: true) } label: { Label(T("Lustro…"), systemImage: "rectangle.on.rectangle.angled") }
                                .help(T("Cel = dokładna kopia źródła. Nadmiarowe pliki w celu trafią do Kosza — zobaczysz listę przed startem."))
                            Spacer()
                            Toggle(T("Porównuj po podłączeniu"), isOn: Binding(get: { p.runOnMount }, set: { v in
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
