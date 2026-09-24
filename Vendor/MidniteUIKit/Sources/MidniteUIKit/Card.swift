import SwiftUI

/// Podstawowa karta: lekko przezroczyste tło koloru tekstu (działa jednakowo w jasnym i ciemnym trybie, bez osobnych kolorów).
public struct Card<Content: View>: View {
    public var padding: CGFloat
    public var radius: CGFloat
    @ViewBuilder var content: Content

    public init(padding: CGFloat = 14, radius: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.radius = radius; self.content = content()
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Color.primary.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

/// Nagłówek sekcji: małymi, rozstrzelonymi literami, przygaszony. Powtarza się nad każdą kartą ustawień/statystyk.
public struct Caption: View {
    let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).tracking(0.6)
    }
}

/// Nagłówek + karta w jednym, z opcjonalnym opisem pod spodem. Podstawowy budulec ekranu ustawień.
public struct SectionCard<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: Content

    public init(title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.footer = footer; self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Caption(title).padding(.leading, 4)
            Card(padding: 12) { VStack(alignment: .leading, spacing: 4) { content } }
            if let footer {
                Text(footer).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}
