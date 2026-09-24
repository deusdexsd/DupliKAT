import SwiftUI

// MARK: - Klocki przewodnika pierwszego uruchomienia (wyjęte z DupliKAT, 2026-09-24)
//
// Użycie w skrócie:
//   OnboardingScaffold(step: $step, count: 4, onFinish: { ... }, onSkip: { ... }) { i in
//       switch i { case 0: WelcomePage() ... }
//   }
// Szczegóły i zasady: Projects/Poradnik – przewodnik pierwszego uruchomienia.html

/// Okrągła ikona funkcji: kolorowa, gdy włączona; szara, gdy wyłączona.
public struct IconCircle: View {
    let symbol: String
    let color: Color
    var on: Bool
    var size: CGFloat

    public init(symbol: String, color: Color, on: Bool = true, size: CGFloat = 38) {
        self.symbol = symbol; self.color = color; self.on = on; self.size = size
    }

    public var body: some View {
        ZStack {
            Circle().fill(on ? AnyShapeStyle(color.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
            Image(systemName: symbol).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(on ? Color.white : Color.secondary)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Duży wiersz funkcji: ikona + tytuł + opis + przełącznik. Po włączeniu rozwija szczegóły (np. próg alarmu).
/// Każda funkcja ma swój stały kolor (zasada nr 2 z README), a wyłączona jest szara.
public struct FeatureRow<Detail: View>: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let detail: Detail
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hover = false

    public init(symbol: String, color: Color, title: String, subtitle: String, isOn: Binding<Bool>, @ViewBuilder detail: () -> Detail) {
        self.symbol = symbol; self.color = color; self.title = title; self.subtitle = subtitle; self._isOn = isOn; self.detail = detail()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                IconCircle(symbol: symbol, color: color, on: isOn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 10)
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().tint(color).accessibilityLabel(title)
            }
            if isOn {
                detail.padding(.leading, 50).transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isOn ? color.opacity(0.07) : Color.primary.opacity(hover ? 0.07 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isOn ? color.opacity(0.35) : Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(reduceMotion ? .easeOut(duration: 0.1) : .spring(response: 0.3, dampingFraction: 1), value: isOn)
    }
}

public extension FeatureRow where Detail == EmptyView {
    init(symbol: String, color: Color, title: String, subtitle: String, isOn: Binding<Bool>) {
        self.init(symbol: symbol, color: color, title: title, subtitle: subtitle, isOn: isOn) { EmptyView() }
    }
}

/// Kafelek wyboru jednej z kilku opcji (ikona nad podpisem). Zaznaczony = gradient akcentu.
public struct ChoiceTile: View {
    let symbol: String
    let title: String
    var subtitle: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.midniteAccent) private var accent
    @State private var hover = false

    public init(symbol: String, title: String, subtitle: String? = nil, selected: Bool, action: @escaping () -> Void) {
        self.symbol = symbol; self.title = title; self.subtitle = subtitle; self.selected = selected; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 20, weight: .medium))
                Text(title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center)
                if let subtitle { Text(subtitle).font(.system(size: 10.5)).opacity(0.8).multilineTextAlignment(.center) }
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.primary.opacity(hover ? 0.09 : 0.06))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Kropki kroków: aktualny krok jako wydłużona pigułka w gradiencie akcentu.
public struct StepDots: View {
    let count: Int
    let current: Int
    @Environment(\.midniteAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(count: Int, current: Int) { self.count = count; self.current = current }

    public var body: some View {
        HStack(spacing: 7) {
            ForEach(0..<count, id: \.self) { i in
                Capsule().fill(i == current ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.primary.opacity(i < current ? 0.35 : 0.12)))
                    .frame(width: i == current ? 22 : 7, height: 7)
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Krok \(current + 1) z \(count)")
    }
}

/// Nagłówek kroku: duża ikona z poświatą, tytuł, jedno-dwa zdania opisu.
public struct OnboardingHeader: View {
    let symbol: String
    let color: Color
    let title: String
    let subtitle: String

    public init(symbol: String, color: Color, title: String, subtitle: String) {
        self.symbol = symbol; self.color = color; self.title = title; self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 10) {
            IconCircle(symbol: symbol, color: color, size: 56).shadow(color: color.opacity(0.35), radius: 14, y: 6)
            Text(title).font(.system(size: 24, weight: .bold)).multilineTextAlignment(.center)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
        }
        .padding(.top, 18)
    }
}

/// Poświata marki u góry okna (radialny gradient akcentu). Jedyny „ozdobnik” — reszta to system.
public struct AccentGlow: View {
    var tint: Color?
    var strength: Double
    @Environment(\.midniteAccent) private var accent

    public init(tint: Color? = nil, strength: Double = 1) { self.tint = tint; self.strength = strength }

    public var body: some View {
        RadialGradient(colors: [(tint ?? accent.primary).opacity(0.18 * strength), (tint ?? accent.secondary).opacity(0.06 * strength), .clear],
                       center: .top, startRadius: 10, endRadius: 520)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Szkielet całego przewodnika: poświata, kropki, przejścia między krokami (sprężyna, a przy „Zmniejsz ruch” — przenikanie),
/// stopka z Wstecz/Dalej/Pomiń. Treść kroków dostarcza aplikacja (długie listy: ScrollView z dolnym odstępem ~24 pt).
public struct OnboardingScaffold<Page: View>: View {
    @Binding var step: Int
    let count: Int
    var nextTitle: (Int) -> String
    let onFinish: () -> Void
    var onSkip: (() -> Void)?
    let page: (Int) -> Page
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(step: Binding<Int>, count: Int, nextTitle: @escaping (Int) -> String = { _ in "Dalej" },
                onFinish: @escaping () -> Void, onSkip: (() -> Void)? = nil, @ViewBuilder page: @escaping (Int) -> Page) {
        self._step = step; self.count = count; self.nextTitle = nextTitle; self.onFinish = onFinish; self.onSkip = onSkip; self.page = page
    }

    public var body: some View {
        ZStack {
            AccentGlow().ignoresSafeArea()
            VStack(spacing: 0) {
                StepDots(count: count, current: step).padding(.top, 22)
                ZStack {
                    page(step).id(step)
                        .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                                                                         removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                footer
            }
        }
        .noFocusRing()
    }

    var footer: some View {
        HStack {
            if step > 0 {
                Button("Wstecz") { go(-1) }.noFocusRing()
            } else if let onSkip {
                Button("Pomiń — ustawię później", action: onSkip).buttonStyle(.borderless).foregroundStyle(.secondary).noFocusRing()
            }
            Spacer()
            Button { step == count - 1 ? onFinish() : go(1) } label: { Text(nextTitle(step)).frame(minWidth: 90) }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .controlSize(.large)
        .padding(.horizontal, 28).padding(.bottom, 22).padding(.top, 10)
    }

    func go(_ d: Int) {
        forward = d > 0
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.42, dampingFraction: 0.92)) { step = max(0, min(count - 1, step + d)) }
    }
}

// MARK: - Samouczek „co jest co” (przyciemnienie + podświetlenie elementu + dymek z opisem)

/// Jeden krok samouczka. `anchor` = identyfikator nadany elementowi przez `.coachAnchor(...)`; nil = dymek na środku (np. „ikona w pasku menu”).
public struct CoachStep: Identifiable {
    public let id = UUID()
    public var anchor: String?
    public var symbol: String
    public var title: String
    public var text: String
    public init(anchor: String?, symbol: String, title: String, text: String) { self.anchor = anchor; self.symbol = symbol; self.title = title; self.text = text }
}

public struct CoachAnchorKey: PreferenceKey {
    public static let defaultValue: [String: Anchor<CGRect>] = [:]
    public static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) { value.merge(nextValue()) { $1 } }
}

public extension View {
    /// Oznacza element, który samouczek może podświetlić.
    func coachAnchor(_ id: String) -> some View { anchorPreference(key: CoachAnchorKey.self, value: .bounds) { [id: $0] } }

    /// Nakłada samouczek na widok. Elementy oznaczone `.coachAnchor` muszą być w tej samej hierarchii SwiftUI.
    /// `step` — opcjonalnie: aktualny krok z zewnątrz (np. do zrzutów ekranu albo wznowienia samouczka).
    func coachMarks(_ steps: [CoachStep], isPresented: Binding<Bool>, step: Binding<Int>? = nil, onFinish: @escaping () -> Void = {}) -> some View {
        modifier(CoachMarksModifier(steps: steps, isPresented: isPresented, external: step, onFinish: onFinish))
    }
}

struct CoachMarksModifier: ViewModifier {
    let steps: [CoachStep]
    @Binding var isPresented: Bool
    var external: Binding<Int>?
    let onFinish: () -> Void
    @State private var internalIndex = 0
    private var index: Int {
        get { external?.wrappedValue ?? internalIndex }
        nonmutating set { if let external { external.wrappedValue = newValue } else { internalIndex = newValue } }
    }
    @Environment(\.midniteAccent) private var accent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(CoachAnchorKey.self) { anchors in
            if isPresented, steps.indices.contains(index) {
                GeometryReader { geo in
                    let step = steps[index]
                    let rect = step.anchor.flatMap { anchors[$0] }.map { geo[$0].insetBy(dx: -6, dy: -6) }
                    ZStack(alignment: .topLeading) {
                        // Przyciemnienie z „dziurą” wokół podświetlanego elementu.
                        Path { p in
                            p.addRect(CGRect(origin: .zero, size: geo.size))
                            if let rect { p.addRoundedRect(in: rect, cornerSize: CGSize(width: 10, height: 10)) }
                        }
                        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                        .contentShape(Rectangle())
                        .onTapGesture { next() }
                        if let rect {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(accent.gradient, lineWidth: 2)
                                .frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                                .allowsHitTesting(false)
                        }
                        bubble(step)
                            .frame(width: 320)
                            .position(bubblePosition(rect, in: geo.size))
                    }
                    .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: index)
                }
                .transition(.opacity)
            }
        }
        .onChange(of: isPresented) { v in if v { index = 0 } }
    }

    func bubble(_ s: CoachStep) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconCircle(symbol: s.symbol, color: accent.primary, size: 30)
                Text(s.title).font(.system(size: 14, weight: .semibold))
            }
            Text(s.text).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("\(index + 1) / \(steps.count)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                Spacer()
                Button("Pomiń") { finish() }.buttonStyle(.borderless).foregroundStyle(.secondary)
                Button(index == steps.count - 1 ? "Gotowe" : "Dalej") { next() }.buttonStyle(GradientButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
    }

    /// Dymek po prawej od elementu; gdy się nie mieści — pod nim; bez elementu — na środku.
    func bubblePosition(_ r: CGRect?, in size: CGSize) -> CGPoint {
        guard let r else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let w: CGFloat = 320, h: CGFloat = 170
        if r.maxX + 20 + w < size.width {
            return CGPoint(x: r.maxX + 20 + w / 2, y: min(max(h / 2 + 12, r.midY), size.height - h / 2 - 12))
        }
        let y = r.maxY + 16 + h / 2 < size.height ? r.maxY + 16 + h / 2 : r.minY - 16 - h / 2
        return CGPoint(x: min(max(w / 2 + 12, r.midX), size.width - w / 2 - 12), y: y)
    }

    func next() { if index < steps.count - 1 { index += 1 } else { finish() } }
    func finish() { isPresented = false; index = 0; onFinish() }
}

extension View {
    /// Bez niebieskiej ramki fokusu na przyciskach przewodnika (macOS 14+; na starszych bez zmian).
    @ViewBuilder func noFocusRing() -> some View {
        if #available(macOS 14.0, iOS 17.0, *) { self.focusEffectDisabled() } else { self }
    }
}
