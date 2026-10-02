import SwiftUI

struct SettingsView: View {
    @Bindable var store: ProjectStore

    var body: some View {
        Form {
            Section("Preference domain") {
                TextField("ORG_PLIST_DOMAIN", text: $store.settings.orgPlistDomain, prompt: Text("com.company"))
                TextField("PREFERENCE", text: $store.settings.preference, prompt: Text("restrict"))
                LabeledContent("Rule domain") {
                    Text("\(store.settings.orgPlistDomain).\(store.settings.preference).<rule-name>")
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                LabeledContent("Watcher label") {
                    Text(store.settings.watcherLabel)
                        .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                ForEach(store.settings.issues, id: \.self) { issue in
                    Label(issue, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                }
            }
            Section("Generated text") {
                TextField("ORG_NAME_FRIENDLY", text: $store.settings.orgNameFriendly, prompt: Text("Company Name"))
                Text("Used in the wording of templates and in .mobileconfig profiles.")
                    .font(.caption).foregroundStyle(.secondary)
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
        .frame(width: 520, height: 540)
    }
}
