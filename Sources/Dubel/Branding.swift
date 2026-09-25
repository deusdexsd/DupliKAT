import AppKit
import SwiftUI

enum AppInfo {
    static let name = "DupliKAT"
}

/// Ikona aplikacji (Dock, przewodnik). Grafiki z Projects/Ikony/kat1–3.png.
enum AppIconChoice: String, CaseIterable, Identifiable {
    case kat1, kat2, kat3
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kat1: return T("Karty")
        case .kat2: return T("Topór")
        case .kat3: return T("Kaptur")
        }
    }

    var image: NSImage? {
        if let u = Bundle.main.url(forResource: rawValue, withExtension: "png") { return NSImage(contentsOf: u) }
        return nil
    }

    static func current(_ raw: String) -> AppIconChoice { AppIconChoice(rawValue: raw) ?? .kat1 }

    /// Ikona w Docku zmienia się od razu. Ikona w Finderze zostaje domyślna (kat1) — zmiana pliku aplikacji zepsułaby jej podpis.
    func apply() { NSApp.applicationIconImage = image }
}

/// Ikona w pasku menu: monochromatyczny szablon (macOS sam dopasowuje ją do jasnego/ciemnego paska).
enum MenuBarIconChoice: String, CaseIterable, Identifiable {
    case cards, axe, hood, docs, scissors
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cards: return T("Karty")
        case .axe: return T("Topór")
        case .hood: return T("Kaptur")
        case .docs: return T("Kopie")
        case .scissors: return T("Nożyczki")
        }
    }

    static func current(_ raw: String) -> MenuBarIconChoice { MenuBarIconChoice(rawValue: raw) ?? .cards }

    func image(size: CGFloat = 18) -> NSImage {
        switch self {
        case .docs: return symbol("doc.on.doc", size)
        case .scissors: return symbol("scissors", size)
        default:
            let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { r in
                NSColor.black.set()
                let s = r.width / 18
                let t = NSAffineTransform(); t.scale(by: s)
                switch self {
                case .cards:
                    for c in [Self.card(5.4, 9.6, -9, cutRight: true), Self.card(12.6, 9.6, 9, cutRight: false)] { c.transform(using: t as AffineTransform); c.fill() }
                case .axe:
                    let blade = Self.axe(); blade.transform(using: t as AffineTransform); blade.fill()
                    let h = Self.handle(); h.transform(using: t as AffineTransform); h.lineWidth = 2.0 * s; h.stroke()
                case .hood:
                    let p = Self.hood(); p.transform(using: t as AffineTransform); p.fill()
                default: break
                }
                return true
            }
            img.isTemplate = true
            return img
        }
    }

    private func symbol(_ name: String, _ size: CGFloat) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: AppInfo.name)?
            .withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .medium)) ?? NSImage()
        img.isTemplate = true
        return img
    }

    // Kształty w układzie 18×18 (y w dół), dopasowane do grafik kat1–3.
    static func card(_ cx: CGFloat, _ cy: CGFloat, _ angle: CGFloat, cutRight: Bool) -> NSBezierPath {
        let w: CGFloat = 6.0, h: CGFloat = 8.0, cut: CGFloat = 1.9, r: CGFloat = 0.8
        let x0 = -w/2, y0 = -h/2, x1 = w/2, y1 = h/2
        let p = NSBezierPath()
        if cutRight {
            p.move(to: NSPoint(x: x0 + r, y: y0)); p.line(to: NSPoint(x: x1 - cut, y: y0)); p.line(to: NSPoint(x: x1, y: y0 + cut))
        } else {
            p.move(to: NSPoint(x: x0 + cut, y: y0)); p.line(to: NSPoint(x: x1 - r, y: y0))
            p.appendArc(from: NSPoint(x: x1, y: y0), to: NSPoint(x: x1, y: y0 + r), radius: r)
        }
        p.line(to: NSPoint(x: x1, y: y1 - r)); p.appendArc(from: NSPoint(x: x1, y: y1), to: NSPoint(x: x1 - r, y: y1), radius: r)
        p.line(to: NSPoint(x: x0 + r, y: y1)); p.appendArc(from: NSPoint(x: x0, y: y1), to: NSPoint(x: x0, y: y1 - r), radius: r)
        if cutRight { p.line(to: NSPoint(x: x0, y: y0 + r)); p.appendArc(from: NSPoint(x: x0, y: y0), to: NSPoint(x: x0 + r, y: y0), radius: r) }
        else { p.line(to: NSPoint(x: x0, y: y0 + cut)) }
        p.close()
        // okienko etykiety (wycięcie) — karta czytelna nawet w 16 px
        let label = NSBezierPath(roundedRect: NSRect(x: x0 + 1.4, y: y0 + 2.9, width: w - 2.8, height: h - 4.3), xRadius: 0.5, yRadius: 0.5)
        p.append(label)
        p.windingRule = .evenOdd
        let t = NSAffineTransform(); t.translateX(by: cx, yBy: cy); t.rotate(byDegrees: angle)
        p.transform(using: t as AffineTransform)
        return p
    }
    static func axe() -> NSBezierPath {
        let p = NSBezierPath()
        // półksiężyc: górny szpic → łuk tnący → dolny szpic → wklęsły powrót do trzonka
        p.move(to: NSPoint(x: 9.0, y: 1.8))
        p.curve(to: NSPoint(x: 4.2, y: 11.4), controlPoint1: NSPoint(x: 4.6, y: 3.0), controlPoint2: NSPoint(x: 2.8, y: 8.0))
        p.curve(to: NSPoint(x: 10.0, y: 7.0), controlPoint1: NSPoint(x: 5.6, y: 9.0), controlPoint2: NSPoint(x: 7.6, y: 7.4))
        p.line(to: NSPoint(x: 12.0, y: 4.4))
        p.curve(to: NSPoint(x: 9.0, y: 1.8), controlPoint1: NSPoint(x: 11.0, y: 3.2), controlPoint2: NSPoint(x: 10.0, y: 2.2))
        p.close()
        p.append(NSBezierPath(ovalIn: NSRect(x: 10.6, y: 2.8, width: 3.0, height: 3.0)))
        return p
    }
    static func handle() -> NSBezierPath {
        let h = NSBezierPath(); h.move(to: NSPoint(x: 12.0, y: 4.6)); h.curve(to: NSPoint(x: 6.0, y: 16.2), controlPoint1: NSPoint(x: 10.4, y: 8.6), controlPoint2: NSPoint(x: 8.0, y: 13.2))
        h.lineWidth = 2.0; h.lineCapStyle = .round; return h
    }
    static func hood() -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 2.8, y: 15.6))
        p.curve(to: NSPoint(x: 8.2, y: 2.6), controlPoint1: NSPoint(x: 2.6, y: 9.4), controlPoint2: NSPoint(x: 4.8, y: 2.8))
        p.curve(to: NSPoint(x: 14.6, y: 2.4), controlPoint1: NSPoint(x: 10.6, y: 2.4), controlPoint2: NSPoint(x: 13.4, y: 1.2))
        p.curve(to: NSPoint(x: 12.6, y: 4.8), controlPoint1: NSPoint(x: 15.4, y: 3.4), controlPoint2: NSPoint(x: 14.2, y: 4.6))
        p.curve(to: NSPoint(x: 15.2, y: 15.6), controlPoint1: NSPoint(x: 14.2, y: 7.6), controlPoint2: NSPoint(x: 15.2, y: 11.0))
        p.curve(to: NSPoint(x: 11.8, y: 14.6), controlPoint1: NSPoint(x: 14.0, y: 16.4), controlPoint2: NSPoint(x: 12.8, y: 15.2))
        p.curve(to: NSPoint(x: 6.2, y: 14.6), controlPoint1: NSPoint(x: 10.0, y: 13.6), controlPoint2: NSPoint(x: 8.0, y: 13.6))
        p.curve(to: NSPoint(x: 2.8, y: 15.6), controlPoint1: NSPoint(x: 5.2, y: 15.2), controlPoint2: NSPoint(x: 4.0, y: 16.4))
        p.close()
        p.append(NSBezierPath(ovalIn: NSRect(x: 5.6, y: 8.3, width: 2.4, height: 2.0)))
        p.append(NSBezierPath(ovalIn: NSRect(x: 10.0, y: 8.3, width: 2.4, height: 2.0)))
        p.windingRule = .evenOdd
        return p
    }
}

