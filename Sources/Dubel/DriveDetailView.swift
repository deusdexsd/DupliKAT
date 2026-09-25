import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Ekran dysku (klik w dysk w pasku bocznym): podsumowanie, rola, kopie, akcje i historia działań.
/// Działa też dla dysku odłączonego — wtedy z zapamiętanej zawartości.
struct DriveDetailScreen: View {
    let key: String
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var prefs: Prefs

    var volume: VolumeUsage? { app.volumes.first { $0.key == key } }
    var memory: DriveMemory { app.drives }
    var catalog: DriveCatalog? { memory.catalogs[key] }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let v = volume { capacity(v) } else { offlineBanner }
                backups
                if volume != nil { actions }
                history
            }
            .padding(20)
        }
    }

    // MARK: Nagłówek

    var header: some View {
        let v = volume
        let isCard = v?.isCard ?? false
        return HStack(alignment: .center, spacing: 14) {
            IconCircle(symbol: isCard ? "sdcard.fill" : (v == nil ? "externaldrive.badge.xmark" : "externaldrive.fill"),
                       color: isCard ? FeatureColor.card : FeatureColor.volume, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(memory.name(key)).font(.system(size: 22, weight: .bold))
                if let v, let d = DriveText.detail(v, prefs) {
                    Text(d).font(.system(size: 12)).foregroundStyle(.secondary)
                } else if v == nil {
                    Text(T("Dysk odłączony")).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if let v, let w = DriveText.slowWarning(v) {
                    Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            Spacer()
            if !isCard && v?.url.path != "/" { DriveRoleMenu(key: key, memory: memory) }
            if let v {
                Button(T("Zmień opis…")) { DriveText.rename(v, prefs) }.controlSize(.small)
                Button { NSWorkspace.shared.activateFileViewerSelecting([v.url]) } label: { Image(systemName: "folder") }
                    .controlSize(.small).help(T("Pokaż w Finderze")).accessibilityLabel(T("Pokaż w Finderze"))
                if v.url.path != "/" {
                    Button { app.transfer.eject(v.url); app.selectedDrive = nil } label: { Image(systemName: "eject") }
                        .controlSize(.small).help(T("Wysuń")).accessibilityLabel(T("Wysuń %@", "\(v.name)"))
                }
            }
        }
    }

    // MARK: Miejsce

    func capacity(_ v: VolumeUsage) -> some View {
        Card(padding: 14, radius: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Fmt.bytes(v.free)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                        .foregroundStyle(Theme.fullness(v.used))
                    Text(T("wolne z %@", "\(Fmt.bytes(v.total))")).font(.system(size: 13)).foregroundStyle(.secondary)
                    Spacer()
                    Text(T("zajęte %@", "\(Fmt.percent(v.used))")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.08))
                        Capsule().fill(Theme.fullness(v.used).gradient).frame(width: g.size.width * v.used)
                    }
                }
                .frame(height: 10)
                HStack(spacing: 16) {
                    if let c = catalog {
                        Label(T("Znam %@ (stan z %@)", "\(Fmt.files(c.items.count))", "\(Fmt.date.string(from: c.date))"), systemImage: "brain")
                    } else if prefs.auto.rememberDrives && !v.isCard && v.url.path != "/" {
                        Label(T("Jeszcze nie zapamiętałem zawartości"), systemImage: "brain")
                    }
                    if let i = memory.indexing, i.key == key {
                        ProgressView().controlSize(.mini)
                        Text(T("zapamiętuję…"))
                    }
                }
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
        }
    }

    var offlineBanner: some View {
        Card(padding: 14, radius: 12) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.badge.xmark").font(.system(size: 22)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(T("Dysk jest odłączony")).font(.system(size: 13, weight: .semibold))
                    if let c = catalog {
                        Text(T("Znam jego zawartość: %@, %@ (stan z %@). Kopie na nim liczą się przy sprawdzaniu kart i folderów — po nazwie i rozmiarze.", "\(Fmt.files(c.items.count))", "\(Fmt.bytes(c.totalSize))", "\(Fmt.date.string(from: c.date))"))
                            .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(T("Zapomnij dysk")) { memory.forget(key); app.selectedDrive = nil }.controlSize(.small)
                    .help(T("Usuwa tylko zapamiętaną listę plików w DupliKAT — nie dotyka dysku"))
            }
        }
    }

    // MARK: Kopie

    @ViewBuilder var backups: some View {
        let asSource = memory.pending(for: key)
        let asCopy = memory.role(key)?.of.map { src in memory.pending(for: src).filter { $0.backup == key } } ?? []
        let rows = asSource + asCopy
        if memory.role(key) != nil {
            SectionCard(title: T("Kopie")) {
                if rows.isEmpty {
                    Text(memory.role(key)?.kind == .ingest && memory.backupKeys(of: key).isEmpty
                         ? T("Ten backup nie ma jeszcze kopii. Oznacz inny dysk jako „kopia backupu %@”.", "\(memory.name(key))")
                         : T("Czekam, aż zapamiętam zawartość obu dysków — wtedy policzę, co dograć."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { i, p in
                    if i > 0 { Divider() }
                    if p.count == 0 {
                        Label(T("%@ → %@: wszystko ma kopię", "\(memory.name(p.ingest))", "\(memory.name(p.backup))"), systemImage: "checkmark.shield.fill")
                            .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.safe)
                    } else {
                        PendingBackupRow(p: p, memory: memory)
                    }
                }
            }
        }
    }

    // MARK: Akcje

    var actions: some View {
        let v = volume!
        return SectionCard(title: T("Co zrobić z tym dyskiem")) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 10)], spacing: 10) {
                if v.isCard {
                    ActionTile(symbol: "sdcard.fill", color: FeatureColor.card, title: T("Co jest zgrane?"), subtitle: T("Które pliki z karty mają już kopię i gdzie")) {
                        app.transfer.startCard(v.url)
                    }
                } else {
                    ActionTile(symbol: "questionmark.folder.fill", color: FeatureColor.card, title: T("Czy ma kopie gdzie indziej?"), subtitle: T("Pliki z tego dysku, których nie ma na innych dyskach")) {
                        app.transfer.startCard(v.url)
                    }
                }
                ActionTile(symbol: Mode.duplicates.symbol, color: Mode.duplicates.color, title: T("Szukaj duplikatów"), subtitle: T("Identyczne pliki na tym dysku")) {
                    app.duplicates.roots = [v.url]; app.mode = .duplicates; app.duplicates.start()
                }
                ActionTile(symbol: Mode.photos.symbol, color: Mode.photos.color, title: T("Podobne zdjęcia"), subtitle: T("Serie i te same zdjęcia w innym rozmiarze")) {
                    app.photos.roots = [v.url]; app.mode = .photos; app.photos.start()
                }
                if app.visibleModes.contains(.fcp) {
                    ActionTile(symbol: Mode.fcp.symbol, color: Mode.fcp.color, title: T("Pliki montażowe"), subtitle: T("Rendery, proxy i cache na tym dysku")) {
                        app.fcp.roots = [v.url]; app.mode = .fcp; app.fcp.start()
                    }
                }
                if !v.isCard && v.url.path != "/" && prefs.auto.rememberDrives {
                    ActionTile(symbol: "brain", color: FeatureColor.pair, title: T("Zapamiętaj zawartość teraz"), subtitle: T("Odśwież listę plików (tylko odczyt, w tle)")) {
                        memory.remember(v, force: true)
                    }
                }
            }
        }
    }

    // MARK: Historia

    var history: some View {
        let events = memory.history[key] ?? []
        return SectionCard(title: T("Historia")) {
            if events.isEmpty {
                Text(T("Nic jeszcze nie robiłem z tym dyskiem.")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(Array(events.prefix(30).enumerated()), id: \.element.id) { i, e in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Image(systemName: e.symbol).frame(width: 18).foregroundStyle(.secondary)
                    Text(e.text).font(.system(size: 12)).lineLimit(2)
                    Spacer()
                    Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !events.isEmpty {
                Divider()
                Button(T("Wyczyść historię")) { memory.clearHistory(key) }.buttonStyle(.borderless).font(.system(size: 11.5))
            }
        }
    }
}

/// Duży przycisk akcji: ikona, tytuł, opis.
struct ActionTile: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconCircle(symbol: symbol, color: color, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.primary)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(QuickRowStyle())
    }
}
