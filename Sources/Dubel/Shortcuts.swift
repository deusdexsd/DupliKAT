import AppKit
import Carbon.HIToolbox
import DubelCore
import MidniteUIKit
import SwiftUI

/// Skrót klawiszowy (kod klawisza + modyfikatory Carbon).
struct HotKeySpec: Codable, Equatable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let cmd: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    /// ⌃⌥⌘K — trzy modyfikatory, mało prawdopodobne, że coś koliduje.
    static let suggestedCheck = HotKeySpec(keyCode: 40, modifiers: control | option | cmd)
    static let suggestedWindow = HotKeySpec(keyCode: 2, modifiers: control | option | cmd) // ⌃⌥⌘D
}

/// Czynności dostępne ze skrótu, Stream Decka (adres duplikat://…) i menu w pasku.
enum QuickAction: String, CaseIterable, Identifiable {
    case checkSelection = "check-selection"
    case checkCard = "check-card"
    case duplicatesSelection = "duplicates-selection"
    case toggleWindow = "toggle"
    case measureSystem = "system"
    case settings = "settings"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .checkSelection: return T("Sprawdź zaznaczone w Finderze (albo podłączoną kartę)")
        case .checkCard: return T("Sprawdź podłączoną kartę")
        case .duplicatesSelection: return T("Szukaj duplikatów w zaznaczonym folderze")
        case .toggleWindow: return T("Pokaż / schowaj okno")
        case .measureSystem: return T("Zmierz dane systemowe")
        case .settings: return T("Otwórz Ustawienia")
        }
    }

    var url: String { "duplikat://\(rawValue)" }
}

// MARK: - Globalne skróty (Carbon, bez uprawnień Dostępności)

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    /// Rejestruje (albo zdejmuje, gdy nil) skrót o danym numerze. Zwraca false, gdy system odmówił (skrót zajęty).
    @discardableResult
    func set(_ id: UInt32, _ spec: HotKeySpec?, handler: @escaping () -> Void) -> Bool {
        if let r = refs[id] { UnregisterEventHotKey(r); refs[id] = nil }
        handlers[id] = handler
        guard let spec else { return true }
        installOnce()
        var r: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4455504B), id: id) // 'DUPK'
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hk, GetApplicationEventTarget(), 0, &r)
        if status == noErr { refs[id] = r }
        return status == noErr
    }

    fileprivate func fire(_ id: UInt32) { handlers[id]?() }

    private func installOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotkeyCenter.shared.fire(id) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

enum HotKeyText {
    static func string(_ s: HotKeySpec) -> String {
        var t = ""
        if s.modifiers & HotKeySpec.control != 0 { t += "⌃" }
        if s.modifiers & HotKeySpec.option != 0 { t += "⌥" }
        if s.modifiers & HotKeySpec.shift != 0 { t += "⇧" }
        if s.modifiers & HotKeySpec.cmd != 0 { t += "⌘" }
        return t + keyName(s.keyCode)
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.control) { m |= HotKeySpec.control }
        if f.contains(.option) { m |= HotKeySpec.option }
        if f.contains(.shift) { m |= HotKeySpec.shift }
        if f.contains(.command) { m |= HotKeySpec.cmd }
        return m
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [49: T("Spacja"), 36: "Enter", 48: "Tab", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        if let n = special[code] { return n }
        let letters: [UInt32: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
                                         18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0"]
        return letters[code] ?? "klawisz \(code)"
    }
}

/// Pole „nagraj skrót”: klikasz, naciskasz kombinację (z co najmniej jednym ⌘/⌃/⌥), gotowe. Esc anuluje.
struct HotKeyRecorder: View {
    @Binding var spec: HotKeySpec?
    var suggested: HotKeySpec
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? T("Naciśnij skrót…") : spec.map(HotKeyText.string) ?? T("Brak"))
                    .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                    .frame(minWidth: 96)
            }
            .buttonStyle(GradientButtonStyle(prominent: recording))
            if spec == nil {
                Button(T("Użyj %@", "\(HotKeyText.string(suggested))")) { spec = suggested }.buttonStyle(.borderless).font(.system(size: 11))
            } else {
                Button { spec = nil } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help(T("Wyłącz skrót")).accessibilityLabel(T("Wyłącz skrót"))
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }
            let mods = HotKeyText.carbon(e.modifierFlags)
            guard mods & (HotKeySpec.cmd | HotKeySpec.control | HotKeySpec.option) != 0 else { NSSound.beep(); return nil }
            spec = HotKeySpec(keyCode: UInt32(e.keyCode), modifiers: mods)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - Wykonanie czynności

