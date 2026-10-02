import SwiftUI

struct MessageDraftView: View {
    let rule: RuleModel
    let settings: RuleSettings
    let onUse: (String) -> Void
    @State private var model: MessageDraftModel
    @Environment(\.ruleAssistant) private var assistant
    @Environment(\.dismiss) private var dismiss

    init(rule: RuleModel, settings: RuleSettings, onUse: @escaping (String) -> Void) {
        self.rule = rule
        self.settings = settings
        self.onUse = onUse
        _model = State(initialValue: MessageDraftModel(intent: rule.killProcess.map { "\($0) is blocked" } ?? ""))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Draft Message", systemImage: "apple.intelligence").font(.title2.bold())
            HStack {
                TextField("What's blocked and why, in one line", text: $model.intent)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(generate)
                Picker("Tone", selection: $model.tone) {
                    ForEach(MessageTone.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                Button(model.draft.isEmpty ? "Draft" : "Redraft", action: generate)
                    .disabled(!model.canGenerate || assistant.availability.unavailableReason != nil)
            }
            if let reason = assistant.availability.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let error = model.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Draft (editable)").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $model.draft)
                        .font(.body.monospaced())
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .overlay {
                            if model.isGenerating { ProgressView() }
                        }
                        .accessibilityLabel("Drafted message")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Preview").font(.caption).foregroundStyle(.secondary)
                    DialogPreviewView(rule: previewRule, settings: settings)
                }
            }
            HStack {
                Text("Generated on this Mac. Review it before use; it never replaces your message on its own.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Use Draft") {
                    onUse(model.draft)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.draft.isEmpty || model.isGenerating || !model.draftIsValid)
            }
        }
        .padding()
        .frame(width: 820, height: 520)
        .onDisappear { model.cancel() }
    }

    private var previewRule: RuleModel {
        var r = rule
        r.dialogMessage = model.draft.isEmpty ? rule.dialogMessage : model.draft
        return r
    }

    private func generate() {
        guard model.canGenerate else { return }
        model.generate(using: assistant, appName: rule.killProcess ?? "", org: settings.orgNameFriendly)
    }
}
