import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Opis dysku do pokazania pod nazwą: „Samsung PSSD T7 · USB 3.2 Gen 2 · 10 Gb/s (~1 GB/s)”.
@MainActor
enum DriveText {
    static func label(_ v: VolumeUsage, _ prefs: Prefs) -> String? {
        if let own = prefs.auto.driveLabels[v.key], !own.isEmpty { return own }
        return v.drive?.displayModel
    }

    static func connection(_ d: DriveInfo?) -> String? {
        guard let d else { return nil }
        switch d.interconnect {
        case "USB":
            guard let s = d.linkSpeed, let std = d.usbStandard else { return "USB" }
            var t = "\(std) · \(DriveInfo.formatBits(s))"
            if let b = d.approxBytesPerSecond { t += T(" (do ~%@/s)", "\(Fmt.bytes(b))") }
            return t
        case "Thunderbolt": return "Thunderbolt"
        case "SD", "Secure Digital": return T("czytnik kart SD")
        case "Apple Fabric": return T("dysk wewnętrzny")
        case "PCI-Express": return d.isInternal ? T("dysk wewnętrzny") : "Thunderbolt / PCIe"
        case let other?: return other
        case nil: return nil
        }
    }

    static func detail(_ v: VolumeUsage, _ prefs: Prefs) -> String? {
        let parts = [label(v, prefs), connection(v.drive)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Zbyt wolne łącze dla dysku zewnętrznego — najczęściej kabel albo port USB 2.0.
    static func slowWarning(_ v: VolumeUsage) -> String? {
        guard let d = v.drive, d.interconnect == "USB", d.isSlowLink, !v.isCard else { return nil }
        return T("Wolne połączenie — sprawdź kabel albo port (USB 2.0 daje ok. 40 MB/s)")
    }

    /// Własny opis dysku (np. zamiast dziwnej nazwy od producenta).
    @MainActor static func rename(_ v: VolumeUsage, _ prefs: Prefs) {
        let alert = NSAlert()
        alert.messageText = T("Opis dysku „%@”", "\(v.name)")
        alert.informativeText = T("Pokazuje się pod nazwą dysku zamiast nazwy od producenta. Zostaw puste, żeby wrócić do nazwy producenta.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = prefs.auto.driveLabels[v.key] ?? v.drive?.displayModel ?? ""
        field.placeholderString = v.drive?.displayModel ?? T("np. Samsung T7 2 TB")
        alert.accessoryView = field
        alert.addButton(withTitle: T("Zapisz"))
        alert.addButton(withTitle: T("Anuluj"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        if text.isEmpty || text == v.drive?.displayModel { prefs.auto.driveLabels[v.key] = nil } else { prefs.auto.driveLabels[v.key] = text }
    }
}

/// Wiersz dysku: nazwa, wolne miejsce, pasek zajętości i (opcjonalnie) model + prędkość łącza.
struct DriveRow: View {
    let volume: VolumeUsage
    var barHeight: CGFloat = 5
    @EnvironmentObject var prefs: Prefs
    @EnvironmentObject var app: AppModel

    var body: some View {
        let v = volume
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if v.isCard { Image(systemName: "sdcard.fill").font(.system(size: 9.5)).foregroundStyle(FeatureColor.card) }
                Text(v.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer()
                Text(T("wolne %@", "\(Fmt.bytes(v.free))")).font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Theme.fullness(v.used).gradient).frame(width: g.size.width * v.used)
                }
            }
            .frame(height: barHeight)
            if prefs.auto.showDriveDetails, let d = DriveText.detail(v, prefs) {
                Text(d).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
            if prefs.auto.showDriveDetails, let w = DriveText.slowWarning(v) {
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange).lineLimit(2)
            }
            if let role = app.drives.roleTitle(v.key) {
                Text(role).font(.system(size: 10, weight: .medium)).foregroundStyle(FeatureColor.volume)
            }
        }
        .help(T("%@: zajęte %@ z %@", "\(v.name)", "\(Fmt.percent(v.used))", "\(Fmt.bytes(v.total))"))
        .contextMenu {
            Button(T("Zmień opis dysku…")) { DriveText.rename(v, prefs) }
            Button(T("Pokaż w Finderze")) { NSWorkspace.shared.activateFileViewerSelecting([v.url]) }
            Toggle(T("Pokazuj model i prędkość dysków"), isOn: Binding(get: { prefs.auto.showDriveDetails }, set: { prefs.auto.showDriveDetails = $0 }))
        }
    }
}

/// Wybór roli dysku: zwykły / backup / kopia innego backupu.
struct DriveRoleMenu: View {
    let key: String
    @ObservedObject var memory: DriveMemory
    @EnvironmentObject var prefs: Prefs

    var body: some View {
        let ingests = prefs.auto.driveRoles.filter { $0.value.kind == .ingest && $0.key != key }.keys.sorted()
        Menu(memory.roleTitle(key) ?? T("zwykły dysk")) {
            Button(T("Zwykły dysk")) { memory.setRole(key, nil) }
            Button(T("Backup (tu zgrywam karty, eksporty, projekty)")) { memory.setRole(key, DriveRole(kind: .ingest)) }
            if !ingests.isEmpty {
                Divider()
                ForEach(ingests, id: \.self) { k in
                    Button(T("Kopia backupu %@", "\(memory.name(k))")) { memory.setRole(key, DriveRole(kind: .backup, of: k)) }
                }
            } else {
                Text(T("Kopia backupu… (najpierw oznacz któryś dysk jako „backup”)"))
            }
        }
        .fixedSize()
        .controlSize(.small)
    }
}

/// „M → M2: 124 pliki czekają na kopię (40 GB)” + Dograj, gdy oba dyski są podłączone.
struct PendingBackupRow: View {
    let p: DriveMemory.Pending
    @ObservedObject var memory: DriveMemory
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Theme.warn)
                Text(T("%@ → %@: bez kopii %@", "\(memory.name(p.ingest))", "\(memory.name(p.backup))", "\(Fmt.files(p.count))"))
                    .font(.system(size: compact ? 11.5 : 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 4)
                if p.backupMounted && memory.isMounted(p.ingest) {
                    Button(T("Dograj…")) { memory.copyPending(p) }.controlSize(.small)
                        .help(T("Kopiuje na %@ tylko to, czego tam nie ma — z zachowaniem folderów. Niczego nie usuwa.", "\(memory.name(p.backup))"))
                }
            }
            Text(p.backupMounted ? Fmt.bytes(p.size) : T("%@ · stan %@ z %@ (dysk niepodłączony)", "\(Fmt.bytes(p.size))", "\(memory.name(p.backup))", "\(Fmt.date.string(from: p.backupDate))"))
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            if p.backupMounted, let free = memory.app?.volumes.first(where: { $0.key == p.backup })?.free, free < p.size {
                Label(T("Za mało miejsca na %@ (wolne %@) — dograj część albo zwolnij miejsce.", "\(memory.name(p.backup))", "\(Fmt.bytes(free))"), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 10.5)).foregroundStyle(.orange)
            }
        }
    }
}
