import Foundation

/// `{{name}}` placeholders in `DialogMessage`. The plist keeps the token; the watcher (1.10 or later) fills it
/// in when it shows the dialog, so the app expands them the same way for the preview and Simulate Dialog.
/// Keep in step with `expand_message_variables` in the watcher script.
enum MessageVariable: String, CaseIterable, Identifiable, Sendable {
    /// The company name the watcher was installed with (`ORG_NAME_FRIENDLY`).
    case companyName
    /// The rule's kebab-case name.
    case ruleName
    /// The rule's `KillProcess`; empty for a notify-only rule.
    case killProcess

    var id: String { rawValue }
    var token: String { "{{\(rawValue)}}" }

    var summary: String {
        switch self {
        case .companyName: "Company name from Settings"
        case .ruleName: "Rule name"
        case .killProcess: "Process to quit"
        }
    }

    func value(rule: RuleModel, settings: RuleSettings) -> String {
        switch self {
        case .companyName: settings.orgNameFriendly
        case .ruleName: rule.name
        case .killProcess: rule.killProcess ?? ""
        }
    }
}

enum MessageVariables {
    /// The text with every known variable replaced, exactly as the watcher does it; unknown tokens stay as typed.
    static func expand(_ text: String, rule: RuleModel, settings: RuleSettings) -> String {
        var out = text
        for variable in MessageVariable.allCases where out.contains(variable.token) {
            out = out.replacingOccurrences(of: variable.token, with: variable.value(rule: rule, settings: settings))
        }
        return out
    }

    /// Names inside `{{…}}` that aren't a `MessageVariable`.
    static func unknownNames(in text: String) -> [String] {
        var seen: Set<String> = []
        // Inline literal: `Regex` isn't Sendable, so it can't be a cached static under Swift 6.
        // swiftDialog's own `{computername}` style (single braces) doesn't match.
        return text.matches(of: /\{\{([A-Za-z]+)\}\}/).compactMap { match in
            let name = String(match.1)
            guard MessageVariable(rawValue: name) == nil, seen.insert(name).inserted else { return nil }
            return name
        }
    }

    static func usesVariables(_ text: String) -> Bool {
        MessageVariable.allCases.contains { text.contains($0.token) }
    }
}
