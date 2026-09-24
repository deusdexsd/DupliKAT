import SwiftUI

/// Kolor marki: dwa odcienie, z których budują się gradienty w kartach, przyciskach i zakładkach.
/// Ustawiasz go raz, na górze widoku, przez `.midniteAccent(...)`.
public struct AccentPalette: Sendable, Equatable {
    public var primary: Color
    public var secondary: Color

    public init(primary: Color, secondary: Color) { self.primary = primary; self.secondary = secondary }

    public var gradient: LinearGradient { LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing) }
}

private struct AccentPaletteKey: EnvironmentKey {
    static let defaultValue = AccentPalette(primary: .accentColor, secondary: .accentColor)
}

public extension EnvironmentValues {
    var midniteAccent: AccentPalette {
        get { self[AccentPaletteKey.self] }
        set { self[AccentPaletteKey.self] = newValue }
    }
}

public extension View {
    /// Ustawia paletę akcentu dla tego widoku i jego dzieci. Komponenty MidniteUIKit (Card, PillTabs, GradientButtonStyle, Ring…) jej używają automatycznie.
    func midniteAccent(_ palette: AccentPalette) -> some View { environment(\.midniteAccent, palette) }
    func midniteAccent(_ primary: Color, _ secondary: Color) -> some View { midniteAccent(AccentPalette(primary: primary, secondary: secondary)) }
}
