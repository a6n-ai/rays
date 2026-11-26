import SwiftUI

/// The small switch System Settings uses in a row.
struct SettingSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Toggle(configuration).toggleStyle(.switch).controlSize(.mini)
    }
}

/// Two or three choices as an inline horizontal radio group, like "Default / Large".
struct RadioChoice<Value: Hashable, Label: View>: View {
    let title: String
    @Binding var selection: Value
    let choices: [Value]
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(choices, id: \.self) { label($0).tag($0) }
        }
        .pickerStyle(.radioGroup)
        .horizontalRadioGroupLayout()
        .labelsHidden()
        .fixedSize()
    }
}

/// A whole number with a sensible range: a slider with tick marks, small end labels and the value, like "Pointer size".
struct StepSlider: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var lowLabel: String?
    var highLabel: String?
    var width: CGFloat = 170
    var display: (Int) -> String = { "\($0)" }

    var body: some View {
        HStack(spacing: 10) {
            VStack(spacing: 2) {
                Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                       in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                    .labelsHidden()
                HStack {
                    Text(lowLabel ?? "\(range.lowerBound)")
                    Spacer()
                    Text(highLabel ?? "\(range.upperBound)")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(width: width)
            Text(display(value))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(display(value))
    }
}

/// An open-ended speed limit in MB/s: a small field with its unit and a stepper. 0 is no limit.
struct SpeedLimitField: View {
    @Binding var bytes: Int

    private var mb: Binding<Double> {
        Binding(get: { Double(bytes) / 1_000_000 }, set: { bytes = Int(max(0, $0) * 1_000_000) })
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("No limit", value: mb, format: .number.precision(.fractionLength(0...1)))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
            Text("MB/s").foregroundStyle(.secondary)
            Stepper("Speed limit", value: mb, in: 0...10_000, step: 1)
                .labelsHidden()
        }
    }
}

/// A destructive action as a small red-text button on the right, not a full-width row.
struct DestructiveButton: View {
    let title: String
    let action: () -> Void

    /// At the very bottom of a page, outside every card, the way System Settings places "Reset…" and "Remove…".
    var body: some View {
        Button(title, role: .destructive, action: action)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
