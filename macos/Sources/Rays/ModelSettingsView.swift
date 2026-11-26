import SwiftUI

/// The "same name exists" choice, shared by the Download settings and the Models settings.
struct ReplaceExistingRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.replaceExisting) private var replaceExisting = false

    var body: some View {
        SettingRow(title: "If a file with the same name exists", hint: "A replaced file goes to the Trash.") {
            RadioChoice(title: "If a file with the same name exists",
                        selection: Binding(get: { replaceExisting }, set: { model.setReplaceExisting($0) }),
                        choices: [false, true]) { Text($0 ? "Replace" : "Keep both") }
        }
    }
}

struct HuggingFaceTokenSection: View {
    var body: some View {
        Section {
            HuggingFaceTokenRows()
        } header: {
            Text("Hugging Face")
        } footer: {
            Text(HuggingFaceTokenRows.note)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The token field and its error line. `card` lays it out as a settings-card row with the note under the title;
/// otherwise it is bare rows for a Form section that shows the note as its footer.
struct HuggingFaceTokenRows: View {
    static let note = "For gated and private models. Sent only to huggingface.co, kept in Keychain."

    var card = false
    @Environment(EngineModel.self) private var model
    @State private var token = ""
    @State private var hasToken = false
    @State private var tokenError: String?

    var body: some View {
        Group {
            if card {
                VStack(alignment: .leading, spacing: 6) {
                    SettingRow(title: "Hugging Face token", hint: Self.note, status: hasToken ? .ok : nil) { controls }
                    if let tokenError { ErrorLine(text: tokenError) }
                }
            } else {
                controls
                if let tokenError { ErrorLine(text: tokenError) }
            }
        }
        .onAppear { hasToken = model.hasHFToken }
    }

    private var controls: some View {
        HStack {
            SecureField("Access token", text: $token)
                .frame(minWidth: card ? 120 : 0)
            if hasToken { Text("Saved").foregroundStyle(.secondary) }
            Button("Save", action: saveToken)
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Remove") { _ = setToken(nil) }
                .disabled(!hasToken)
        }
    }

    /// The field keeps the typed token when the save fails, so the user can retry or copy it.
    private func saveToken() {
        if setToken(token.trimmingCharacters(in: .whitespacesAndNewlines)) { token = "" }
    }

    @discardableResult private func setToken(_ value: String?) -> Bool {
        defer { hasToken = model.hasHFToken }
        do {
            try model.setHFToken(value)
            tokenError = nil
            return true
        } catch {
            tokenError = EngineModel.message(for: error)
            return false
        }
    }
}

/// The AI Models folder row of the Models settings card.
struct AIModelsFolderRow: View {
    let folder: URL

    var body: some View {
        SettingRow(title: "AI Models folder", hint: (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath) {
            Button("Show in Finder") { AIModelsFolder.reveal(folder) }
        }
    }
}
