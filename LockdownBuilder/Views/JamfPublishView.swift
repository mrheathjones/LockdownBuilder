import SwiftUI

/// Uploads one rule's `.mobileconfig` to Jamf Pro as a macOS configuration profile.
/// Two deliberate steps: a read-only check that says whether this creates or updates, then the upload.
struct JamfPublishView: View {
    @Bindable var store: ProjectStore
    let draft: RuleDraft
    @State private var model: JamfPublishModel
    @Environment(\.dismiss) private var dismiss

    init(store: ProjectStore, draft: RuleDraft) {
        self.store = store
        self.draft = draft
        _model = State(initialValue: JamfPublishModel(
            rule: draft.rule, name: store.settings.profileName(for: draft.rule.name)))
    }

    private var serverURL: URL? { JamfConnection.normalizedURL(store.settings.jamfURL) }
    private var isConfigured: Bool { serverURL != nil && !store.settings.jamfClientID.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "icloud.and.arrow.up.fill").font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Publish “\(draft.rule.name)” to Jamf Pro").font(.system(size: 15, weight: .semibold))
                    Text(serverURL?.host ?? "No Jamf Pro server set")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            VStack(alignment: .leading, spacing: 12) {
                if store.hasErrors(draft) {
                    notice("xmark.circle.fill", .red, "Fix the errors in this rule before publishing it.")
                } else if !isConfigured {
                    notice("gearshape", .orange, "Add your Jamf Pro URL and API client credentials in Settings → Jamf Pro first.")
                    SettingsLink { Text("Open Settings…") }
                } else {
                    form
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)

            Divider()
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if case .done = model.state {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    primaryButton
                }
            }
            .padding()
        }
        .frame(width: 520)
    }

    @ViewBuilder
    private var form: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "Configuration profile name", key: "PayloadDisplayName")
                TextField("Configuration profile name", text: $model.name,
                          prompt: Text(store.settings.defaultProfileName(for: draft.rule.name)))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .disabled(model.isBusy || isDone)
                Text("Jamf Pro matches profiles by this exact name: an existing profile with the name is updated, otherwise a new one is created.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            Divider()
            HStack(alignment: .firstTextBaseline) {
                FieldLabel(title: "Preference domain")
                Spacer()
                Text(store.settings.ruleDomain(for: draft.rule.name))
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(14)
        }
        .card()

        switch model.state {
        case .idle:
            notice("info.circle", .secondary, "Nothing is sent yet. Check Jamf Pro to see whether this creates a new profile or updates an existing one.")
        case .checking:
            notice("magnifyingglass", .secondary, "Looking for a profile with this name…")
        case .ready(let existingID):
            if let existingID {
                notice("arrow.triangle.2.circlepath", .orange,
                       "A profile with this name exists (ID \(existingID)). Updating replaces its payload and redeploys it to the computers already in its scope. Scope, category and site are not changed.")
            } else {
                notice("plus.circle.fill", .green,
                       "No profile has this name. A new computer-level profile is created with no scope, so it installs nowhere until you scope it in Jamf Pro.")
            }
        case .publishing:
            notice("icloud.and.arrow.up", .secondary, "Uploading…")
        case .done(let id, let created):
            notice("checkmark.circle.fill", .green,
                   created ? "Created profile ID \(id). It has no scope yet: assign it in Jamf Pro."
                           : "Updated profile ID \(id).")
            if let url = serverURL.flatMap({ URL(string: "\($0.absoluteString)/OSXConfigurationProfiles.html?id=\(id)&o=r") }) {
                Link("Open in Jamf Pro", destination: url).font(.system(size: 12))
            }
        case .failed(let message):
            notice("xmark.circle.fill", .red, message)
        }
    }

    private var isDone: Bool {
        if case .done = model.state { true } else { false }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if case .ready(let existingID) = model.state {
            Button(existingID == nil ? "Create Profile" : "Update Profile") {
                // The chosen name is remembered so the exported payload and the next publish use it too.
                let isDefault = model.trimmedName == store.settings.defaultProfileName(for: draft.rule.name)
                store.settings.profileNames[draft.rule.name] = isDefault ? nil : model.trimmedName
                Task { await model.publish(settings: store.settings) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        } else {
            Button("Check Jamf Pro") {
                Task { await model.check(settings: store.settings) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canCheck || !isConfigured || store.hasErrors(draft))
        }
    }

    private func notice(_ symbol: String, _ tint: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(text).font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
