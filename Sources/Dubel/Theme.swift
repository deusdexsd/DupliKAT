import AppKit
import DubelCore
import MidniteUIKit
import SwiftUI

/// Jedyny kolor marki (przyciski, zakładki, główna liczba). Reszta interfejsu to system: Color.primary.opacity(...), materiały.
enum Theme {
    /// Róż → śliwka, jak poświata na ikonach kat1–3.
    static let accent = AccentPalette(primary: Color(red: 0.96, green: 0.30, blue: 0.40), secondary: Color(red: 0.62, green: 0.20, blue: 0.52))

    /// Stałe kolory rodzajów plików — tylko w pasku podziału i przy ikonach, żeby na pierwszy rzut oka było widać, co zajmuje miejsce.
    static func color(_ kind: MediaKind) -> Color {
        switch kind {
        case .video: return Color(nsColor: .systemBlue)
        case .audio: return Color(nsColor: .systemGreen)
        case .image: return Color(nsColor: .systemTeal)
        case .project: return Color(nsColor: .systemPurple)
        case .other: return Color(nsColor: .systemGray)
        }
    }

    static func color(_ kind: GeneratedKind) -> Color {
        switch kind {
        case .render: return Color(nsColor: .systemBlue)
        case .preview: return Color(nsColor: .systemCyan)
        case .mediaCache: return Color(nsColor: .systemOrange)
        case .cache: return Color(nsColor: .systemBrown)
        case .proxy: return Color(nsColor: .systemIndigo)
        case .optimized: return Color(nsColor: .systemTeal)
        case .analysis: return Color(nsColor: .systemGreen)
        case .segmentation: return Color(nsColor: .systemGray)
        }
    }

    /// Znaczenie, nie dekoracja: zielony = bezpieczne, czerwony = brakuje, pomarańczowy = do sprawdzenia.
    static let safe = Color(nsColor: .systemGreen)
    static let missing = Color(nsColor: .systemRed)
    static let warn = Color(nsColor: .systemOrange)

    /// Płynna skala zajętości dysku: zielony → bursztyn → czerwony (bez skoków na progach).
    static func fullness(_ f: Double) -> Color {
        let stops: [(Double, NSColor)] = [(0.0, .systemGreen), (0.75, .systemGreen), (0.88, .systemOrange), (0.97, .systemRed), (1.0, .systemRed)]
        let x = min(1, max(0, f))
        for i in 0..<(stops.count - 1) where x <= stops[i + 1].0 {
            let (a, ca) = stops[i], (b, cb) = stops[i + 1]
            let t = b > a ? (x - a) / (b - a) : 0
            return Color(nsColor: ca.blended(withFraction: t, of: cb) ?? ca)
        }
        return Color(nsColor: .systemRed)
    }
}

private struct RichUIKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    /// Styl „jak przewodnik” (true) albo klasyczny, natywny (false). Ustawiany w przewodniku i w Ustawieniach.
    var richUI: Bool { get { self[RichUIKey.self] } set { self[RichUIKey.self] = newValue } }
}

enum Fmt {
    static let bytesFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    static func bytes(_ b: Int64) -> String { bytesFormatter.string(fromByteCount: b) }

    static var date: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: Lang.isEnglish ? "en_US" : "pl_PL")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }

    static func files(_ n: Int) -> String { Lang.isEnglish ? "\(n) \(n == 1 ? "file" : "files")" : "\(n) \(plural(n, "plik", "pliki", "plików"))" }
    static func groups(_ n: Int) -> String { Lang.isEnglish ? "\(n) \(n == 1 ? "group" : "groups")" : "\(n) \(plural(n, "grupa", "grupy", "grup"))" }
    static func copies(_ n: Int) -> String { Lang.isEnglish ? "\(n) \(n == 1 ? "copy" : "copies")" : "\(n) \(plural(n, "kopia", "kopie", "kopii"))" }

    /// Polska odmiana liczebników: 1 plik, 2–4 pliki, 5+ plików (ale 22 pliki, 12 plików).
    static func plural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
        if Lang.isEnglish { return n == 1 ? (Lang.table["#" + one] ?? one) : (Lang.table["#" + many] ?? many) }
        if n == 1 { return one }
        let d = n % 10, t = n % 100
        return (2...4).contains(d) && !(12...14).contains(t) ? few : many
    }

    /// „ok. 4 min”, „ok. 1 h 20 min”, „kilka sekund”.
    static func eta(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "" }
        if s < 20 { return T("kilka sekund") }
        let about = Lang.isEnglish ? "about" : "ok."
        if s < 90 { return "\(about) \(Int(s.rounded())) s" }
        let m = Int((s / 60).rounded())
        return m < 60 ? "\(about) \(m) min" : "\(about) \(m / 60) h \(m % 60) min"
    }

    static func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

    /// Skrócona ścieżka: ~ zamiast katalogu domowego, „M ▸ …” dla dysków zewnętrznych.
    static func path(_ p: String) -> String {
        let home = NSHomeDirectory()
        if p.hasPrefix(home) { return "~" + p.dropFirst(home.count) }
        if p.hasPrefix("/Volumes/") {
            let rest = p.dropFirst("/Volumes/".count)
            let parts = rest.split(separator: "/", maxSplits: 1)
            return parts.count == 2 ? "\(parts[0]) ▸ \(parts[1])" : String(rest)
        }
        return p
    }
}

/// Natywny materiał tła (NSVisualEffectView): sam staje się pełny przy „Zmniejsz przezroczystość”.
struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material; v.blendingMode = blending; v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material; v.blendingMode = blending }
}

/// Animacja sprężysta z wyłącznikiem dla „Zmniejsz ruch”.
extension View {
    func springy<V: Equatable>(_ value: V, reduceMotion: Bool) -> some View {
        animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 1), value: value)
    }
}
