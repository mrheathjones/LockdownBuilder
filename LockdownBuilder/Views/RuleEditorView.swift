import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct RuleEditorView: View {
    @Bindable var store: ProjectStore
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
                    .frame(width: 420)
            }
        }
        .navigationTitle(draft.rule.name.isEmpty ? "New Rule" : draft.rule.name)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem {
                Button { store.isShowingTestHarness = true } label: {
                    Label("Test", systemImage: "play.circle").labelStyle(.titleAndIcon)
                }
                .help("Dry-run, simulate the dialog, or live-test the quit (⌘T)")
            }
            ToolbarItem {
                ControlGroup {
                    Button("Compare", systemImage: "arrow.left.arrow.right") { isShowingDiff = true }
                        .help("Compare with the last exported plist")
                    Button("Save", systemImage: "square.and.arrow.down") { store.save() }
                        .help("Save all rules to the project folder (⌘S)")
                }
            }
            ToolbarItem {
                Menu {
                    Button("Export This Plist…") { store.export(draft, format: .plist) }
                    Button("Export This .mobileconfig…") { store.export(draft, format: .mobileconfig) }
                    Divider()
                    Button("Publish to Jamf Pro…") { store.isShowingJamfPublish = true }
                    Divider()
                    Button("Export All Plists…") { store.exportAll(format: .plist) }
                    Button("Export All .mobileconfig…") { store.exportAll(format: .mobileconfig) }
                    Divider()
                    Button("Export JSON Schema…") { store.exportSchema() }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up").labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .help("Export or publish (⌘E exports this plist)")
            }
            ToolbarItem {
                Toggle(isOn: $showPreview) {
                    Label("Preview", systemImage: "sidebar.trailing")
                }
                .toggleStyle(.button)
                .help(showPreview ? "Hide the preview" : "Show the preview")
            }
        }
        .sheet(isPresented: $store.isShowingTestHarness) {
            TestHarnessView(rule: draft.rule, settings: store.settings)
        }
        .sheet(isPresented: $store.isShowingJamfPublish) {
            JamfPublishView(store: store, draft: draft)
        }
        .sheet(isPresented: $isShowingDiff) {
            DiffView(ruleName: draft.rule.name, old: store.lastExportedPlist(for: draft),
                     new: RuleExport.plist(for: draft.rule))
        }
    }

    private var subtitle: String {
        let count = store.issues(for: draft).count
        var parts: [String] = []
        if count > 0 { parts.append("\(count) issue\(count == 1 ? "" : "s")") }
        if store.isDirty(draft) { parts.append("Unsaved changes") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Form

private struct RuleForm: View {
    let store: ProjectStore
    @Binding var draft: RuleDraft
    @State private var pendingPreset: DialogPreset?
    @State private var savingPreset = false
    @State private var newPresetName = ""
    @State private var pickingTarget = false
    @State private var discovering = false
    @State private var liveTesting = false
    @State private var syntaxResult: (ok: Bool, text: String)?
    @State private var checkingSyntax = false
    @State private var draftingMessage = false
    @Environment(\.ruleAssistant) private var assistant

    private var issues: [ValidationIssue] { store.issues(for: draft) }

    private func hasError(_ field: RuleField) -> Bool {
        issues.contains { $0.field == field && $0.isError }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !draft.importNotes.isEmpty { importNotes }
                step(1, "What to quit") {
                    if draft.mode == .notifyOnly { nothingToQuit } else { whatToQuit }
                }
                step(2, "When to act") { whenToAct }
                step(3, "What the user sees") { whatTheUserSees }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .textFieldStyle(.roundedBorder)
        .sheet(isPresented: $pickingTarget) {
            TargetPickerView { choice in
                switch choice {
                case .kill(let name):
                    draft.rule.killProcess = name
                case .watch(let name):
                    draft.mode = .watchOneKillAnother
                    draft.rule.predicate = nil
                    draft.rule.watchProcess = name
                case .watchAndKill(let watch, let kill):
                    draft.mode = .watchOneKillAnother
                    draft.rule.predicate = nil
                    draft.rule.watchProcess = watch
                    draft.rule.killProcess = kill
                }
            }
        }
        .sheet(isPresented: $discovering) {
            DiscoveryView(target: draft.rule.killProcess ?? "") { predicate in
                if draft.mode != .notifyOnly { draft.mode = .event }
                draft.rule.watchProcess = nil
                draft.rule.predicate = predicate
            }
        }
        .sheet(isPresented: $draftingMessage) {
            MessageDraftView(rule: draft.rule, settings: store.settings) { message in
                draft.rule.dialogMessage = message
            }
        }
        .sheet(isPresented: $liveTesting) {
            PredicateLiveTestView(predicate: draft.rule.predicate ?? "")
        }
        .onChange(of: draft.rule.predicate) { syntaxResult = nil }
        .onChange(of: draft.mode) { _, newMode in
            // The two keys are mutually exclusive, so switching types drops the other one.
            switch newMode {
            case .presence: draft.rule.predicate = nil; draft.rule.watchProcess = nil
            case .event: draft.rule.watchProcess = nil
            case .watchOneKillAnother: draft.rule.predicate = nil
            case .notifyOnly: draft.rule.watchProcess = nil; draft.rule.killProcess = nil
            }
        }
        .confirmationDialog(
            "Replace the message with the “\(pendingPreset?.name ?? "")” preset?",
            isPresented: Binding(get: { pendingPreset != nil }, set: { if !$0 { pendingPreset = nil } })
        ) {
            Button("Replace Message") {
                if let preset = pendingPreset {
                    draft.rule.dialogMessage = preset.message(appName: draft.rule.killProcess ?? "")
                }
                pendingPreset = nil
            }
        } message: {
            Text("The preset is a starting point; edit it freely afterwards.")
        }
        .alert("Save Message as Preset", isPresented: $savingPreset) {
            TextField("Preset name", text: $newPresetName)
            Button("Save") { saveMessageAsPreset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(saveAsPresetExplanation)
        }
    }

    private var saveAsPresetExplanation: String {
        let shared = "Watcher variables such as {{companyName}} stay as typed. Presets are managed in Settings → Dialog."
        if let app = draft.rule.killProcess?.trimmingCharacters(in: .whitespaces), !app.isEmpty {
            return "“\(app)” in the message becomes \(DialogPreset.appNameToken), so the preset fits other rules. " + shared
        }
        return shared
    }

    private func saveMessageAsPreset() {
        let base = newPresetName.trimmingCharacters(in: .whitespaces)
        let name = DialogPreset.uniqueName(base.isEmpty ? "New preset" : base, among: store.settings.dialogPresets)
        store.settings.dialogPresets.append(
            DialogPreset.generalizing(draft.rule.dialogMessage, appName: draft.rule.killProcess ?? "", name: name))
    }

    private func step(_ number: Int, _ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StepHeader(number: number, title: title)
            content()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    // Title-sized, but drawn as a field so it is clearly editable.
                    TextField("Rule name", text: $draft.rule.name, prompt: Text("rule-name"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7)
                            .strokeBorder(hasError(.name) ? AnyShapeStyle(Color.red.opacity(0.5)) : AnyShapeStyle(.quaternary)))
                        .accessibilityLabel("Name")
                    Text(store.settings.ruleDomain(for: draft.rule.name))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 12)
                statusPill
            }
            issueRows(for: .name)
            if let version = draft.rule.requiredWatcherVersion {
                Label("Needs Restricted Item Watcher \(version) or later (the installer in Settings → Watcher deploys the current one).",
                      systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                FieldLabel(title: "Display name", key: "PayloadDisplayName")
                    .frame(width: 130, alignment: .leading)
                TextField("Display name", text: displayName,
                          prompt: Text(store.settings.defaultProfileName(for: draft.rule.name)))
                    .labelsHidden()
                    .accessibilityLabel("Display name")
                    .help("The configuration profile's name in Jamf Pro and on the Mac. It is part of the .mobileconfig, not of the rule plist.")
            }
            sentence
        }
        .onChange(of: draft.rule.name) { old, new in
            store.settings.moveProfileName(from: old, to: new)
        }
    }

    /// The profile's friendly name, kept in Settings by rule name because the rule plist has no place for it.
    private var displayName: Binding<String> {
        Binding(
            get: { store.settings.profileNames[draft.rule.name] ?? "" },
            set: { store.settings.setProfileName($0, for: draft.rule.name) })
    }

    private var statusPill: some View {
        let count = issues.count
        return Label(count == 0 ? "Ready to export" : "\(count) to fix",
                     systemImage: count == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(count == 0 ? .green : .orange)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background((count == 0 ? Color.green : .orange).opacity(0.15), in: Capsule())
            .fixedSize()
    }

    /// "When [trigger] → quit [process] → show “[title]”": the rule in one line.
    private var sentence: some View {
        let kill = draft.rule.killProcess ?? "a process"
        let trigger = switch draft.mode {
        case .presence: "\(kill) is running"
        case .watchOneKillAnother: "\(draft.rule.watchProcess ?? "a process") is running"
        case .event, .notifyOnly: "a matching log line appears"
        }
        let message = MessageVariables.expand(draft.rule.dialogMessage, rule: draft.rule, settings: store.settings)
        let title = DialogMarkdown.parse(message).title.map { "“\($0)”" } ?? "message"
        return FlowLayout {
            Text("When")
            chip(trigger)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            if draft.mode != .notifyOnly {
                Text("quit")
                chip(kill, isError: hasError(.killProcess))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
            }
            Text("show")
            chip(title)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func chip(_ text: String, isError: Bool = false) -> some View {
        Text(text)
            .fontWeight(.medium)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .foregroundStyle(isError ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
            .background(isError ? AnyShapeStyle(Color.red.opacity(0.15)) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 5))
    }

    private var importNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import notes").font(.system(size: 13, weight: .semibold))
            ForEach(draft.importNotes) { IssueLabel(issue: $0) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: Step 1

    private var whatToQuit: some View {
        let killError = issues.first { $0.field == .killProcess && $0.isError }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                dropTile
                FieldLabel(title: "Process to quit", key: "KillProcess")
                    .frame(width: 120, alignment: .leading)
                TextField("Process to quit", text: $draft.rule.killProcess.orEmpty, prompt: Text("e.g. System Settings"))
                    .labelsHidden()
                    .accessibilityLabel("KillProcess")
                Button("Choose…") { pickingTarget = true }
                    .help("Pick a running process, drop an app, or enter a command-line path")
            }
            .padding(14)
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if killError == nil {
                    Text("The exact process name, as pgrep -x sees it. Drop an app here to use its executable name.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                issueRows(for: .killProcess)
                if let kill = draft.rule.killProcess, !kill.contains("/") {
                    ProcessStatusLabel(name: kill)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .card(border: killError == nil ? nil : .red.opacity(0.5))
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first,
                  let target = TargetResolver.target(forBundleAt: url) ?? TargetResolver.target(forExecutablePath: url.path)
            else { return false }
            draft.rule.killProcess = target.name
            return true
        }
    }

    /// Step 1 for a notify-only rule: there is no KillProcess to pick.
    private var nothingToQuit: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Nothing is quit. This rule only shows the dialog when the log line appears.", systemImage: "bell")
            Text("A rule without KillProcess needs Restricted Item Watcher \(RuleModel.notifyOnlyMinimumWatcherVersion) or later. Older watchers skip it as invalid.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var dropTile: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .frame(width: 40, height: 40)
            .overlay {
                if draft.rule.killProcess == nil {
                    Image(systemName: "square.and.arrow.down").foregroundStyle(.secondary)
                } else if let icon = Self.appIcon(named: draft.rule.killProcess ?? "") {
                    Image(nsImage: icon).resizable().frame(width: 30, height: 30)
                } else {
                    Image(systemName: "macwindow").foregroundStyle(.secondary)
                }
            }
            .help("Drop an app here to use its executable name")
            .accessibilityHidden(true)
    }

    /// The icon of an app in the usual places whose name matches the process name (decoration only).
    private static func appIcon(named name: String) -> NSImage? {
        guard !name.contains("/") else { return nil }
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    // MARK: Step 2

    private var whenToAct: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    modeCard(.presence, symbol: "eye", detail: "Polls every 0.5 s while the app runs")
                    modeCard(.event, symbol: "bolt", detail: "Fires on a unified-log line, ~0.25 s")
                }
                GridRow {
                    modeCard(.watchOneKillAnother, symbol: "binoculars", detail: "Watch one process, quit another")
                    modeCard(.notifyOnly, symbol: "bell", detail: "Shows the dialog on a log line, quits nothing")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rule type")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(modeExplanation)
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    switch draft.mode {
                    case .event, .notifyOnly:
                        VStack(alignment: .leading, spacing: 6) {
                            FieldLabel(title: "Log predicate", key: "Predicate")
                            TextField("Log predicate", text: $draft.rule.predicate.orEmpty,
                                      prompt: Text(#"process == "X" AND eventMessage CONTAINS "Y""#), axis: .vertical)
                                .lineLimit(3...8)
                                .font(.system(size: 12, design: .monospaced))
                                .labelsHidden()
                                .accessibilityLabel("Predicate")
                            issueRows(for: .predicate)
                            predicateTools
                        }
                    case .watchOneKillAnother:
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                FieldLabel(title: "Process to watch", key: "WatchProcess")
                                    .frame(width: 120, alignment: .leading)
                                TextField("Process to watch", text: $draft.rule.watchProcess.orEmpty,
                                          prompt: Text("e.g. InternetAccountsSettingsExtension"))
                                    .labelsHidden()
                                    .accessibilityLabel("WatchProcess")
                            }
                            issueRows(for: .watchProcess)
                            if let watch = draft.rule.watchProcess, !watch.contains("/") {
                                ProcessStatusLabel(name: watch)
                            }
                        }
                    case .presence:
                        EmptyView()
                    }
                }
                .padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        FieldLabel(title: "Cooldown", key: "CooldownSeconds",
                                   subtitle: draft.mode == .notifyOnly
                                       ? "Shortest time between dialogs."
                                       : "Shortest time between dialogs. The quit happens every time.")
                        Spacer()
                        TextField("Cooldown", text: cooldownBinding, prompt: Text("\(RuleModel.defaultCooldownSeconds)"))
                            .labelsHidden()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 56)
                            .accessibilityLabel("Cooldown seconds")
                        Text("s").foregroundStyle(.secondary)
                        Stepper("Cooldown", value: cooldownStepper, in: 0...86_400)
                            .labelsHidden()
                    }
                    issueRows(for: .cooldownSeconds)
                }
                .padding(14)
            }
            .card()
        }
    }

    private func modeCard(_ mode: RuleModel.Kind, symbol: String, detail: String) -> some View {
        let selected = draft.mode == mode
        return Button { draft.mode = mode } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(height: 24)
                    Spacer()
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                Text(mode.label).fontWeight(.semibold)
                Text(detail)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .background(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.label)
        .accessibilityHint(detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var predicateTools: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Discover…") { discovering = true }
                    .help("Record a baseline and your action, then rank log lines that only appear during the action")
                Button("Check Syntax") {
                    guard let predicate = draft.rule.predicate else { return }
                    checkingSyntax = true
                    Task {
                        do {
                            let error = try await ProcessRunner.shared.checkPredicate(predicate)
                            syntaxResult = error.map { (false, $0) } ?? (true, "log stream accepts this predicate.")
                        } catch {
                            syntaxResult = (false, error.localizedDescription)
                        }
                        checkingSyntax = false
                    }
                }
                .disabled(draft.rule.predicate == nil || checkingSyntax)
                Button("Test Live…") { liveTesting = true }
                    .disabled(draft.rule.predicate == nil)
                if checkingSyntax { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            if let syntaxResult {
                Label(syntaxResult.text, systemImage: syntaxResult.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(syntaxResult.ok ? .green : .red)
            }
        }
    }

    // MARK: Step 3

    private var whatTheUserSees: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                MessageEditor(message: $draft.rule.dialogMessage, hasError: hasError(.dialogMessage),
                              variables: MessageEditorVariable.watcher(rule: draft.rule, settings: store.settings)) {
                    aiDraftButton
                    Menu("Presets") {
                        if store.settings.dialogPresets.isEmpty {
                            Text("No presets")
                        }
                        ForEach(store.settings.dialogPresets) { preset in
                            Button(preset.name) { pendingPreset = preset }
                        }
                        Divider()
                        Button("Save Message as Preset…") {
                            let title = DialogMessageParts.split(draft.rule.dialogMessage).title
                            newPresetName = DialogPreset.uniqueName(title.isEmpty ? "New preset" : title, among: store.settings.dialogPresets)
                            savingPreset = true
                        }
                        .disabled(draft.rule.dialogMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Manage Presets…") { store.showSettings(.dialog) }
                    }
                    .fixedSize()
                    .accessibilityLabel("Message presets")
                }
                issueRows(for: .dialogMessage)
            }
            .padding(14)
            Divider()
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "Main button", key: "ButtonText")
                    TextField("Main button", text: $draft.rule.buttonText.orEmpty, prompt: Text("OK"))
                        .labelsHidden()
                        .accessibilityLabel("ButtonText")
                    issueRows(for: .buttonText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    FieldLabel(title: "Second button", key: "DismissButtonText")
                    TextField("Second button", text: $draft.rule.dismissButtonText.orEmpty, prompt: Text("None (one button)"))
                        .labelsHidden()
                        .accessibilityLabel("DismissButtonText")
                    issueRows(for: .dismissButtonText)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(title: "Main button opens", key: "ButtonAction")
                HStack {
                    TextField("Main button opens", text: $draft.rule.buttonAction.orEmpty, prompt: Text("Nothing (closes the dialog)"))
                        .labelsHidden()
                        .accessibilityLabel("ButtonAction")
                    Button("Self Service") { draft.rule.buttonAction = "/Applications/Self Service.app" }
                    Button("jamfselfservice://") { draft.rule.buttonAction = "jamfselfservice://content" }
                }
                .controlSize(.small)
                issueRows(for: .buttonAction)
            }
            .padding(14)
            Divider()
            infoButton
                .padding(14)
            Divider()
            windowOptions
                .padding(14)
        }
        .card()
    }

    /// An optional "More Information" button that opens a local file or a web page.
    private var infoButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(title: "More-information button opens", key: "InfoButtonAction",
                       subtitle: "Adds a button at the bottom left. Pressing it closes the dialog and opens a local file, an app or a web page.")
            HStack {
                TextField("More-information button opens", text: $draft.rule.infoButtonAction.orEmpty,
                          prompt: Text("None (no button)"))
                    .labelsHidden()
                    .accessibilityLabel("InfoButtonAction")
                Button("Choose File…") {
                    if let url = FileDialogs.chooseFiles(types: [.item], message: "Choose the file the button opens on the managed Macs.").first {
                        draft.rule.infoButtonAction = url.path
                    }
                }
                .help("Pick a local file; its path must also exist on the managed Macs")
            }
            .controlSize(.small)
            issueRows(for: .infoButtonAction)
            HStack(spacing: 12) {
                FieldLabel(title: "Button label", key: "InfoButtonText")
                    .frame(width: 120, alignment: .leading)
                TextField("Button label", text: $draft.rule.infoButtonText.orEmpty, prompt: Text(RuleModel.defaultInfoButtonText))
                    .labelsHidden()
                    .accessibilityLabel("InfoButtonText")
                    .disabled(draft.rule.infoButtonAction == nil && draft.rule.infoButtonText == nil)
            }
            issueRows(for: .infoButtonText)
        }
    }

    /// Size, position and behaviour of the dialog window. Every control maps "the default" to an absent key,
    /// so a rule that doesn't customise the window exports exactly as before.
    private var windowOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Dialog window").font(.system(size: 13, weight: .medium))
                Text("Drag a slider to resize the preview. A simulated dialog that is open follows too.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            sizeSlider("Width", key: "DialogWidth", value: $draft.rule.dialogWidth,
                       default: DialogCommand.defaultWidth, range: 300...1600)
            sizeSlider("Height", key: "DialogHeight", value: $draft.rule.dialogHeight,
                       default: DialogCommand.defaultHeight, range: 200...1200)
            issueRows(for: .dialogWidth)
            issueRows(for: .dialogHeight)
            HStack(spacing: 12) {
                FieldLabel(title: "Position", key: "DialogPosition")
                    .frame(width: 160, alignment: .leading)
                Picker("Position", selection: $draft.rule.dialogPosition) {
                    Text("Center (default)").tag(RuleModel.DialogPosition?.none)
                    Divider()
                    ForEach(RuleModel.DialogPosition.allCases.filter { $0 != .center }, id: \.self) { position in
                        Text(position.label).tag(RuleModel.DialogPosition?.some(position))
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 0)
                Button("Reset Size") { draft.rule.dialogWidth = nil; draft.rule.dialogHeight = nil }
                    .controlSize(.small)
                    .disabled(draft.rule.dialogWidth == nil && draft.rule.dialogHeight == nil)
                    .help("Use the watcher's default size (\(DialogCommand.defaultWidth) × \(DialogCommand.defaultHeight))")
            }
            HStack(spacing: 12) {
                FieldLabel(title: "Message alignment", key: "DialogMessageAlignment")
                    .frame(width: 160, alignment: .leading)
                Picker("Message alignment", selection: choice(\.dialogMessageAlignment, default: .left)) {
                    Image(systemName: "text.alignleft").accessibilityLabel("Left").tag(RuleModel.MessageAlignment.left)
                    Image(systemName: "text.aligncenter").accessibilityLabel("Center").tag(RuleModel.MessageAlignment.center)
                    Image(systemName: "text.alignright").accessibilityLabel("Right").tag(RuleModel.MessageAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Horizontal alignment of the message text")
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                FieldLabel(title: "Message position", key: "DialogMessagePosition")
                    .frame(width: 160, alignment: .leading)
                Picker("Message position", selection: choice(\.dialogMessagePosition, default: .top)) {
                    Text("Top").tag(RuleModel.MessagePosition.top)
                    Text("Center").tag(RuleModel.MessagePosition.center)
                    Text("Bottom").tag(RuleModel.MessagePosition.bottom)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Vertical position of the message in the dialog")
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 24) {
                windowToggle("Show banner", key: "DialogShowBanner", flag(\.dialogShowBanner, default: true))
                    .disabled(store.settings.bannerImagePath.isEmpty)
                    .help(store.settings.bannerImagePath.isEmpty
                          ? "No banner image is set in Settings → Dialog"
                          : "Off: this rule's dialog shows the company name as its title instead of the banner")
                windowToggle("Show icon", key: "DialogShowIcon", flag(\.dialogShowIcon, default: true))
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 24) {
                windowToggle("Keep on top", key: "DialogOnTop", flag(\.dialogOnTop, default: true))
                windowToggle("Movable", key: "DialogMoveable", flag(\.dialogMoveable, default: true))
                windowToggle("Blur screen", key: "DialogBlurScreen", flag(\.dialogBlurScreen, default: false))
                Spacer(minLength: 0)
            }
        }
    }

    /// A slider over an optional size: untouched it shows swiftDialog's default and the key stays absent.
    private func sizeSlider(_ title: String, key: String, value: Binding<Int?>, default defaultValue: Int,
                            range: ClosedRange<Double>) -> some View {
        HStack(spacing: 12) {
            FieldLabel(title: title, key: key)
                .frame(width: 160, alignment: .leading)
            Slider(value: Binding(
                get: { min(max(Double(value.wrappedValue ?? defaultValue), range.lowerBound), range.upperBound) },
                set: { value.wrappedValue = Int(($0 / 10).rounded()) * 10 }),
                in: range)
                .accessibilityLabel(key)
            Text(value.wrappedValue.map { "\($0) pt" } ?? "\(defaultValue) pt (default)")
                .font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(value.wrappedValue == nil ? .secondary : .primary)
                .frame(width: 110, alignment: .trailing)
        }
    }

    private func windowToggle(_ title: String, key: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            FieldLabel(title: title, key: key)
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel(key)
    }

    /// A picker over an optional key: the default choice is stored as "absent".
    private func choice<Value: Equatable>(_ keyPath: WritableKeyPath<RuleModel, Value?>, default defaultValue: Value) -> Binding<Value> {
        Binding(
            get: { draft.rule[keyPath: keyPath] ?? defaultValue },
            set: { draft.rule[keyPath: keyPath] = $0 == defaultValue ? nil : $0 })
    }

    /// A checkbox over an optional key: the default value is stored as "absent".
    private func flag(_ keyPath: WritableKeyPath<RuleModel, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(
            get: { draft.rule[keyPath: keyPath] ?? defaultValue },
            set: { draft.rule[keyPath: keyPath] = $0 == defaultValue ? nil : $0 })
    }

    @ViewBuilder
    private var aiDraftButton: some View {
        let reason = assistant.availability.unavailableReason
        Button {
            draftingMessage = true
        } label: {
            Label("Draft…", systemImage: "apple.intelligence")
        }
        .disabled(reason != nil)
        .help(reason ?? "Draft the message with on-device Apple Intelligence (you review it before it's used)")
    }

    // MARK: Pieces

    @ViewBuilder
    private func issueRows(for key: RuleField) -> some View {
        ForEach(issues.filter { $0.field == key }) { IssueLabel(issue: $0) }
    }

    private var cooldownBinding: Binding<String> {
        Binding(
            get: { draft.rule.cooldownSeconds.map(String.init) ?? "" },
            set: { text in
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                draft.rule.cooldownSeconds = Int(trimmed)  // non-numeric input leaves the key absent
            })
    }

    private var cooldownStepper: Binding<Int> {
        Binding(
            get: { draft.rule.cooldownSeconds ?? RuleModel.defaultCooldownSeconds },
            set: { draft.rule.cooldownSeconds = $0 })
    }

    private var modeExplanation: String {
        switch draft.mode {
        case .presence:
            "No predicate. The watcher polls every 0.5 s, so it is simple, but it can't catch a command that exits faster than the poll (e.g. one-shot CLI commands)."
        case .event:
            "Driven by a unified-log line, about 0.25 s measured and no polling. Needs a log line that appears only when the user does the thing you want to block."
        case .watchOneKillAnother:
            "Polls the watched process but quits the other one, e.g. watch InternetAccountsSettingsExtension and quit System Settings. Quit the host app: quitting only an extension makes Settings show “Extension process exited”."
        case .notifyOnly:
            "Driven by a unified-log line like an event rule, but nothing is quit: the watcher only shows the dialog. Use it to explain something that is already enforced elsewhere (e.g. a DDM policy that blocks external storage)."
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
    @State private var live = LiveDialogController()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                if tab != .dialog {
                    Button("Copy", systemImage: "doc.on.doc") {
                        FileDialogs.copyToClipboard(store.text(for: draft.rule, format: format))
                    }
                    .labelStyle(.iconOnly)
                    .help("Copy the XML to the clipboard")
                }
            }
            switch tab {
            case .dialog:
                dialogPreview
            case .plist, .mobileconfig:
                filePreview
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.primary.opacity(0.03))
        // The live swiftDialog window follows edits and closes when the rule or editor goes away.
        .onChange(of: draft.rule) { live.update(rule: draft.rule, settings: store.settings) }
        .onChange(of: store.settings) { live.update(rule: draft.rule, settings: store.settings) }
        .onDisappear { live.stop() }
    }

    private var format: ExportFormat { tab == .mobileconfig ? .mobileconfig : .plist }

    @ViewBuilder
    private var dialogPreview: some View {
        HStack {
            if live.isRunning {
                Button("Close Dialog", systemImage: "stop.circle") { live.stop() }
                    .tint(.green)
                    .help("Close the swiftDialog window")
                Label("Following edits", systemImage: "circle.fill")
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
                    .font(.system(size: 11))
                    .foregroundStyle(.green)
            } else {
                Button("Simulate Dialog", systemImage: "macwindow") {
                    live.start(rule: draft.rule, settings: store.settings)
                }
                .disabled(!live.dialogInstalled)
                .help(live.dialogInstalled
                      ? "Open the real swiftDialog window with the watcher's flags. It follows your edits until you close it."
                      : "swiftDialog isn't installed at \(DialogCommand.dialogPath)")
            }
            Spacer()
            Button("Copy Command", systemImage: "terminal") {
                FileDialogs.copyToClipboard(DialogCommand.shellCommand(for: draft.rule, settings: store.settings))
            }
            .help("Copy the swiftDialog command the watcher would run")
        }
        if let status = live.status, !live.isRunning {
            Label(status, systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        // A wallpaper-like backdrop so the mock reads as a window on a desktop.
        DialogPreviewView(rule: draft.rule, settings: store.settings)
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(
                LinearGradient(colors: [.blue.opacity(0.35), .indigo.opacity(0.4), .purple.opacity(0.3)],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 10))
        Text("This preview follows your edits and is approximate. Simulate Dialog opens the real swiftDialog window.")
            .font(.system(size: 11)).foregroundStyle(.secondary)
        Spacer(minLength: 0)
    }

    @ViewBuilder
    private var filePreview: some View {
        let blocking = store.issues(for: draft).filter(\.isError)
        Label(store.fileName(for: draft.rule, format: format), systemImage: "doc.text")
            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            .textSelection(.enabled)
        if !blocking.isEmpty {
            Label("\(blocking.count) error\(blocking.count == 1 ? "" : "s") to fix before exporting.", systemImage: "xmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        } else if format == .mobileconfig {
            Text("Jamf profile name: \(store.settings.profileName(for: draft.rule.name))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        ScrollView([.vertical, .horizontal]) {
            Text(store.text(for: draft.rule, format: format))
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}
