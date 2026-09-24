import AppKit
import DubelCore
import SwiftUI

/// Tylko do rozwoju: DUBEL_SHOTS=<folder> uruchamia prawdziwe skany na folderze DUBEL_DEMO_ROOT (tylko odczyt),
/// zapisuje zrzuty okien w jasnym i ciemnym wyglądzie i zamyka aplikację. W zwykłym uruchomieniu nic nie robi.
@MainActor
enum DevShots {
    static func runIfRequested(app: AppModel, prefs: Prefs, delegate: AppDelegate) async {
        let env = ProcessInfo.processInfo.environment
        guard let out = env["DUBEL_SHOTS"], let demo = env["DUBEL_DEMO_ROOT"] else { return }
        let root = URL(fileURLWithPath: demo)
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        prefs.minSizeMB = 0.1

        // Przewodnik — każdy krok.
        delegate.showOnboarding()
        prefs.auto.searchLocations = [root.appendingPathComponent("dyski").path]
        prefs.auto.cardImportEnabled = true
        prefs.auto.spaceAlarmEnabled = true
        for i in 0..<6 {
            if i > 0 { NotificationCenter.default.post(name: .dubelOnboardingStep, object: i) }
            await shoot("o\(i)-przewodnik", out, windowID: "onboarding")
        }
        NSApp.windows.first { $0.identifier?.rawValue == "onboarding" }?.close()

        // Ustawienia — każda zakładka.
        delegate.showSettings()
        for (i, t) in [SettingsTab.general, .transfer, .rules, .alarms, .scanning].enumerated() {
            NotificationCenter.default.post(name: .dubelSettingsTab, object: t)
            await shoot("s\(i)-ustawienia", out, windowID: "settings")
        }
        NSApp.windows.first { $0.identifier?.rawValue == "settings" }?.close()

        delegate.showMain()
        app.duplicates.roots = [root.appendingPathComponent("dyski")]
        app.duplicates.start()
        app.mode = .duplicates
        while app.duplicates.status.isRunning { try? await Task.sleep(for: .milliseconds(200)) }
        await shoot("1-duplikaty-przewodnik", out)
        prefs.auto.uiStyle = "classic"
        await shoot("1-duplikaty-klasyczny", out)
        prefs.auto.uiStyle = "rich"

        // Samouczek — każdy krok.
        app.tourStep = 0
        app.tourActive = true
        for i in 0..<Tour.steps.count {
            app.tourStep = i
            await shoot("t\(i)-samouczek", out)
        }
        app.tourActive = false
        app.mode = .backup
        await shoot("4-porownaj", out)
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }), let tb = w.toolbar {
            print("TOOLBAR items:", tb.items.map(\.itemIdentifier.rawValue), "visible:", tb.visibleItems?.map(\.itemIdentifier.rawValue) ?? [])
            // zrzut całego okna przez system (z paskiem narzędzi)
            if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(w.windowNumber), [.boundsIgnoreFraming]) {
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out).appendingPathComponent("toolbar-okno.png"))
            }
        }

        // Zgrywanie: „karta” demo → cel M (tylko liczenie; kopiowanie nie jest uruchamiane).
        prefs.auto.pairs = [ComparePair(name: "Karty → M", source: root.appendingPathComponent("karta").path, target: root.appendingPathComponent("dyski/M").path, runOnMount: true)]
        app.transfer.startCard(root.appendingPathComponent("karta"))
        try? await Task.sleep(for: .milliseconds(300))
        while app.transfer.card?.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
        if let c = app.transfer.card { c.checked = Set(c.missing.prefix(1).map(\.id)) }
        await shoot("2-karta", out)
        app.transfer.closeCard()

        // Test reguły „kopiuj automatycznie” (kopie trafiają do folderu z wynikami zrzutów).
        let autoDir = URL(fileURLWithPath: out).appendingPathComponent("auto-kopia")
        try? FileManager.default.createDirectory(at: autoDir, withIntermediateDirectories: true)
        prefs.auto.cardAfterCheck = "auto"; prefs.auto.cardAutoFolder = autoDir.path
        app.transfer.startCard(root.appendingPathComponent("karta"), automatic: true)
        for _ in 0..<150 { try? await Task.sleep(for: .milliseconds(200)); if app.working == nil, app.transfer.card?.isBusy == false, app.transfer.card?.lastResult != nil { break } }
        let copied = (FileManager.default.enumerator(atPath: autoDir.path)?.allObjects as? [String]) ?? []
        print("AUTO-KOPIA:", app.transfer.card?.lastResult ?? "brak", copied.sorted())
        await shoot("2b-karta-po-auto", out)
        app.transfer.closeCard()
        if app.system.current != nil { app.mode = .system; await shoot("3-dane-systemowe", out) }

        print("DUBEL_SHOTS gotowe: \(out)")
        NSApp.terminate(nil)
    }

    static func shoot(_ name: String, _ dir: String, windowID: String = "main") async {
        for (suffix, appearance) in [("jasny", NSAppearance.Name.aqua), ("ciemny", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            try? await Task.sleep(for: .milliseconds(900))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == windowID }) else { continue }
            let target = window.attachedSheet ?? window
            guard let view = target.contentView?.superview ?? target.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
        }
        NSApp.appearance = nil
    }
}

extension Notification.Name {
    static let dubelOnboardingStep = Notification.Name("dubel.onboarding.step")
    static let dubelSettingsTab = Notification.Name("dubel.settings.tab")
}
