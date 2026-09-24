import SwiftUI

/// Pierścień postępu w stylu Aplikacji Zdrowie. Przekaż osobny `gradient` dla każdej metryki (patrz README):
/// dzięki temu kilka pierścieni obok siebie da się rozróżnić kątem oka, zamiast zlewać się w jeden kolor.
public struct Ring: View {
    public var progress: Double
    public var lineWidth: CGFloat
    public var gradient: LinearGradient

    public init(progress: Double, lineWidth: CGFloat = 10, gradient: LinearGradient) {
        self.progress = progress; self.lineWidth = lineWidth; self.gradient = gradient
    }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, progress)))
                .stroke(gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.6), value: progress)
    }
}
