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
        "DialogWidth", "DialogHeight", "DialogPosition", "DialogOnTop", "DialogMoveable", "DialogBlurScreen",
        "DialogShowBanner", "DialogShowIcon", "DialogMessageAlignment", "DialogMessagePosition",
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

        func integer(_ key: String, field: RuleField) -> Int? {
            guard let raw = dict[key] else { return nil }
            // NSNumber bridges booleans and reals too; only a true integer is acceptable.
            if let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
               !CFNumberIsFloatType(n), let i = Int(exactly: n.int64Value) {
                return i
            }
            issues.append(ValidationIssue(field: field, severity: .error, code: .wrongType,
                                          message: "\(key) must be an integer."))
            return nil
        }

        func bool(_ key: String, field: RuleField) -> Bool? {
            guard let raw = dict[key] else { return nil }
            if let n = raw as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
            issues.append(ValidationIssue(field: field, severity: .error, code: .wrongType,
                                          message: "\(key) must be true or false."))
            return nil
        }

        var position: RuleModel.DialogPosition?
        if let raw = string("DialogPosition", field: .dialogPosition) {
            position = RuleModel.DialogPosition(rawValue: raw)
            if position == nil {
                issues.append(ValidationIssue(
                    field: .dialogPosition, severity: .error, code: .dialogPositionUnknown,
                    message: "DialogPosition “\(raw)” isn't one of \(RuleModel.DialogPosition.allCases.map(\.rawValue).joined(separator: ", "))."))
            }
        }

        func choice<T: RawRepresentable & CaseIterable>(_ key: String, field: RuleField, _ type: T.Type) -> T?
        where T.RawValue == String {
            guard let raw = string(key, field: field) else { return nil }
            if let value = T(rawValue: raw) { return value }
            issues.append(ValidationIssue(
                field: field, severity: .error, code: .dialogChoiceUnknown,
                message: "\(key) “\(raw)” isn't one of \(T.allCases.map(\.rawValue).joined(separator: ", "))."))
            return nil
        }

        let rule = RuleModel(
            name: name,
            killProcess: string("KillProcess", field: .killProcess) ?? "",
            dialogMessage: string("DialogMessage", field: .dialogMessage) ?? "",
            predicate: string("Predicate", field: .predicate),
            watchProcess: string("WatchProcess", field: .watchProcess),
            cooldownSeconds: integer("CooldownSeconds", field: .cooldownSeconds),
            buttonText: string("ButtonText", field: .buttonText),
            buttonAction: string("ButtonAction", field: .buttonAction),
            dismissButtonText: string("DismissButtonText", field: .dismissButtonText),
            dialogWidth: integer("DialogWidth", field: .dialogWidth),
            dialogHeight: integer("DialogHeight", field: .dialogHeight),
            dialogPosition: position,
            dialogOnTop: bool("DialogOnTop", field: .dialogOnTop),
            dialogMoveable: bool("DialogMoveable", field: .dialogMoveable),
            dialogBlurScreen: bool("DialogBlurScreen", field: .dialogBlurScreen),
            dialogShowBanner: bool("DialogShowBanner", field: .dialogShowBanner),
            dialogShowIcon: bool("DialogShowIcon", field: .dialogShowIcon),
            dialogMessageAlignment: choice("DialogMessageAlignment", field: .dialogMessageAlignment, RuleModel.MessageAlignment.self),
            dialogMessagePosition: choice("DialogMessagePosition", field: .dialogMessagePosition, RuleModel.MessagePosition.self)
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
