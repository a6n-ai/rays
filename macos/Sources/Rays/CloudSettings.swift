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

            if !model.awsProfiles.isEmpty { AWSSection() }

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
                                  region: region.trimmingCharacters(in: .whitespaces), accessKeyId: k, pathStyle: pathStyle, profile: nil)
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

/// Buckets from the AWS CLI logins on this Mac. Linking one stores no keys: the CLI hands Rays fresh ones.
private struct AWSSection: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("cloudAWSProfile") private var profile = "default"
    @State private var found: [AwsBucket] = []
    @State private var loading = false
    @State private var adding: String?
    @State private var error: String?

    private var linked: Set<String> { Set(model.buckets.map(\.name)) }

    var body: some View {
        Section {
            Picker("Profile", selection: $profile) {
                ForEach(model.awsProfiles, id: \.self) { Text($0).tag($0) }
            }
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let error {
                ErrorLine(text: error)
            } else if found.isEmpty {
                Text("No buckets in this profile.").foregroundStyle(.secondary)
            }
            ForEach(found, id: \.name) { bucket in
                LabeledContent {
                    if linked.contains(bucket.name) {
                        Label("Added", systemImage: "checkmark").foregroundStyle(.secondary)
                    } else if adding == bucket.name {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") { add(bucket) }.disabled(adding != nil)
                    }
                } label: {
                    Label { Text(bucket.name); Text(bucket.region) } icon: { Image(systemName: "cloud") }
                }
            }
        } header: {
            Text("Your AWS CLI")
        } footer: {
            Text("Rays asks the aws command for keys each time and keeps none. Only list and read access is used.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .task(id: profile) { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            found = try await model.awsBuckets(profile)
            error = nil
        } catch {
            found = []
            self.error = EngineModel.message(for: error)
        }
    }

    private func add(_ bucket: AwsBucket) {
        adding = bucket.name
        Task {
            defer { adding = nil }
            do {
                try await model.addAWSBucket(bucket, profile: profile)
            } catch {
                self.error = "\(bucket.name): " + EngineModel.message(for: error)
            }
        }
    }
}