@MainActor
enum QuickActions {
    /// Zaznaczenie w Finderze — pliki i foldery (albo folder przedniego okna Findera, gdy nic nie jest zaznaczone).
    /// Przez AppleScript: przy pierwszym użyciu macOS pyta o zgodę. `nil` = brak zgody.
    static func finderSelection() -> [URL]? {
        let src = """
        tell application "Finder"
            set out to {}
            set sel to selection
            if (count of sel) > 0 then
                repeat with i in sel
                    set end of out to POSIX path of (i as alias)
                end repeat
            else if (count of Finder windows) > 0 then
                set end of out to POSIX path of (target of front Finder window as alias)
            end if
            return out
        end tell
        """
        var err: NSDictionary?
        guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err) else {
            let code = err?[NSAppleScript.errorNumber] as? Int ?? 0
            return code == -1743 || code == -1744 ? nil : []
        }
        var urls: [URL] = []
        if res.numberOfItems > 0 {
            for i in 1...res.numberOfItems { if let p = res.atIndex(i)?.stringValue { urls.append(URL(fileURLWithPath: p)) } }
        } else if let p = res.stringValue { urls.append(URL(fileURLWithPath: p)) }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Czynność startuje od razu w tle; postęp i wynik widać w okienku przy pasku menu (i w powiadomieniu po skończeniu).
    static func run(_ a: QuickAction, app: AppModel, delegate: AppDelegate?) {
        app.quickNote = nil
        switch a {
        case .checkSelection:
            guard let sel = selectionOrNote(app) else { return }
            if sel.isEmpty { checkCard(app: app) } else { checkInBackground(sel, app: app) }
        case .checkCard:
            checkCard(app: app)
        case .duplicatesSelection:
            guard let sel = selectionOrNote(app) else { return }
            guard !sel.isEmpty else { app.quickNote = QuickNote(text: T("Nic nie jest zaznaczone w Finderze. Zaznacz folder (albo pliki) i kliknij jeszcze raz.")); return }
            guard !app.duplicates.status.isRunning else { app.quickNote = QuickNote(text: T("Już szukam duplikatów — poczekaj, aż skończy się poprzedni skan.")); return }
            app.duplicates.roots = sel
            app.duplicates.onFinish = {
                let g = app.duplicates.groups
                let body = g.isEmpty ? T("Brak duplikatów.") : T("%@, do odzyskania %@. Nic nie zostało usunięte.", "\(Fmt.groups(g.count))", "\(Fmt.bytes(app.duplicates.reclaimable))")
                app.quickNote = QuickNote(text: T("Duplikaty: %@", "\(sel.map(\.lastPathComponent).joined(separator: ", "))") + " — " + body, isError: false, mode: g.isEmpty ? nil : .duplicates)
                Notifier.send(T("Duplikaty: %@", "\(sel.map(\.lastPathComponent).joined(separator: ", "))"), body, mode: .duplicates)
            }
            app.duplicates.start()
        case .toggleWindow: delegate?.toggleMain()
        case .measureSystem: app.system.measure()
        case .settings: delegate?.showSettings()
        }
    }

    /// Zaznaczenie z Findera albo komunikat w okienku, gdy macOS nie dał zgody (wtedy `nil`).
    private static func selectionOrNote(_ app: AppModel) -> [URL]? {
        guard let sel = finderSelection() else {
            app.quickNote = QuickNote(text: T("macOS nie pozwala mi odczytać zaznaczenia w Finderze. Włącz DupliKAT → Finder w Ustawieniach systemowych → Prywatność i ochrona → Automatyzacja."), privacyLink: true)
            return nil
        }
        return sel
    }

    private static func checkCard(app: AppModel) {
        if let card = app.volumes.first(where: \.isCard) { checkInBackground([card.url], app: app, card: true) }
        else { app.quickNote = QuickNote(text: T("Nic nie jest zaznaczone w Finderze i nie widzę karty. Zaznacz pliki albo folder i kliknij jeszcze raz.")) }
    }

    /// Sprawdzenie w tle — bez otwierania okna. Postęp i wynik w okienku przy pasku menu, na koniec powiadomienie.
    private static func checkInBackground(_ urls: [URL], app: AppModel, card: Bool = false) {
        guard app.transfer.card?.isBusy != true else { app.quickNote = QuickNote(text: T("Już sprawdzam — poczekaj, aż skończy się poprzednie sprawdzanie.")); return }
        let (mode, drive) = (app.mode, app.selectedDrive)
        if card { app.transfer.startCard(urls[0], automatic: true) } else { app.transfer.startSelection(urls) }
        if app.mode != mode { app.mode = mode } // nie przełączaj widoku, jeśli okno jest otwarte na czymś innym
        app.selectedDrive = drive
    }
}

/// Krótki komunikat w okienku przy pasku menu (błąd albo wynik szybkiej akcji).
struct QuickNote: Equatable {
    var text: String
    var isError = true
    var mode: Mode?
    var privacyLink = false
}

/// Karta w Ustawieniach: skróty klawiszowe + adresy do Stream Decka (jak w Ogarze).
struct ShortcutsSettings: View {
    @EnvironmentObject var prefs: Prefs
    @State private var copied: String?

    var body: some View {
        Group {
            SectionCard(title: T("Skróty klawiszowe"), footer: T("Działają w każdej aplikacji, także w Final Cut. Nie wymagają żadnych uprawnień.")) {
                SettingRow(title: T("Sprawdź zaznaczone w Finderze"), subtitle: T("Folder albo karta zaznaczona w Finderze — sprawdzanie w tle")) {
                    HotKeyRecorder(spec: $prefs.auto.hotkeyCheck, suggested: .suggestedCheck)
                }
                Divider()
                SettingRow(title: T("Pokaż / schowaj okno")) {
                    HotKeyRecorder(spec: $prefs.auto.hotkeyWindow, suggested: .suggestedWindow)
                }
            }
            SectionCard(title: T("Stream Deck"), footer: T("W Stream Decku: akcja „Website” (albo „Open”), wklej adres. Przy pierwszym „Sprawdź zaznaczone” macOS zapyta, czy DupliKAT może czytać zaznaczenie w Finderze.")) {
                ForEach(QuickAction.allCases) { a in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.system(size: 12.5))
                            Text(a.url).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.url, forType: .string); copied = a.url
                        } label: { Image(systemName: copied == a.url ? "checkmark" : "doc.on.doc") }
                            .buttonStyle(.borderless).help(T("Kopiuj adres")).accessibilityLabel(T("Kopiuj %@", "\(a.url)"))
                    }
                    if a != QuickAction.allCases.last { Divider() }
                }
            }
        }
    }
}
