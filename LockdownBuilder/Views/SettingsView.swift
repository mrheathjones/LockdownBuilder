import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var store: ProjectStore
    /// True when shown in the main window's detail pane (from the sidebar) rather than the Settings window.
    var embedded = false

    var body: some View {
        if embedded {
            tabs
                .frame(maxWidth: 640)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle("Settings")
                .navigationSubtitle("")
        } else {
            tabs.frame(width: 560, height: 560)
        }
    }

    private var tabs: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings(store: store)
            }
            Tab("Dialog", systemImage: "macwindow") {
                DialogSettings(store: store)
            }
            Tab("Watcher", systemImage: "shield.lefthalf.filled") {
                WatcherSettings(store: store)
            }
            Tab("Jamf Pro", systemImage: "icloud.and.arrow.up") {
                JamfSettings(store: store)
            }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var store: ProjectStore
    @AppStorage("showPlistKeys") private var showKeys = true

    var body: some View {
        Form {
            Section {
                TextField("Company Name", text: $store.settings.orgNameFriendly, prompt: Text("Company Name"))
            } footer: {
                caption("ORG_NAME_FRIENDLY. Used in template wording, the dialog title when there is no banner, and as the organization in .mobileconfig profiles.")
            }
            Section("Preference domain") {
                TextField("Organization domain", text: $store.settings.orgPlistDomain, prompt: Text("com.company"))
                TextField("Preference", text: $store.settings.preference, prompt: Text("restrict"))
                LabeledContent("Rule domain") {
                    Text("\(store.settings.orgPlistDomain).\(store.settings.preference).<rule-name>")
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Watcher label") {
                    Text(store.settings.watcherLabel)
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(store.settings.issues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Editor") {
                Toggle("Show plist keys under field labels", isOn: $showKeys)
            }
            Section {
                Toggle("Use on-device Apple Intelligence", isOn: $store.settings.aiEnabled)
                if store.settings.aiEnabled {
                    if let reason = FoundationModelsAssistant().availability.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    } else {
                        Label("Available. Runs on this Mac; nothing is sent anywhere.", systemImage: "checkmark.circle")
                            .font(.caption).foregroundStyle(.green)
                    }
                }
            } header: {
                Text("Apple Intelligence (optional)")
            } footer: {
                caption("Adds “Draft message” and “Suggest with Apple Intelligence” in discovery. AI output is never applied without you.")
            }
            Section("Output folder") {
                LabeledContent("Default folder") {
                    Text(store.settings.defaultOutputFolder.isEmpty ? "None" : store.settings.defaultOutputFolder)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button("Choose…") {
                        if let url = FileDialogs.chooseFolder(message: "Choose the default output folder.") {
                            store.settings.defaultOutputFolder = url.path
                        }
                    }
                    Button("Clear") { store.settings.defaultOutputFolder = "" }
                        .disabled(store.settings.defaultOutputFolder.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
}

// MARK: - Dialog

private struct DialogSettings: View {
    @Bindable var store: ProjectStore

    var body: some View {
        Form {
            Section {
                pathRow("Banner Image Path", text: $store.settings.bannerImagePath,
                        prompt: "None (the dialog title is the company name)",
                        message: "Choose the banner image the watcher uses.")
                sizeRow("Banner height", value: $store.settings.bannerHeight, range: 40...300, fallback: 130)
                    .disabled(store.settings.bannerImagePath.isEmpty)
            } footer: {
                caption("The watcher's --bannerimage (shown with --title none) and --bannerheight. This is the path on managed Macs. A rule can turn the banner off.")
            }
            Section {
                pathRow("Icon Path", text: $store.settings.iconPath,
                        prompt: "None (the watcher's red shield)",
                        message: "Choose the icon the watcher's dialog shows.")
                sizeRow("Icon size", value: $store.settings.iconSize, range: 40...400, fallback: 150)
            } footer: {
                caption("Passed to swiftDialog as --icon and --iconsize. None shows the watcher's standard red shield. A rule can turn the icon off.")
            }
            Section("Preview") {
                DialogPreviewView(
                    rule: RuleModel(name: "example", killProcess: "Example",
                                    dialogMessage: "# Example Blocked\n\nThis is how \(store.settings.orgNameFriendly) dialogs look."),
                    settings: store.settings)
                    .padding(8)
            }
        }
        .formStyle(.grouped)
    }

    /// A slider over an optional size: "Default" leaves the flag out so swiftDialog decides.
    private func sizeRow(_ title: String, value: Binding<Int?>, range: ClosedRange<Double>, fallback: Int) -> some View {
        LabeledContent(title) {
            HStack {
                Slider(value: Binding(
                    get: { Double(value.wrappedValue ?? fallback) },
                    set: { value.wrappedValue = Int(($0 / 5).rounded()) * 5 }),
                    in: range)
                    .accessibilityLabel(title)
                Text(value.wrappedValue.map { "\($0) pt" } ?? "Default")
                    .monospacedDigit()
                    .foregroundStyle(value.wrappedValue == nil ? .secondary : .primary)
                    .frame(width: 56, alignment: .trailing)
                Button("Reset") { value.wrappedValue = nil }
                    .disabled(value.wrappedValue == nil)
            }
        }
    }

    @ViewBuilder
    private func pathRow(_ title: String, text: Binding<String>, prompt: String, message: String) -> some View {
        HStack {
            TextField(title, text: text, prompt: Text(prompt))
            Button("Choose…") {
                if let url = FileDialogs.chooseFiles(types: [.image], message: message).first {
                    text.wrappedValue = url.path
                }
            }
        }
        if !text.wrappedValue.isEmpty, !FileManager.default.fileExists(atPath: text.wrappedValue) {
            Label("Not found on this Mac. That's fine if the path only exists on managed Macs; the preview shows a placeholder.",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        }
    }
}

// MARK: - Watcher

/// Builds the watcher's Jamf installer script from these Settings, to save or to upload to Jamf Pro.
private struct WatcherSettings: View {
    @Bindable var store: ProjectStore
    @State private var upload = WatcherUploadModel()

    private var template: String? { try? WatcherInstaller.bundledTemplate() }
    private var issues: [String] { WatcherInstaller.issues(for: store.settings) }
    private var jamfConfigured: Bool {
        JamfConnection.normalizedURL(store.settings.jamfURL) != nil && !store.settings.jamfClientID.isEmpty
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Installer version", value: template.flatMap(WatcherInstaller.version(of:)) ?? "Unavailable")
                value("Rule domains", "\(store.settings.orgPlistDomain).\(store.settings.preference).<rule-name>")
                value("LaunchDaemon label", store.settings.watcherLabel)
                value("Banner image", store.settings.bannerImagePath.isEmpty ? "None" : store.settings.bannerImagePath)
                value("Banner height", store.settings.bannerHeight.map { "\($0) pt" } ?? "Default")
                value("Icon", store.settings.iconPath.isEmpty ? "Red shield (default)" : store.settings.iconPath)
                value("Icon size", store.settings.iconSize.map { "\($0) pt" } ?? "Default")
                ForEach(issues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Watcher installer")
            } footer: {
                caption("One Jamf script that installs the Restricted Item Watcher and its LaunchDaemon with the values above baked in. Change them in General and Dialog, then save or upload again. Policy parameter 4: install (default) or uninstall.")
            }
            Section {
                Button("Save Installer Script…", systemImage: "square.and.arrow.down") { save() }
                    .disabled(!issues.isEmpty || template == nil)
            }
            Section {
                TextField("Script name", text: $store.settings.watcherScriptName, prompt: Text(WatcherInstaller.defaultScriptName))
                    .autocorrectionDisabled()
                    .disabled(upload.isBusy)
                HStack {
                    uploadButton
                    if upload.isBusy { ProgressView().controlSize(.small) }
                    Spacer()
                }
                uploadStatus
            } header: {
                Text("Jamf Pro")
            } footer: {
                caption("Uploads the script to the server in the Jamf Pro tab. Check first: it tells you whether a script with this name exists before anything is sent. The API role also needs Create, Read and Update Scripts. Nothing runs until you add the script to a policy.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.settings) { upload.reset() }
    }

    private func value(_ title: String, _ text: String) -> some View {
        LabeledContent(title) {
            Text(text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func script() -> String? {
        do {
            return try WatcherInstaller.build(template: WatcherInstaller.bundledTemplate(), settings: store.settings)
        } catch {
            store.message = error.localizedDescription
            return nil
        }
    }

    private func save() {
        guard let script = script(),
              let url = FileDialogs.saveFile(suggestedName: WatcherInstaller.fileName, type: .shellScript)
        else { return }
        do {
            try Data(script.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            store.message = "Couldn't save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    @ViewBuilder
    private var uploadButton: some View {
        if case .ready(let existingID) = upload.state {
            Button(existingID == nil ? "Create Script in Jamf Pro" : "Update Script in Jamf Pro") {
                guard let script = script() else { return }
                Task { await upload.upload(script: script, settings: store.settings) }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Upload to Jamf Pro…", systemImage: "icloud.and.arrow.up") {
                Task { await upload.check(settings: store.settings) }
            }
            .disabled(!issues.isEmpty || template == nil || !jamfConfigured || upload.isBusy)
            .help(jamfConfigured ? "Check Jamf Pro for a script with this name" : "Add your server and API client in the Jamf Pro tab first")
        }
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch upload.state {
        case .idle:
            if !jamfConfigured {
                status("Add your server and API client in the Jamf Pro tab to upload.", "info.circle", .secondary)
            }
        case .checking:
            status("Looking for a script with this name…", "magnifyingglass", .secondary)
        case .ready(let existingID):
            if let existingID {
                status("A script with this name exists (ID \(existingID)). Updating replaces its contents; policies that use it run the new version from then on.", "arrow.triangle.2.circlepath", .orange)
            } else {
                status("No script has this name. A new script is created; it does nothing until you add it to a policy.", "plus.circle.fill", .green)
            }
        case .publishing:
            status("Uploading…", "icloud.and.arrow.up", .secondary)
        case .done(let id, let created):
            status(created ? "Created script ID \(id). Add it to a policy to deploy the watcher." : "Updated script ID \(id).",
                   "checkmark.circle.fill", .green)
        case .failed(let message):
            status(message, "xmark.circle.fill", .red)
        }
    }

    private func status(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

// MARK: - Jamf Pro

private struct JamfSettings: View {
    @Bindable var store: ProjectStore
    @State private var model = JamfSettingsModel()
    @FocusState private var secretFocused: Bool
    private let enrolledURL = JamfConnection.enrolledServerURL()

    var body: some View {
        Form {
            Section {
                TextField("Jamf Pro URL", text: $store.settings.jamfURL, prompt: Text("https://company.jamfcloud.com"))
                    .autocorrectionDisabled()
                if !store.settings.jamfURL.isEmpty, JamfConnection.normalizedURL(store.settings.jamfURL) == nil {
                    Label(JamfError.invalidURL.localizedDescription, systemImage: "xmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let enrolledURL, store.settings.jamfURL != enrolledURL {
                    Button("Use This Mac's Server (\(URL(string: enrolledURL)?.host ?? enrolledURL))") {
                        store.settings.jamfURL = enrolledURL
                    }
                    .buttonStyle(.link)
                }
            } header: {
                Text("Server")
            }
            Section {
                TextField("Client ID", text: $store.settings.jamfClientID, prompt: Text("API client ID"))
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
                SecureField("Client Secret", text: $model.clientSecret, prompt: Text("API client secret"))
                    .focused($secretFocused)
                    .onSubmit { model.saveSecret() }
                if let error = model.keychainError {
                    Label(error, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("API client credentials")
            } footer: {
                caption("OAuth client credentials from Jamf Pro → Settings → API roles and clients. The secret is stored in your login keychain, never in preferences or files. The API role needs Create, Read and Update macOS Configuration Profiles, plus Create, Read and Update Scripts if you upload the watcher installer.")
            }
            Section {
                HStack {
                    Button("Test Connection") {
                        model.test(urlText: store.settings.jamfURL, clientID: store.settings.jamfClientID)
                    }
                    .disabled(model.testState == .testing || store.settings.jamfURL.isEmpty
                              || store.settings.jamfClientID.isEmpty || model.clientSecret.isEmpty)
                    if model.testState == .testing { ProgressView().controlSize(.small) }
                    Spacer()
                }
                switch model.testState {
                case .idle, .testing:
                    EmptyView()
                case .ok(let text):
                    result(text, "checkmark.circle.fill", .green)
                case .limited(let text):
                    result(text, "exclamationmark.triangle.fill", .orange)
                case .failed(let text):
                    result(text, "xmark.circle.fill", .red)
                }
            } footer: {
                caption("The test requests a token, checks that profiles can be read, and invalidates the token. Nothing is changed in Jamf Pro. Publish a rule from its Export menu.")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.loadSecret() }
        .onDisappear { model.saveSecret() }
        .onChange(of: secretFocused) { _, focused in
            if !focused { model.saveSecret() }
        }
        .onChange(of: store.settings.jamfURL) { model.credentialsChanged() }
        .onChange(of: store.settings.jamfClientID) { model.credentialsChanged() }
        .onChange(of: model.clientSecret) { model.credentialsChanged() }
    }

    private func result(_ text: String, _ symbol: String, _ tint: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
