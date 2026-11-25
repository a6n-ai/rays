import SwiftUI

/// The "same name exists" choice, shared by the Download settings and the Models settings.
struct ReplaceExistingRow: View {
    @Environment(EngineModel.self) private var model
    @AppStorage(SettingsKey.replaceExisting) private var replaceExisting = false

    var body: some View {
        SettingRow(symbol: "doc.on.doc", color: .blue,
                   title: "If a file with the same name exists", hint: "Applies to every download.") {
            Picker("If a file with the same name exists", selection: Binding(get: { replaceExisting }, set: { model.setReplaceExisting($0) })) {
                Text("Keep both").tag(false)
                Text("Replace (old file goes to the Trash)").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
    }
}

struct HuggingFaceTokenSection: View {
    @Environment(EngineModel.self) private var model
    @State private var token = ""
    @State private var hasToken = false
    @State private var tokenError: String?

    var body: some View {
        Section {
            HStack {
                SecureField("Access token", text: $token)
                if hasToken { Text("Saved").foregroundStyle(.secondary) }
                Button("Save", action: saveToken)
                    .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Remove") { _ = setToken(nil) }
                    .disabled(!hasToken)
            }
            if let tokenError { ErrorLine(text: tokenError) }
        } header: {
            Text("Hugging Face")
        } footer: {
            Text("Needed for gated and private models. Sent only to huggingface.co. Stored in Keychain.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .onAppear { hasToken = model.hasHFToken }
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

/// The Settings page of the Models view.
struct ModelSettingsView: View {
    let folder: URL

    var body: some View {
        Form {
            Section {
                ReplaceExistingRow()
                SettingRow(symbol: "shippingbox.fill", color: .indigo,
                           title: "AI Models folder", hint: (folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath) {
                    Button("Show in Finder") { AIModelsFolder.reveal(folder) }
                }
            }
            HuggingFaceTokenSection()
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
    }
}
