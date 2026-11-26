import SwiftUI

/// The Cloud page: hero, settings (add a bucket, AWS CLI and R2 logins) and the buckets card. S3-compatible buckets. A provider preset fills the endpoint; every field stays editable.
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
    @Environment(NavHistory.self) private var nav
    @AppStorage("cloudPlace") private var cloudPlace = ""

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
            Section {
                HeroCard(.cloud, title: "Cloud",
                         subtitle: "Browse S3-compatible buckets like folders and download from them.",
                         learnMore: URL(string: "https://rays.a6n.ai/docs/s3/")) {
                    HeroActions {
                        Button("Refresh") { Task { await model.loadCloudLogins(force: true) } }
                            .help("Ask the aws and cf commands again")
                    }
                }
            }

            CollapsibleSettingsCard(page: "cloud", summary: "Add a bucket, AWS, Cloudflare", startsOpen: model.buckets.isEmpty, inForm: true) {
                addBucketRows
                if !model.awsProfiles.isEmpty { AWSRows() }
                CloudflareRows()
            }

            if !model.buckets.isEmpty {
                Section {
                    DrillInRow(tile: .cloud, title: "Browse", subtitle: "Open buckets like folders") { nav.open("browse") }
                    DrillInRow(tile: .downloads, title: "Cloud downloads", subtitle: "Downloads from your buckets") { nav.open("downloads") }
                }
            }
            Section("Buckets") {
                if model.buckets.isEmpty {
                    Text("No buckets yet. Open Settings above to add one, then browse it.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.buckets, id: \.name) { bucket in
                    CardRow(title: bucket.name, subtitle: detail(bucket)) {
                        ProviderIcon(provider: bucket.provider, size: TileSize.list)
                    } trailing: {
                        RowIcon("folder", "Browse \(bucket.name)", tint: .secondary) {
                            cloudPlace = "b:" + bucket.name
                            nav.open("browse")
                        }
                    }
                    .contextMenu { Button("Remove bucket", role: .destructive) { remove(bucket.name) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .formStyle(.grouped)
        .controlSize(.small)
        .toggleStyle(SettingSwitchStyle())
        .task { await model.loadCloudLogins() }
        .onAppear { applyPreset() }
        .onChange(of: providerID) { applyPreset() }
        .onChange(of: region) { fillEndpoint() }
        .onChange(of: field) { fillEndpoint() }
    }

    @ViewBuilder private var addBucketRows: some View {
        Text("Add a bucket").font(.subheadline.weight(.semibold))
        Picker("Provider", selection: $providerID) {
            ForEach(model.providers, id: \.id) { preset in
                Label { Text(preset.name) } icon: { Image(systemName: ProviderIcon.style(preset.id).0) }
                    .tag(preset.id)
            }
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
            Button("Add bucket", action: add)
                .disabled(!canAdd)
                .keyboardShortcut(.defaultAction)
        }
        Text("The secret key is kept in your Keychain.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
    }

    private func detail(_ bucket: BucketConfig) -> String {
        let source = bucket.profile.map { "AWS CLI: \($0)" } ?? "Key in Keychain"
        return [providerName(bucket.provider), bucket.region, source].filter { !$0.isEmpty }.joined(separator: " · ")
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
private struct AWSRows: View {
    @Environment(EngineModel.self) private var model
    @AppStorage("cloudAWSProfile") private var profile = "default"
    @State private var found: [AwsBucket] = []
    @State private var loading = false
    @State private var adding: String?
    @State private var error: String?

    private var linked: Set<String> { Set(model.buckets.map(\.name)) }

    var body: some View {
        Group {
            Text("Your AWS CLI").font(.subheadline.weight(.semibold))
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
                CloudRow(provider: "aws", title: bucket.name, detail: bucket.region) {
                    AddState(added: linked.contains(bucket.name), busy: adding == bucket.name, name: bucket.name) { add(bucket) }
                        .disabled(adding != nil)
                }
            }
            Text("Rays keeps no keys. Only list and read access is used.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .task(id: "\(profile)|\(model.awsFound[profile] == nil)") { await load() }
    }

    private func load() async {
        if let cached = model.awsFound[profile] {
            found = cached
            return
        }
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

/// R2 buckets from the `cf` login. Shown only when `cf` is installed and logged in.
private struct CloudflareRows: View {
    @Environment(EngineModel.self) private var model
    @State private var adding: String?
    @State private var error: String?

    private var linked: Set<String> { Set(model.buckets.map(\.name)) }

    private var checked: Bool { model.cloudflare != nil }
    private var account: CfAccount? { try? model.cloudflare?.get() }
    private var loadError: String? {
        if case .failure(let error)? = model.cloudflare { EngineModel.message(for: error) } else { nil }
    }

    var body: some View {
        Group {
            if !checked {
                Text("Cloudflare R2").font(.subheadline.weight(.semibold))
                HStack { ProgressView().controlSize(.small); Text("Checking the cf login").foregroundStyle(.secondary) }
            } else if let loadError, !loadError.contains("not found") {
                Text("Cloudflare R2").font(.subheadline.weight(.semibold))
                Text("Log in with cf auth login in Terminal to see your R2 buckets here.")
                    .foregroundStyle(.secondary)
                Text(loadError).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else if let account {
                Text("Cloudflare R2 · \(account.name)").font(.subheadline.weight(.semibold))
                if let error { ErrorLine(text: error) }
                if account.buckets.isEmpty {
                    Text("No R2 buckets in this account.").foregroundStyle(.secondary)
                }
                ForEach(account.buckets, id: \.self) { bucket in
                    CloudRow(provider: "r2", title: bucket, detail: "Cloudflare R2") {
                        AddState(added: linked.contains(bucket), busy: adding == bucket, name: bucket) {
                            add(bucket, account: account.id)
                        }
                        .disabled(adding != nil)
                    }
                }
                Text("The first Add creates a read-only R2 token in your Cloudflare account.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func add(_ bucket: String, account: String) {
        adding = bucket
        Task {
            defer { adding = nil }
            do {
                try await model.addCloudflareBucket(bucket, account: account)
                error = nil
            } catch {
                self.error = "\(bucket): " + EngineModel.message(for: error)
            }
        }
    }
}

/// Trailing state of a found bucket: added, adding, or an Add button.
private struct AddState: View {
    let added: Bool
    let busy: Bool
    let name: String
    let add: () -> Void

    var body: some View {
        if added {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .frame(width: 26, height: 24)
                .help("\(name) is added")
                .accessibilityLabel("\(name) is added")
        } else if busy {
            ProgressView().controlSize(.small).frame(width: 26, height: 24)
        } else {
            RowIcon("plus.circle.fill", "Add \(name)", tint: .accentColor, action: add)
        }
    }
}
