import SwiftUI

/// Zakładki w formie pigułki z jeżdżącym podświetleniem (matchedGeometryEffect). Jeden komponent do wyboru
/// okresu w statystykach, karty w ustawieniach czy głównych sekcji panelu.
public struct PillTabs<T: Hashable>: View {
    public let items: [(value: T, title: String, symbol: String?)]
    @Binding public var selection: T
    public var fontSize: CGFloat
    @Environment(\.midniteAccent) private var accent
    @Namespace private var ns

    public init(items: [(value: T, title: String, symbol: String?)], selection: Binding<T>, fontSize: CGFloat = 12.5) {
        self.items = items; self._selection = selection; self.fontSize = fontSize
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let selected = item.value == selection
                Button {
                    withAnimation(.snappy(duration: 0.25)) { selection = item.value }
                } label: {
                    HStack(spacing: 5) {
                        if let s = item.symbol { Image(systemName: s).font(.system(size: fontSize - 1.5, weight: .semibold)) }
                        Text(item.title).font(.system(size: fontSize, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.vertical, 6).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background { if selected { Capsule().fill(accent.gradient).matchedGeometryEffect(id: "pill", in: ns) } }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}
