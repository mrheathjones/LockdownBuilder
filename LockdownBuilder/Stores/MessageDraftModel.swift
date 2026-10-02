import Foundation
import Observation

/// "Draft message" with Apple Intelligence. The draft is shown for review and editing and only replaces the
/// rule's DialogMessage when the user chooses to.
@MainActor
@Observable
final class MessageDraftModel {
    var intent: String
    var tone: MessageTone = .professional
    /// Editable Markdown draft.
    var draft = ""
    private(set) var isGenerating = false
    private(set) var error: String?
    private var task: Task<Void, Never>?

    init(intent: String = "") {
        self.intent = intent
    }

    var canGenerate: Bool { !intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating }

    func generate(using assistant: any RuleAssistant, appName: String, org: String) {
        task?.cancel()
        isGenerating = true
        error = nil
        let intent = intent, tone = tone
        task = Task {
            do {
                let message = try await assistant.draftMessage(intent: intent, tone: tone, appName: appName, org: org)
                if !Task.isCancelled { draft = message.markdown }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
            isGenerating = false
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        isGenerating = false
    }

    /// The draft is usable only if it would make a valid DialogMessage.
    var draftIsValid: Bool {
        let probe = RuleModel(name: "probe", killProcess: "probe", dialogMessage: draft)
        return !probe.validate().contains { $0.field == .dialogMessage && $0.isError }
    }
}
