import AppKit
import DubelCore

/// Ikona w pasku menu: lewy przycisk = okno Dubla, prawy = menu z regułami i ustawieniami.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var progressTimer: Timer?
    private weak var delegate: AppDelegate?
    private let menu = NSMenu()

    init(delegate: AppDelegate) {
        self.delegate = delegate
        super.init()
        if let b = item.button {
            b.image = MenuBarIconChoice.current(delegate.prefs.auto.menuBarIcon).image()
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "\(AppInfo.name) — kliknij, żeby otworzyć albo schować; prawy przycisk: menu"
        }
        menu.delegate = self
        // Postęp skanu obok ikony („37%”), także gdy okno jest schowane.
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateProgress() } }
    }

    private func updateProgress() {
        guard let b = item.button, let app = delegate?.app else { return }
        if let (label, fraction) = app.currentProgress {
            let text = fraction.map { " \(Int(($0 * 100).rounded()))%" } ?? " …"
            if b.title != text { b.title = text; b.imagePosition = .imageLeft }
            b.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            b.toolTip = "\(AppInfo.name): \(label)"
        } else if !b.title.isEmpty {
            b.title = ""; b.imagePosition = .imageOnly
            b.toolTip = "\(AppInfo.name) — kliknij, żeby otworzyć albo schować; prawy przycisk: menu"
        }
    }

    func remove() { NSStatusBar.system.removeStatusItem(item) }
    func updateIcon(_ raw: String) { item.button?.image = MenuBarIconChoice.current(raw).image() }

    @objc private func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            item.menu = menu
            item.button?.performClick(nil) // pokazuje menu przypięte do ikony
            item.menu = nil
        } else {
            delegate?.toggleMain()
        }
    }

    // Menu budowane za każdym razem od nowa, żeby pokazywało aktualny stan reguł i skanów.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let d = delegate else { return }
        let app = d.app
        let a0 = app.prefs.auto
        menu.removeAllItems()

        let header = NSMenuItem(title: AppInfo.name, action: nil, keyEquivalent: "")
        header.attributedTitle = NSAttributedString(string: AppInfo.name, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
        menu.addItem(header)
        let running = Mode.allCases.filter { app.isRunning($0) }
        if running.isEmpty {
            menu.addItem(info("Nic teraz nie skanuje"))
        } else {
            for m in running { menu.addItem(action("⏳ \(m.title)…", #selector(openMode(_:)), m.rawValue)) }
        }
        for v in app.volumes {
            menu.addItem(info("\(v.isCard ? "Karta" : "Dysk") \(v.name): wolne \(Fmt.bytes(v.free)) (\(Fmt.percent(v.used)) zajęte)"))
        }
        menu.addItem(.separator())

        menu.addItem(action("Otwórz \(AppInfo.name)", #selector(openMain)))
        for m in [Mode.duplicates, .transfer, .fcp, .system] { menu.addItem(action(m.title + "…", #selector(openMode(_:)), m.rawValue)) }
        for v in app.volumes where v.isCard { menu.addItem(action("Co jest zgrane z „\(v.name)”?", #selector(importCard(_:)), v.url.path)) }
        menu.addItem(action("Sprawdź zaznaczone w Finderze" + (a0.hotkeyCheck.map { "  " + HotKeyText.string($0) } ?? ""), #selector(checkSelection)))
        menu.addItem(.separator())

        menu.addItem(info("Reguły automatyczne"))
        let a = app.prefs.auto
        menu.addItem(toggle("Karta podłączona → sprawdź, co jest zgrane", a.cardImportEnabled, "card"))
        menu.addItem(toggle("Alarm zajętego miejsca (\(Int(a.spaceAlarmPercent))%)", a.spaceAlarmEnabled, "space"))
        menu.addItem(toggle("Pilnuj danych systemowych", a.systemWatchEnabled, "system"))
        menu.addItem(toggle("Tygodniowy przegląd", a.weeklyReportEnabled, "weekly"))
        if !a.checkVolumesOnMount.isEmpty { menu.addItem(info("Sprawdzam po podłączeniu: " + a.checkVolumesOnMount.joined(separator: ", "))) }
        menu.addItem(action("Zmierz dane systemowe teraz", #selector(measureNow)))
        menu.addItem(.separator())
        menu.addItem(action("Ustawienia…", #selector(openSettings)))
        menu.addItem(action("Przewodnik konfiguracji…", #selector(openOnboarding)))
        menu.addItem(action("Pokaż, co jest co", #selector(openTour)))
        menu.addItem(.separator())
        menu.addItem(action("Zakończ \(AppInfo.name)", #selector(quit)))
    }

    private func info(_ t: String) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ t: String, _ sel: Selector, _ obj: String? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: t, action: sel, keyEquivalent: "")
        i.target = self
        i.representedObject = obj
        return i
    }

    private func toggle(_ t: String, _ on: Bool, _ key: String) -> NSMenuItem {
        let i = action(t, #selector(toggleRule(_:)), key)
        i.state = on ? .on : .off
        return i
    }

    @objc private func openMain() { delegate?.showMain() }
    @objc private func openSettings() { delegate?.showSettings() }
    @objc private func openOnboarding() { delegate?.showOnboarding() }
    @objc private func openTour() { delegate?.startTour() }
    @objc private func openMode(_ s: NSMenuItem) { if let r = s.representedObject as? String, let m = Mode(rawValue: r) { delegate?.open(mode: m) } }
    @objc private func importCard(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String, let d = delegate else { return }
        d.app.transfer.startCard(URL(fileURLWithPath: p))
        d.showMain()
    }
    @objc private func checkSelection() { if let d = delegate { QuickActions.run(.checkSelection, app: d.app, delegate: d) } }
    @objc private func measureNow() {
        guard let d = delegate else { return }
        d.app.system.measure()
        d.open(mode: .system)
    }
    @objc private func quit() {
        let alert = NSAlert()
        alert.messageText = "Zakończyć \(AppInfo.name)?"
        alert.informativeText = "Reguły automatyczne (zgrywanie kart, alarmy) przestaną działać do następnego uruchomienia."
        alert.addButton(withTitle: "Zakończ")
        alert.addButton(withTitle: "Anuluj")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    @objc private func toggleRule(_ s: NSMenuItem) {
        guard let d = delegate, let key = s.representedObject as? String else { return }
        switch key {
        case "card": d.prefs.auto.cardImportEnabled.toggle()
        case "space": d.prefs.auto.spaceAlarmEnabled.toggle()
        case "system": d.prefs.auto.systemWatchEnabled.toggle()
        case "weekly": d.prefs.auto.weeklyReportEnabled.toggle()
        default: break
        }
        if d.prefs.auto.anyRuleEnabled { Notifier.request() }
    }
}
