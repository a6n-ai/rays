import SwiftUI

enum FinishKind: String, CaseIterable {
    case nothing, sound, quit, sleep, lock, shutDown, command

    var title: String {
        switch self {
        case .nothing: "Do nothing"
        case .sound: "Play sound"
        case .quit: "Quit Rays"
        case .sleep: "Sleep"
        case .lock: "Lock screen"
        case .shutDown: "Shut down"
        case .command: "Run command"
        }
    }

    var symbol: String {
        switch self {
        case .nothing: "minus"
        case .sound: "speaker.wave.2"
        case .quit: "xmark"
        case .sleep: "moon.zzz"
        case .lock: "lock"
        case .shutDown: "power"
        case .command: "terminal"
        }
    }

    init(_ action: FinishAction) {
        switch action {
        case .nothing: self = .nothing
        case .sound: self = .sound
        case .quit: self = .quit
        case .sleep: self = .sleep
        case .lock: self = .lock
        case .shutDown: self = .shutDown
        case .command: self = .command
        }
    }

    var action: FinishAction {
        switch self {
        case .nothing: .nothing
        case .sound: .sound
        case .quit: .quit
        case .sleep: .sleep
        case .lock: .lock
        case .shutDown: .shutDown
        case .command: .command(command: "")
        }
    }
}

/// Seven glass tiles in four columns. Shut down asks for its permission as soon as it is picked.
struct FinishActionGrid: View {
    @Binding var action: FinishAction
    @State private var shutDownDenied = false

    private var selected: FinishKind { FinishKind(action) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(FinishKind.allCases, id: \.self) { kind in tile(kind) }
                }
            }
            if case .command(let command) = action {
                TextField("Command", text: Binding(get: { command }, set: { action = .command(command: $0) }))
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                Text(command.trimmingCharacters(in: .whitespaces).isEmpty ? "Enter a command to run." : "Runs as your user account")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if selected == .shutDown && shutDownDenied {
                Text("Rays needs permission to shut down your Mac. Allow it in System Settings > Privacy & Security > Automation.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tile(_ kind: FinishKind) -> some View {
        let on = kind == selected
        return Button { choose(kind) } label: {
            VStack(alignment: .leading) {
                Image(systemName: kind.symbol)
                    .font(.body.weight(.medium))
                Spacer(minLength: 0)
                Text(kind.title)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.accentColor.opacity(0.35)).interactive() : .regular.interactive(), in: RoundedRectangle(cornerRadius: 12))
        .overlay { if on { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 1.5) } }
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func choose(_ kind: FinishKind) {
        guard kind != selected else { return }
        action = kind.action
        shutDownDenied = false
        if kind == .shutDown {
            Task { shutDownDenied = !(await QueueActions.shared.prepareShutDown()) }
        }
    }
}