/// Wybór ikony aplikacji — kafelki z grafikami kat1–3.
struct AppIconPicker: View {
    @Binding var selection: String
    @Environment(\.midniteAccent) private var accent

    var body: some View {
        HStack(spacing: 14) {
            ForEach(AppIconChoice.allCases) { c in
                let on = AppIconChoice.current(selection) == c
                Button { selection = c.rawValue; c.apply() } label: {
                    VStack(spacing: 6) {
                        if let img = c.image { Image(nsImage: img).resizable().interpolation(.high).frame(width: 64, height: 64) }
                        Text(c.title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? accent.primary.opacity(0.14) : Color.primary.opacity(0.04)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.clear), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("Ikona %@", "\(c.title)"))
            }
        }
    }
}

/// Wybór ikony w pasku menu — 5 szablonów, podgląd tak, jak w prawdziwym pasku.
struct MenuBarIconPicker: View {
    @Binding var selection: String
    @Environment(\.midniteAccent) private var accent

    var body: some View {
        HStack(spacing: 8) {
            ForEach(MenuBarIconChoice.allCases) { c in
                let on = MenuBarIconChoice.current(selection) == c
                Button { selection = c.rawValue } label: {
                    VStack(spacing: 6) {
                        Image(nsImage: c.image(size: 22)).renderingMode(.template)
                            .foregroundStyle(on ? Color.white : Color.primary)
                            .frame(width: 26, height: 26)
                        Text(c.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(on ? Color.white : Color.primary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T("Ikona w pasku menu: %@", "\(c.title)"))
            }
        }
    }
}

// MARK: - Język (PL/EN)

/// Tłumaczenie tekstów interfejsu. Kluczem jest polski tekst (z %@ w miejscu wstawek), angielskie wersje są w en.json.
/// Brak tłumaczenia = polski tekst (nic się nie psuje, najwyżej zostaje po polsku).
enum Lang {
    nonisolated(unsafe) static var isEnglish = false
    nonisolated(unsafe) static var table: [String: String] = [:]

    static func load(_ code: String) {
        isEnglish = code == "en"
        if isEnglish, table.isEmpty, let u = Bundle.main.url(forResource: "en", withExtension: "json"),
           let d = try? Data(contentsOf: u), let t = try? JSONDecoder().decode([String: String].self, from: d) { table = t }
    }
}

func T(_ key: String, _ args: String...) -> String {
    var out = Lang.isEnglish ? (Lang.table[key] ?? key) : key
    for a in args {
        guard let r = out.range(of: "%@") else { break }
        out.replaceSubrange(r, with: a)
    }
    return out
}
