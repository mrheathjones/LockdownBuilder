import Foundation

/// The rule keys (plus the rule's file-level name) that a validation issue can point at.
enum RuleField: String, Sendable, CaseIterable {
    case name = "Name"
    case killProcess = "KillProcess"
    case dialogMessage = "DialogMessage"
    case predicate = "Predicate"
    case watchProcess = "WatchProcess"
    case cooldownSeconds = "CooldownSeconds"
    case buttonText = "ButtonText"
    case buttonAction = "ButtonAction"
    case dismissButtonText = "DismissButtonText"
    case dialogWidth = "DialogWidth"
    case dialogHeight = "DialogHeight"
    case dialogPosition = "DialogPosition"
    case dialogOnTop = "DialogOnTop"
    case dialogMoveable = "DialogMoveable"
    case dialogBlurScreen = "DialogBlurScreen"
    case dialogShowBanner = "DialogShowBanner"
    case dialogShowIcon = "DialogShowIcon"
    case dialogMessageAlignment = "DialogMessageAlignment"
    case dialogMessagePosition = "DialogMessagePosition"
    case file = "File"
}

enum ValidationSeverity: Sendable {
    case error
    case warning
}

/// Stable identifiers so tests (and the UI) can match on the kind of problem, not on message text.
enum ValidationCode: String, Sendable {
    // Name
    case nameEmpty, nameNotKebabCase, nameReserved, nameCollision
    // Required keys / wrong values
    case emptyString, wrongType, unknownKey
    case killProcessDenylisted, processNameUnmatchable
    case predicateWithWatchProcess, watchProcessSameAsKill
    case cooldownNegative
    case dialogSizeTooSmall, dialogPositionUnknown, dialogChoiceUnknown
    case buttonActionInvalid, buttonActionFileScheme, buttonActionControlCharacters
    case messageIllegalCharacters
    case plistUnreadable
}

struct ValidationIssue: Equatable, Hashable, Sendable, Identifiable {
    let field: RuleField
    let severity: ValidationSeverity
    let code: ValidationCode
    let message: String

    var id: String { "\(field.rawValue)/\(code.rawValue)" }
    var isError: Bool { severity == .error }
}
