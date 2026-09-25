import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    let prefs = Prefs()
    lazy var app = AppModel(prefs: prefs)
    private var mainWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var statusBar: StatusBarController?

    func applicationDidFinishLaunching(_ note: Notification) {
        if let l = ProcessInfo.processInfo.environment["DUBEL_LANG"] { prefs.auto.language = l }
        Lang.load(prefs.auto.language)
        CoreText.translate = { T($0) }
        KitText.translate = { T($0) }
        NSApp.mainMenu = MainMenu.build(target: self)
        app.showMainWindow = { [weak self] in self?.showMain() }
        UNUserNotificationCenter.current().delegate = self
        applyAppearanceSettings()
        AppIconChoice.current(prefs.auto.appIcon).apply()
        installEscapeKey()

        if ProcessInfo.processInfo.environment["DUBEL_SHOTS"] != nil {
            showMain()
            Task { await DevShots.runIfRequested(app: app, prefs: prefs, delegate: self) }
            return
        }
        app.automation.start()
        if prefs.auto.onboardingDone {
            showMain()
            if !prefs.auto.tourDone { startTour() } // np. po aktualizacji, która dodała samouczek
        } else { showOnboarding() }
        if prefs.auto.anyRuleEnabled { Notifier.request() }
    }

    /// Po zamknięciu okna Dubel zostaje w pasku menu (reguły działają dalej). Bez ikony w pasku — zamyka się.
    /// Adresy duplikat://… (Stream Deck, Skróty, przeglądarka).
    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "duplikat" {
            let name = u.host ?? u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if name == "open" {
                if let m = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "mode" })?.value.flatMap(Mode.init(rawValue:)) { open(mode: m) } else { showMain() }
            } else if let a = QuickAction(rawValue: name) {
                QuickActions.run(a, app: app, delegate: self)
            }
        }
    }

    /// Zmiana języka: onboarding i menu przełączają się od razu, reszta okien po ponownym uruchomieniu.
    func setLanguage(_ code: String) {
        guard prefs.auto.language != code else { return }
        prefs.auto.language = code
        Lang.table = [:]
        Lang.load(code)
        NSApp.mainMenu = MainMenu.build(target: self)
        statusBar?.updateIcon(prefs.auto.menuBarIcon)
    }

    /// Uruchamia aplikację od nowa (po zmianie języka w Ustawieniach).
    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    /// Globalne skróty z Ustawień (po każdej zmianie ustawień rejestrowane od nowa).
    func applyHotkeys() {
        HotkeyCenter.shared.set(1, prefs.auto.hotkeyCheck) { [weak self] in guard let self else { return }; QuickActions.run(.checkSelection, app: self.app, delegate: self) }
        HotkeyCenter.shared.set(2, prefs.auto.hotkeyWindow) { [weak self] in self?.toggleMain() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !prefs.auto.showMenuBarIcon }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMain() }
        return true
    }

    /// Ikona w pasku menu, obecność w Docku i start z systemem — wywoływane po każdej zmianie w Ustawieniach/przewodniku.
    func applyAppearanceSettings() {
        let a = prefs.auto
        if a.showMenuBarIcon {
            if statusBar == nil { statusBar = StatusBarController(delegate: self) }
            statusBar?.updateIcon(a.menuBarIcon)
        } else {
            statusBar?.remove(); statusBar = nil
        }
        // Bez Docka i bez paska menu nie dałoby się otworzyć aplikacji — wtedy Dock zostaje.
        applyHotkeys()
        let dock = a.showInDock || !a.showMenuBarIcon
        let anyWindow = [mainWindow, settingsWindow, onboardingWindow].contains { $0?.isVisible == true }
        NSApp.setActivationPolicy(dock || anyWindow ? .regular : .accessory)
    }

    // MARK: Okna

    private func makeWindow<V: View>(_ view: V, title: String, size: NSSize, id: String, style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]) -> NSWindow {
        let root = view.environmentObject(app).environmentObject(prefs).midniteAccent(Theme.accent)
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: root)
        w.title = title
        w.identifier = NSUserInterfaceItemIdentifier(id)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(size)
        w.center()
        w.setFrameAutosaveName("Dubel.\(id)")
        return w
    }

    /// Ikona w pasku menu: pierwsze kliknięcie pokazuje okno, drugie je chowa (DupliKAT działa dalej w tle).
    func toggleMain() {
        if let w = mainWindow, w.isVisible, NSApp.isActive, w.isKeyWindow || w.attachedSheet != nil { hideMain() } else { showMain() }
    }

    /// Chowa okno główne. Skany i reguły działają dalej; bez ikony w pasku menu okno jest tylko minimalizowane,
    /// żeby aplikacja się nie zamknęła.
    func hideMain() {
        guard let w = mainWindow else { return }
        if prefs.auto.showMenuBarIcon { w.orderOut(nil); applyAppearanceSettings() } else { w.miniaturize(nil) }
    }

    /// Escape w oknie głównym = schowaj okno. Nie zabiera Escape arkuszom, polom tekstowym ani samouczkowi.
    private func installEscapeKey() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.keyCode == 53 else { return e }
            // Escape w Ustawieniach zamyka tylko Ustawienia — następny Escape (już w oknie głównym) chowa okno.
            if let s = self.settingsWindow, NSApp.keyWindow === s, s.attachedSheet == nil, !(s.firstResponder is NSTextView) {
                s.close()
                if let m = self.mainWindow, m.isVisible { m.makeKeyAndOrderFront(nil) }
                return nil
            }
            guard let w = self.mainWindow, NSApp.keyWindow === w, w.attachedSheet == nil else { return e }
            if self.app.tourActive { self.app.tourActive = false; self.prefs.auto.tourDone = true; return nil }
            if w.firstResponder is NSTextView { return e } // edycja tekstu: Escape należy do pola
            self.hideMain()
            return nil
        }
    }

    @objc func showMain() {
        if mainWindow == nil {
            let w = makeWindow(RootView().frame(minWidth: 900, minHeight: 600), title: AppInfo.name, size: NSSize(width: 1180, height: 780), id: "main")
            // Pasek okna wypełnia SwiftUI (NavigationSplitView + .toolbar w RootView) — własne elementy AppKit są przez niego zastępowane.
            w.toolbar = NSToolbar(identifier: "main")
            w.toolbarStyle = .unified
            w.titleVisibility = .visible
            mainWindow = w
        }
        present(mainWindow)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = makeWindow(SettingsView(onChange: { [weak self] in self?.applyAppearanceSettings() }), title: T("Ustawienia %@", "\(AppInfo.name)"),
                                        size: NSSize(width: 660, height: 720), id: "settings", style: [.titled, .closable, .miniaturizable, .resizable])
        }
        present(settingsWindow)
    }

    @objc func showOnboarding() {
        if onboardingWindow == nil {
            let w = makeWindow(OnboardingView(onFinish: { [weak self] in self?.finishOnboarding() }), title: T("Witaj w %@", "\(AppInfo.name)"),
                               size: NSSize(width: 760, height: 680), id: "onboarding", style: [.titled, .closable, .fullSizeContentView])
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            onboardingWindow = w
        }
        present(onboardingWindow)
    }

    private func finishOnboarding() {
        prefs.auto.onboardingDone = true
        AutomationEngine.applyLoginItem(prefs.auto.launchAtLogin)
        if prefs.auto.anyRuleEnabled { Notifier.request() }
        onboardingWindow?.close()
        applyAppearanceSettings()
        showMain()
        if !prefs.auto.tourDone { startTour() }
    }

    /// Samouczek „co jest co”: przyciemnienie + podświetlenie kolejnych elementów okna.
    @objc func startTour() {
        showMain()
        app.mode = .duplicates
        Task { try? await Task.sleep(for: .milliseconds(700)); app.tourActive = true }
    }

    private func present(_ w: NSWindow?) {
        guard let w else { return }
        NSApp.setActivationPolicy(.regular)
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidMiniaturize(_ notification: Notification) {}

    func windowWillClose(_ notification: Notification) {
        // Po zamknięciu ostatniego okna chowamy ikonę z Docka, jeśli tak ustawiłeś.
        DispatchQueue.main.async { [weak self] in self?.applyAppearanceSettings() }
    }

    func open(mode: Mode) { app.mode = mode; showMain() }

    // MARK: Powiadomienia

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler done: @escaping () -> Void) {
        let raw = response.notification.request.content.userInfo["mode"] as? String
        let card = response.notification.request.content.userInfo["checkCard"] as? String
        Task { @MainActor in
            if let card, FileManager.default.fileExists(atPath: card) { self.app.transfer.startCard(URL(fileURLWithPath: card)); self.showMain() }
            else if let raw, let m = Mode(rawValue: raw) { self.open(mode: m) } else { self.showMain() }
            done()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }

    // MARK: Menu

    @objc func selectMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let m = Mode(rawValue: raw) { open(mode: m) }
    }
}

