import Foundation

struct RuleImportResult: Sendable {
    /// Best-effort model (nil only if the file isn't a dictionary plist at all).
    var rule: RuleModel?
    /// Import problems (wrong types, unknown keys) followed by `RuleModel.validate()` issues.
    var issues: [ValidationIssue]

    var isValid: Bool { rule != nil && !issues.contains(where: \.isError) }
}

/// Reads an existing rule plist (XML or binary) into a `RuleModel`, reporting wrong types explicitly
/// because a typed model can't represent them.
enum RuleImporter {
    static let knownKeys: Set<String> = [
        "KillProcess", "DialogMessage", "Predicate", "WatchProcess",
        "CooldownSeconds", "ButtonText", "ButtonAction", "DismissButtonText",
    ]

    static func importRule(data: Data, name: String) -> RuleImportResult {
        guard let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any]
        else {
            return RuleImportResult(rule: nil, issues: [
                ValidationIssue(field: .file, severity: .error, code: .plistUnreadable,
                                message: "This file isn't a readable property list with a dictionary at the top level.")
            ])
        }

        var issues: [ValidationIssue] = []

        func string(_ key: String, field: RuleField) -> String? {
            guard let raw = dict[key] else { return nil }
            if let s = raw as? String { return s }
            issues.append(ValidationIssue(field: field, severity: .error, code: .wrongType,
                                          message: "\(key) must be a string."))
            return nil
        }

        var cooldown: Int?
        if let raw = dict["CooldownSeconds"] {
            // NSNumber bridges booleans and reals too; only a true integer is acceptable.
            if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
               !CFNumberIsFloatType(n), let i = Int(exactly: n.int64Value) {
                cooldown = i
            } else {
                issues.append(ValidationIssue(field: .cooldownSeconds, severity: .error, code: .wrongType,
                                              message: "CooldownSeconds must be an integer."))
            }
        }

        let rule = RuleModel(
            name: name,
            killProcess: string("KillProcess", field: .killProcess) ?? "",
            dialogMessage: string("DialogMessage", field: .dialogMessage) ?? "",
            predicate: string("Predicate", field: .predicate),
            watchProcess: string("WatchProcess", field: .watchProcess),
            cooldownSeconds: cooldown,
            buttonText: string("ButtonText", field: .buttonText),
            buttonAction: string("ButtonAction", field: .buttonAction),
            dismissButtonText: string("DismissButtonText", field: .dismissButtonText)
        )

        for key in dict.keys.sorted() where !knownKeys.contains(key) {
            issues.append(ValidationIssue(field: .file, severity: .warning, code: .unknownKey,
                                          message: "Unknown key “\(key)” — the watcher ignores it, and re-saving drops it."))
        }

        // A wrongly typed key was already reported; don't also report it as "required/empty".
        let reportedFields = Set(issues.map(\.field))
        issues += rule.validate().filter { !(reportedFields.contains($0.field) && $0.code == .emptyString) }
        return RuleImportResult(rule: rule, issues: issues)
    }
}
