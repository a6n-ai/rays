import SwiftUI

/// Seven glass pills, Mo to Su. The mask's bit 0 is Monday.
struct DayPills: View {
    @Binding var mask: UInt8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(0..<7, id: \.self) { day in
                        let on = mask & (1 << day) != 0
                        Button { mask ^= 1 << day } label: {
                            Text(SchedulerTime.dayLetters[day])
                                .font(.callout.weight(.medium))
                                .frame(minWidth: 28, minHeight: 28)
                                .padding(.horizontal, 4)
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(on ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Capsule())
                        .accessibilityLabel(SchedulerTime.dayNames[day])
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .help(SchedulerTime.dayNames[day])
                    }
                }
            }
            if mask == 0 {
                Text("Pick at least one day")
                    .font(.subheadline)
                    .foregroundStyle(.red)
            }
        }
    }
}
