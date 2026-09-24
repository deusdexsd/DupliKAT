import SwiftUI

/// Wiersz ustawienia: tytuł (+ opcjonalny podtytuł) po lewej, dowolna kontrolka po prawej.
public struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    public init(title: String, subtitle: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title; self.subtitle = subtitle; self.control = control()
    }

    public var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle { Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            control
        }
        .frame(minHeight: 30)
    }
}

public struct SwitchRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool
    @Environment(\.midniteAccent) private var accent

    public init(title: String, subtitle: String? = nil, isOn: Binding<Bool>) { self.title = title; self.subtitle = subtitle; self._isOn = isOn }

    public var body: some View {
        SettingRow(title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(accent.primary)
        }
    }
}

/// Stepper w formie pigułki z wartością pośrodku: `− 20 min +`. Format dowolny przez `format`.
public struct ValueStepper: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    public init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) {
        self._value = value; self.range = range; self.step = step; self.format = format
    }

    public var body: some View {
        HStack(spacing: 0) {
            button("minus", enabled: value > range.lowerBound + 0.0001) { value = max(range.lowerBound, value - step) }
            Text(format(value)).font(.system(size: 12.5, weight: .semibold).monospacedDigit()).frame(minWidth: 62)
            button("plus", enabled: value < range.upperBound - 0.0001) { value = min(range.upperBound, value + step) }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.07)))
    }

    private func button(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 10, weight: .bold))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color.primary.opacity(0.06)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.primary : Color.primary.opacity(0.25))
        .disabled(!enabled)
    }
}

public extension Binding where Value == Int {
    var asDouble: Binding<Double> { Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = Int($0.rounded()) }) }
}

/// Przycisk w gradiencie marki (`prominent: true`) albo w cichym, neutralnym tle (`false`).
public struct GradientButtonStyle: ButtonStyle {
    public var prominent: Bool
    @Environment(\.midniteAccent) private var accent

    public init(prominent: Bool = true) { self.prominent = prominent }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(prominent ? AnyShapeStyle(accent.gradient) : AnyShapeStyle(Color.primary.opacity(0.09))))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
