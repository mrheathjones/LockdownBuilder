import SwiftUI

struct RuleEditorView: View {
    let store: ProjectStore
    @Binding var draft: RuleDraft
    @AppStorage("showPreview") private var showPreview = true
    @State private var isShowingDiff = false

    var body: some View {
        HStack(spacing: 0) {
            RuleForm(store: store, draft: $draft)
                .frame(minWidth: 400, maxWidth: .infinity)
            if showPreview {
                Divider()
                PreviewPane(store: store, draft: draft)
                    .frame(minWidth: 320, idealWidth: 440, maxWidth: 560)
            }
        }
        .navigationTitle(draft.rule.name.isEmpty ? "New Rule" : draft.rule.name)
        .toolbar {
            ToolbarItemGroup {
                Button("Test", systemImage: "play.circle") { store.isShowingTestHarness = true }
                    .help("Dry-run, simulate the dialog, or live-test the kill (⌘T)")
                Button("Compare", systemImage: "arrow.left.arrow.right") { isShowingDiff = true }
                    .help("Compare with the last exported plist")
                Button("Save", systemImage: "square.and.arrow.down") { store.save() }
                    .help("Save all rules to the project folder (⌘S)")
                Menu("Export", systemImage: "square.and.arrow.up") {
                    Button("Export This Plist…") { store.export(draft, format: .plist) }
                    Button("Export This .mobileconfig…") { store.export(draft, format: .mobileconfig) }
                    Divider()
                    Button("Export All Plists…") { store.exportAll(format: .plist) }
                    Button("Export All .mobileconfig…") { store.exportAll(format: .mobileconfig) }
                    Divider()
                    Button("Export JSON Schema…") { store.exportSchema() }
                }
                .help("Export (⌘E exports this plist)")
                Button("Preview", systemImage: "sidebar.trailing") { showPreview.toggle() }
                    .help(showPreview ? "Hide the preview" : "Show the preview")
            }
        }
        .sheet(isPresented: Binding(get: { store.isShowingTestHarness }, set: { store.isShowingTestHarness = $0 })) {
            TestHarnessView(rule: draft.rule, settings: store.settings)
        }
        .sheet(isPresented: $isShowingDiff) {
            DiffView(ruleName: draft.rule.name, old: store.lastExportedPlist(for: draft),
                     new: RuleExport.plist(for: draft.rule))
        }
    }
}

// MARK: - Form

private struct RuleForm: View {
    let store: ProjectStore
    @Binding var draft: RuleDraft
    @State private var pendingPreset: DialogPreset?

    private var issues: [ValidationIssue] { store.issues(for: draft) }

