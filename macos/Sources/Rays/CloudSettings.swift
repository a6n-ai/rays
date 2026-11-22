import SwiftUI

/// Cloud > Buckets: S3-compatible buckets. A provider preset fills the endpoint; every field stays editable.
struct BucketsForm: View {
    @Environment(EngineModel.self) private var model
    @State private var providerID = "aws"
    @State private var name = ""
    @State private var region = ""
    @State private var field = ""
    @State private var endpoint = ""
    @State private var keyID = ""
    @State private var secret = ""
    @State private var pathStyle = false
    @State private var adding = false
    @State private var error: String?

    private var preset: ProviderPreset? { model.providers.first { $0.id == providerID } }
    private var trimmed: (String, String, String) {
        (name.trimmingCharacters(in: .whitespaces), endpoint.trimmingCharacters(in: .whitespaces),
         keyID.trimmingCharacters(in: .whitespaces))
    }
    private var canAdd: Bool {
        let (n, e, k) = trimmed
        return !adding && !n.isEmpty && !e.isEmpty && !k.isEmpty && !secret.isEmpty
    }

    var body: some View {
        Form {
            Section("Buckets") {
                if model.buckets.isEmpty {
                    Text("No buckets yet. Add one below, then browse it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.buckets, id: \.name) { bucket in
                    LabeledContent {
                        Button("Remove", role: .destructive) { remove(bucket.name) }
                    } label: {
                        HStack(spacing: 10) {
                            SettingIcon(symbol: "cloud.fill", color: .blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(bucket.name)
                                Text(providerName(bucket.provider) + " · " + bucket.endpoint)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                }
            }

            Section {
                Picker("Provider", selection: $providerID) {
                    ForEach(model.providers, id: \.id) { Text($0.name).tag($0.id) }
                }
                TextField("Bucket name", text: $name)
                if let label = preset?.fieldLabel {
                    TextField(label, text: $field)
                }
                TextField("Region", text: $region, prompt: Text(preset?.regionHint ?? ""))
                TextField("Endpoint", text: $endpoint, prompt: Text("https://s3.example.com"))
                Toggle("Path-style addressing", isOn: $pathStyle)
                TextField("Access key ID", text: $keyID)
                SecureField("Secret access key", text: $secret)
                HStack {
                    if let error { ErrorLine(text: error) }
                    Spacer()
                    if adding { ProgressView().controlSize(.small) }
                    Button("Add Bucket", action: add)
                        .disabled(!canAdd)
                        .keyboardShortcut(.defaultAction)
                }
            } header: {
                Text("Add a bucket")
            } footer: {
                Text("Rays lists the bucket once to check the keys. The secret key is kept in your Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .onAppear { applyPreset() }
        .onChange(of: providerID) { applyPreset() }
        .onChange(of: region) { fillEndpoint() }
        .onChange(of: field) { fillEndpoint() }
    }

    private func providerName(_ id: String) -> String {
        model.providers.first { $0.id == id }?.name ?? id
    }

    private func applyPreset() {
        guard let preset else { return }
        region = preset.region
        field = ""
        pathStyle = preset.pathStyle
        endpoint = ""
        fillEndpoint()
    }

    /// Generic S3 and MinIO have no template, so whatever the user typed stays.
    private func fillEndpoint() {
        guard let preset, !preset.endpoint.isEmpty else { return }
        endpoint = model.providerEndpoint(preset.id, region: region, field: field) ?? ""
    }

    private func add() {
        let (n, e, k) = trimmed
        let config = BucketConfig(name: n, provider: providerID, endpoint: e,
                                  region: region.trimmingCharacters(in: .whitespaces), accessKeyId: k, pathStyle: pathStyle)
        adding = true
        error = nil
        Task {
            defer { adding = false }
            do {
                try await model.addBucket(config, secret: secret)
                name = ""
                keyID = ""
                secret = ""
            } catch {
                self.error = EngineModel.message(for: error)
            }
        }
    }

    private func remove(_ bucket: String) {
        do {
            try model.removeBucket(bucket)
        } catch {
            self.error = EngineModel.message(for: error)
        }
    }
}