enum MainMenu {
    @MainActor static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, to t: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = t
            return i
        }
        let appMenu = NSMenu()
        appMenu.addItem(item("O \(AppInfo.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(item(T("Ustawienia…"), #selector(AppDelegate.showSettings), ",", to: target))
        appMenu.addItem(item(T("Przewodnik konfiguracji…"), #selector(AppDelegate.showOnboarding), to: target))
        appMenu.addItem(.separator())
        appMenu.addItem(item(T("Ukryj %@", "\(AppInfo.name)"), #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(item(T("Ukryj pozostałe"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(.separator())
        appMenu.addItem(item(T("Zakończ %@", "\(AppInfo.name)"), #selector(NSApplication.terminate(_:)), "q"))
        add(appMenu, AppInfo.name, to: main)

        let edit = NSMenu(title: T("Edycja"))
        edit.addItem(item(T("Cofnij"), Selector(("undo:")), "z"))
        edit.addItem(item(T("Przywróć"), Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(T("Wytnij"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(T("Kopiuj"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(T("Wklej"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(T("Zaznacz wszystko"), #selector(NSText.selectAll(_:)), "a"))
        add(edit, T("Edycja"), to: main)

        let modes = NSMenu(title: T("Tryb"))
        for (i, m) in Mode.allCases.enumerated() {
            let it = item(m.title, #selector(AppDelegate.selectMode(_:)), "\(i + 1)", to: target)
            it.representedObject = m.rawValue
            modes.addItem(it)
        }
        add(modes, T("Tryb"), to: main)

        let window = NSMenu(title: T("Okno"))
        window.addItem(item(T("Otwórz okno %@", "\(AppInfo.name)"), #selector(AppDelegate.showMain), "0", to: target))
        window.addItem(item(T("Minimalizuj"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(T("Zamknij"), #selector(NSWindow.performClose(_:)), "w"))
        add(window, T("Okno"), to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: T("Pomoc"))
        help.addItem(item(T("Pokaż, co jest co"), #selector(AppDelegate.startTour), "", to: target))
        help.addItem(item(T("Przewodnik konfiguracji…"), #selector(AppDelegate.showOnboarding), "", to: target))
        add(help, T("Pomoc"), to: main)
        NSApp.helpMenu = help
        return main
    }

    private static func add(_ submenu: NSMenu, _ title: String, to main: NSMenu) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        i.submenu = submenu
        main.addItem(i)
    }
}
