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
        if env["DUBEL_ONLY"] == "drives" { await driveShots(app: app, prefs: prefs, out: out, delegate: delegate); NSApp.terminate(nil); return }
        if env["DUBEL_ONLY"] == "popover" { await popoverShots(app: app, prefs: prefs, root: root, out: out); NSApp.terminate(nil); return }

        // Przewodnik — każdy krok.
        delegate.showOnboarding()
        prefs.auto.searchLocations = [root.appendingPathComponent("dyski").path]
        prefs.auto.cardImportEnabled = true
        prefs.auto.spaceAlarmEnabled = true
        for i in 0..<7 {
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
        prefs.resultsLayout = "grid"; await shoot("1-duplikaty-siatka", out)
        prefs.resultsLayout = "compact"; await shoot("1-duplikaty-kompakt", out)
        prefs.resultsLayout = "list"
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
        if let c = app.transfer.card {
            print("POMINIETE:", c.skippedOthers.map { "\($0.count) / \($0.size) B" } ?? "brak")
            c.checkRest()
            try? await Task.sleep(for: .milliseconds(300))
            while c.isBusy { try? await Task.sleep(for: .milliseconds(200)) }
            print("PO RESZCIE:", c.report?.entries.map { "\($0.file.name) \($0.status)" } ?? [], "pominięte:", c.skippedOthers == nil ? "brak" : "są")
            await shoot("2c-karta-reszta", out)
        }
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

        await popoverShots(app: app, prefs: prefs, root: root, out: out)
        print("DUBEL_SHOTS gotowe: \(out)")
        NSApp.terminate(nil)
    }

    /// Okienko z paska menu w zwykłym oknie: bezczynne, w trakcie szukania kopii zaznaczenia i z wynikiem.
    static func popoverShots(app: AppModel, prefs: Prefs, root: URL, out: String) async {
        let st = MenuBarStatus(app: app)
        let panel = MenuBarPanel(status: st, openApp: {}, openSettings: {}, run: { _ in })
            .environmentObject(app).environmentObject(prefs).midniteAccent(Theme.accent)
        let w = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("popover")
        w.contentViewController = NSHostingController(rootView: panel)
        w.makeKeyAndOrderFront(nil)
        await shoot("p0-pasek-bezczynny", out, windowID: "popover")
        prefs.auto.searchLocations = [root.appendingPathComponent("dyski").path]
        let m = root.appendingPathComponent("dyski/M")
        app.transfer.startSelection([m.appendingPathComponent("SFX/Paper_SFX_01.wav"), m.appendingPathComponent("SFX/b.wav"), m.appendingPathComponent("Pobrane/Revachol.jpg")])
        try? await Task.sleep(for: .milliseconds(150))
        st.refresh()
        await shoot("p1-pasek-w-trakcie", out, windowID: "popover")
        while app.transfer.card?.isBusy == true { try? await Task.sleep(for: .milliseconds(200)) }
        st.refresh()
        print("ZAZNACZENIE:", app.transfer.card?.report?.entries.map { "\($0.file.name) \($0.status)" } ?? [])
        await shoot("p2-pasek-wynik", out, windowID: "popover")
        app.transfer.closeCard()
        app.system.measure()
        try? await Task.sleep(for: .milliseconds(600))
        st.refresh()
        await shoot("p3-pasek-dane-systemowe", out, windowID: "popover")
        app.system.cancel()
        w.close()
    }

    /// Role dysków na prawdziwych dyskach (tylko w ustawieniach deweloperskich): M = zrzut, T7-2 = kopia M. Tylko odczyt listy plików.
    static func driveShots(app: AppModel, prefs: Prefs, out: String, delegate: AppDelegate? = nil) async {
        app.refreshVolumes()
        guard let m = app.volumes.first(where: { $0.name == "M" }), let t = app.volumes.first(where: { $0.name == "T7-2" }) else { print("DYSKI: brak M/T7-2"); return }
        app.drives.setRole(m.key, DriveRole(kind: .ingest))
        app.drives.setRole(t.key, DriveRole(kind: .backup, of: m.key))
        let start = Date()
        while (app.drives.catalogs[m.key] == nil || app.drives.catalogs[t.key] == nil), Date().timeIntervalSince(start) < 600 { try? await Task.sleep(for: .seconds(1)) }
        print("DYSKI:", app.drives.catalogs.values.map { "\($0.name): \($0.items.count) plików" }, "czeka:", app.drives.allPending.map { "\($0.count) / \($0.size)" }, "czas:", Int(Date().timeIntervalSince(start)), "s")
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 700, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("drives")
        w.contentViewController = NSHostingController(rootView: ScrollView { VStack(alignment: .leading, spacing: 12) { DrivesSettings() }.padding(16) }
            .frame(width: 700, height: 700).environmentObject(app).environmentObject(prefs).midniteAccent(Theme.accent))
        w.makeKeyAndOrderFront(nil)
        await shoot("d0-dyski-ustawienia", out, windowID: "drives")
        w.close()
        app.drives.log(m.key, "doc.on.doc.fill", "Duplikaty: 3 grupy, do odzyskania 1,2 GB")
        delegate?.showMain()
        app.selectedDrive = m.key
        await shoot("d2-dysk-M", out)
        app.selectedDrive = t.key
        await shoot("d3-dysk-T7", out)
        let st = MenuBarStatus(app: app)
        let pw = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 340, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        pw.identifier = NSUserInterfaceItemIdentifier("popover")
        pw.contentViewController = NSHostingController(rootView: MenuBarPanel(status: st, openApp: {}, openSettings: {}, run: { _ in })
            .environmentObject(app).environmentObject(prefs).midniteAccent(Theme.accent))
        pw.makeKeyAndOrderFront(nil)
        await shoot("d1-dyski-pasek", out, windowID: "popover")
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