    var body: some View {
        Form {
            if !draft.importNotes.isEmpty {
                Section("Import notes") {
                    ForEach(draft.importNotes) { note in
                        Label(note.message, systemImage: note.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(note.isError ? .red : .orange)
                    }
                }
            }

            Section("Rule") {
                field("Name", .name, prompt: "apple-account", text: $draft.rule.name)
                LabeledContent("Preference domain") {
                    Text(store.settings.ruleDomain(for: draft.rule.name))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("What to kill") {
                field("KillProcess", .killProcess, prompt: "System Settings", text: $draft.rule.killProcess)
                Text("The exact process name, as pgrep -x sees it. Full names match and may contain spaces.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("When to act") {
                Picker("Rule type", selection: $draft.mode) {
                    Text("Presence").tag(RuleModel.Kind.presence)
                    Text("Event").tag(RuleModel.Kind.event)
                    Text("Watch & Kill").tag(RuleModel.Kind.watchOneKillAnother)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("Rule type")
                .onChange(of: draft.mode) { _, newMode in
                    // The two keys are mutually exclusive, so switching types drops the other one.
                    switch newMode {
                    case .presence: draft.rule.predicate = nil; draft.rule.watchProcess = nil
                    case .event: draft.rule.watchProcess = nil
                    case .watchOneKillAnother: draft.rule.predicate = nil
                    }
                }
                Text(modeExplanation).font(.caption).foregroundStyle(.secondary)

                switch draft.mode {
                case .event:
                    field("Predicate", .predicate, prompt: #"process == "X" AND eventMessage CONTAINS "Y""#,
                          text: $draft.rule.predicate.orEmpty, axis: .vertical, monospaced: true)
                case .watchOneKillAnother:
                    field("WatchProcess", .watchProcess, prompt: "InternetAccountsSettingsExtension",
                          text: $draft.rule.watchProcess.orEmpty)
                case .presence:
                    EmptyView()
                }

                LabeledContent("CooldownSeconds") {
                    TextField("CooldownSeconds", text: cooldownBinding, prompt: Text("\(RuleModel.defaultCooldownSeconds)"))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 80)
                        .accessibilityLabel("Cooldown seconds")
                }
                issueRows(for: .cooldownSeconds)
            }

            Section("Dialog") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("DialogMessage")
                        Spacer()
                        Menu("Presets") {
                            ForEach(DialogPreset.allCases) { preset in
                                Button(preset.rawValue) { pendingPreset = preset }
                            }
                        }
                        .fixedSize()
                        .accessibilityLabel("Message presets")
                    }
                    TextEditor(text: $draft.rule.dialogMessage)
                        .font(.body.monospaced())
                        .frame(minHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .accessibilityLabel("Dialog message")
                    Text("swiftDialog Markdown. Start with “# Title” for a large bold title; blank lines make paragraphs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                issueRows(for: .dialogMessage)
                field("ButtonText", .buttonText, prompt: "OK", text: $draft.rule.buttonText.orEmpty)
                field("ButtonAction", .buttonAction, prompt: "/Applications/Self Service.app", text: $draft.rule.buttonAction.orEmpty)
                HStack {
                    Text("Presets").font(.caption).foregroundStyle(.secondary)
                    Button("Self Service") { draft.rule.buttonAction = "/Applications/Self Service.app" }
                    Button("jamfselfservice://content") { draft.rule.buttonAction = "jamfselfservice://content" }
                    Button("Clear") { draft.rule.buttonAction = nil }
                }
                .buttonStyle(.link).font(.caption)
                field("DismissButtonText", .dismissButtonText, prompt: "Done (adds a second button)", text: $draft.rule.dismissButtonText.orEmpty)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Replace the message with the “\(pendingPreset?.rawValue ?? "")” preset?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })
        ) {
            Button("Replace Message") {
                if let preset = pendingPreset {
                    draft.rule.dialogMessage = preset.message(appName: draft.rule.killProcess, org: store.settings.orgNameFriendly)
                }
                pendingPreset = nil
            }
        } message: {
            Text("The preset is a starting point; edit it freely afterwards.")
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func field(
        _ title: String, _ key: RuleField, prompt: String, text: Binding<String>,
        axis: Axis = .horizontal, monospaced: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(title, text: text, prompt: Text(prompt), axis: axis)
                .font(monospaced ? .body.monospaced() : .body)
                .accessibilityLabel(title)
            issueRows(for: key)
        }
    }

    @ViewBuilder
    private func issueRows(for key: RuleField) -> some View {
        ForEach(issues.filter { $0.field == key }) { issue in
            Label(issue.message, systemImage: issue.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(issue.isError ? .red : .orange)
        }
    }

    private var cooldownBinding: Binding<String> {
        Binding(
            get: { draft.rule.cooldownSeconds.map(String.init) ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                draft.rule.cooldownSeconds = Int(trimmed)  // non-numeric input leaves the key absent
            })
    }

    private var modeExplanation: String {
        switch draft.mode {
        case .presence:
            "No predicate. The watcher polls every 0.5 s, so it is simple, but it can't catch a command that exits faster than the poll (e.g. one-shot CLI commands)."
        case .event:
            "Driven by a unified-log line, about 0.25 s measured and no polling. Needs a log line that appears only when the user does the thing you want to block."
        case .watchOneKillAnother:
            "Polls WatchProcess but kills KillProcess, e.g. watch InternetAccountsSettingsExtension and kill System Settings. Kill the host app: killing only an extension makes Settings show “Extension process exited”."
        }
    }
}

extension Binding where Value == String? {
    /// Presents an optional string as a text field value: an empty field means the key is absent.
    var orEmpty: Binding<String> {
        Binding<String>(
            get: { wrappedValue ?? "" },
            set: { wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Preview

private struct PreviewPane: View {
    let store: ProjectStore
    let draft: RuleDraft
    enum Tab: String { case dialog, plist, mobileconfig }
    @AppStorage("previewTab") private var tab: Tab = .dialog

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Preview", selection: $tab) {
                    Text("Dialog").tag(Tab.dialog)
                    Text("Plist").tag(Tab.plist)
                    Text(".mobileconfig").tag(Tab.mobileconfig)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                if tab == .dialog {
                    Button("Copy Command", systemImage: "terminal") {
                        FileDialogs.copyToClipboard(DialogCommand.shellCommand(for: draft.rule, settings: store.settings))
                    }
                    .help("Copy the swiftDialog command the watcher would run")
                } else {
                    Button("Copy", systemImage: "doc.on.doc") {
                        FileDialogs.copyToClipboard(store.text(for: draft.rule, format: format))
                    }
                    .help("Copy the XML to the clipboard")
                }
            }
            switch tab {
            case .dialog:
                DialogPreviewView(rule: draft.rule, settings: store.settings)
                Text("Approximate preview. Use Test (⌘T) → Simulate Dialog to see the real swiftDialog window.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            case .plist, .mobileconfig:
                filePreview
            }
        }
        .padding()
    }

    private var format: ExportFormat { tab == .mobileconfig ? .mobileconfig : .plist }

    @ViewBuilder
    private var filePreview: some View {
        let blocking = store.issues(for: draft).filter(\.isError)
        Group {
            Text(store.fileName(for: draft.rule, format: format))
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .textSelection(.enabled)
            if !blocking.isEmpty {
                Label("\(blocking.count) error\(blocking.count == 1 ? "" : "s") to fix before exporting.", systemImage: "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(.red)
            } else if format == .mobileconfig {
                Text("Suggested Jamf profile name: \(store.settings.profileName(for: draft.rule.name))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(store.text(for: draft.rule, format: format))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
