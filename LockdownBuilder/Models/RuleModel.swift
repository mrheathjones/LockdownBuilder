import Foundation

/// One Restricted Item Watcher rule. `validate()` is the single source of truth for what is a valid rule;
/// the UI, the exporters and the importer all go through it.
///
/// Optional keys are `nil` when absent. A present-but-empty string is *invalid* (the watcher treats
/// wrong types and empty strings as errors), so the editor maps an empty field to `nil`.
struct RuleModel: Equatable, Hashable, Sendable {
    /// Lowercase kebab-case; becomes the last component of the preference domain / file name.
    var name: String
    var killProcess: String
    var dialogMessage: String
    var predicate: String?
    var watchProcess: String?
    var cooldownSeconds: Int?
    var buttonText: String?
    var buttonAction: String?
    var dismissButtonText: String?
    /// Dialog window options. Absent means the watcher's default: swiftDialog's own size, centred,
    /// on top, moveable, no blur.
    var dialogWidth: Int?
    var dialogHeight: Int?
    var dialogPosition: DialogPosition?
    var dialogOnTop: Bool?
    var dialogMoveable: Bool?
    var dialogBlurScreen: Bool?
    /// Whether this rule's dialog shows the banner and icon set in Settings. Absent means shown.
    var dialogShowBanner: Bool?
    var dialogShowIcon: Bool?
    /// Where the message text sits in the dialog. Absent means left-aligned at the top.
    var dialogMessageAlignment: MessageAlignment?
    var dialogMessagePosition: MessagePosition?

    /// swiftDialog's `--messagealignment` values.
    enum MessageAlignment: String, CaseIterable, Sendable { case left, center, right }
    /// swiftDialog's `--messageposition` values.
    enum MessagePosition: String, CaseIterable, Sendable { case top, center, bottom }

    /// swiftDialog's `--position` values.
    enum DialogPosition: String, CaseIterable, Sendable {
        case topLeft = "topleft", top, topRight = "topright"
        case left, center, right
        case bottomLeft = "bottomleft", bottom, bottomRight = "bottomright"
    }

    init(
        name: String,
        killProcess: String,
        dialogMessage: String,
        predicate: String? = nil,
        watchProcess: String? = nil,
        cooldownSeconds: Int? = nil,
        buttonText: String? = nil,
        buttonAction: String? = nil,
        dismissButtonText: String? = nil,
        dialogWidth: Int? = nil,
        dialogHeight: Int? = nil,
        dialogPosition: DialogPosition? = nil,
        dialogOnTop: Bool? = nil,
        dialogMoveable: Bool? = nil,
        dialogBlurScreen: Bool? = nil,
        dialogShowBanner: Bool? = nil,
        dialogShowIcon: Bool? = nil,
        dialogMessageAlignment: MessageAlignment? = nil,
        dialogMessagePosition: MessagePosition? = nil
    ) {
        self.name = name
        self.killProcess = killProcess
        self.dialogMessage = dialogMessage
        self.predicate = predicate
        self.watchProcess = watchProcess
        self.cooldownSeconds = cooldownSeconds
        self.buttonText = buttonText
        self.buttonAction = buttonAction
        self.dismissButtonText = dismissButtonText
        self.dialogWidth = dialogWidth
        self.dialogHeight = dialogHeight
        self.dialogPosition = dialogPosition
        self.dialogOnTop = dialogOnTop
        self.dialogMoveable = dialogMoveable
        self.dialogBlurScreen = dialogBlurScreen
        self.dialogShowBanner = dialogShowBanner
        self.dialogShowIcon = dialogShowIcon
        self.dialogMessageAlignment = dialogMessageAlignment
        self.dialogMessagePosition = dialogMessagePosition
    }

    enum Kind: Sendable {
        /// No predicate: polled every 0.5 s.
        case presence
        /// Predicate present: event-driven, driven by a unified-log line.
        case event
        /// Presence rule that polls `WatchProcess` but kills `KillProcess`.
        case watchOneKillAnother
    }

    var kind: Kind {
        if predicate != nil { return .event }
        if watchProcess != nil { return .watchOneKillAnother }
        return .presence
    }

    // MARK: Constants (the contract with the watcher)

    static let reservedNames: Set<String> = ["watcher"]

    static let killDenylist: Set<String> = [
        "launchd", "kernel_task", "loginwindow", "WindowServer",
        "bash", "log", "dialog", "Restricted-Item-Watcher.sh",
    ]

    static let defaultCooldownSeconds = 5
    /// Smallest dialog size that still fits the message and buttons.
    static let minimumDialogSize = 200

    // MARK: Validation

    func validate() -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        func add(_ field: RuleField, _ severity: ValidationSeverity, _ code: ValidationCode, _ message: String) {
            issues.append(ValidationIssue(field: field, severity: severity, code: code, message: message))
        }

        // Name
        if name.isEmpty {
            add(.name, .error, .nameEmpty, "Give the rule a name.")
        } else if name.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) == nil {
            add(.name, .error, .nameNotKebabCase,
                "Use lowercase kebab-case (letters, digits, single hyphens), e.g. apple-account. Case, dots and spaces cause file collisions or look like sub-domains.")
        } else if Self.reservedNames.contains(name) {
            add(.name, .error, .nameReserved, "“\(name)” is reserved for the watcher itself.")
        }

        // KillProcess
        if killProcess.isEmpty {
            add(.killProcess, .error, .emptyString, "KillProcess is required.")
        } else {
            if Self.killDenylist.contains(killProcess) {
                add(.killProcess, .error, .killProcessDenylisted,
                    "“\(killProcess)” is on the safety denylist and can never be killed.")
            }
            Self.checkProcessName(killProcess, field: .killProcess, add: add)
        }

        // DialogMessage
        if dialogMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.dialogMessage, .error, .emptyString, "DialogMessage is required.")
        } else if Self.containsXMLIllegalCharacters(dialogMessage) {
            add(.dialogMessage, .error, .messageIllegalCharacters,
                "DialogMessage contains control characters that cannot be stored in a plist.")
        }

        // Predicate / WatchProcess
        if let predicate, predicate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            add(.predicate, .error, .emptyString, "Predicate is empty. Remove it for a presence rule, or enter a log predicate.")
        }
        if let watchProcess {
            if watchProcess.isEmpty {
                add(.watchProcess, .error, .emptyString, "WatchProcess is empty. Remove it or enter a process name.")
            } else {
                Self.checkProcessName(watchProcess, field: .watchProcess, add: add)
                if watchProcess == killProcess {
                    add(.watchProcess, .warning, .watchProcessSameAsKill,
                        "WatchProcess equals KillProcess, so it has no effect. Remove it.")
                }
            }
            if predicate != nil {
                add(.watchProcess, .error, .predicateWithWatchProcess,
                    "WatchProcess only applies to presence rules and is invalid together with Predicate.")
            }
        }

        // CooldownSeconds
        if let cooldownSeconds, cooldownSeconds < 0 {
            add(.cooldownSeconds, .error, .cooldownNegative, "CooldownSeconds must be 0 or greater.")
        }

        // Buttons
        if let buttonText, buttonText.isEmpty {
            add(.buttonText, .error, .emptyString, "ButtonText is empty. Remove it to use the default “OK”.")
        }
        if let dismissButtonText, dismissButtonText.isEmpty {
            add(.dismissButtonText, .error, .emptyString, "DismissButtonText is empty. Remove it for a single-button dialog.")
        }
        if let buttonAction {
            if buttonAction.isEmpty {
                add(.buttonAction, .error, .emptyString, "ButtonAction is empty. Remove it, or enter an absolute path or scheme://… URL.")
            } else {
                issues.append(contentsOf: Self.buttonActionIssues(buttonAction))
            }
        }

        // Dialog window
        if let dialogWidth, dialogWidth < Self.minimumDialogSize {
            add(.dialogWidth, .error, .dialogSizeTooSmall, "DialogWidth must be \(Self.minimumDialogSize) or more.")
        }
        if let dialogHeight, dialogHeight < Self.minimumDialogSize {
            add(.dialogHeight, .error, .dialogSizeTooSmall, "DialogHeight must be \(Self.minimumDialogSize) or more.")
        }

        return issues
    }

    var errors: [ValidationIssue] { validate().filter(\.isError) }
    var isValid: Bool { errors.isEmpty }

    // MARK: Helpers

    /// ButtonAction must be an absolute path (`^/…`) or a `scheme://…` URL; `file://` is refused;
    /// control characters are refused.
    static func buttonActionIssues(_ value: String) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        func add(_ code: ValidationCode, _ message: String) {
            out.append(ValidationIssue(field: .buttonAction, severity: .error, code: code, message: message))
        }
        if value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            add(.buttonActionControlCharacters, "ButtonAction must not contain control characters (including newlines and tabs).")
        }
        if value.lowercased().hasPrefix("file:") {
            add(.buttonActionFileScheme, "file:// URLs are refused. Use an absolute path such as /Applications/Self Service.app instead.")
        } else if value.hasPrefix("/") {
            // absolute path: fine
        } else if value.wholeMatch(of: /[A-Za-z][A-Za-z0-9+.\-]*:\/\/\S.*/) == nil {
            add(.buttonActionInvalid, "ButtonAction must be an absolute path (starting with /) or a scheme://… URL.")
        }
        return out
    }

    private static func checkProcessName(
        _ value: String,
        field: RuleField,
        add: (RuleField, ValidationSeverity, ValidationCode, String) -> Void
    ) {
        if value.contains("/") || value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            add(field, .error, .processNameUnmatchable,
                "\(field.rawValue) is a process name (as pgrep -x sees it), not a path, and can't contain control characters.")
        } else if value != value.trimmingCharacters(in: .whitespaces) {
            add(field, .warning, .processNameUnmatchable,
                "\(field.rawValue) has leading or trailing spaces; pgrep -x matches the full name exactly, so this will never match.")
        }
    }

    /// XML 1.0 forbids control characters other than tab, LF and CR.
    static func containsXMLIllegalCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (v < 0x20 && v != 0x09 && v != 0x0A && v != 0x0D) || v == 0x7F
        }
    }

    /// Case-insensitive file-name collisions across a project folder (APFS is case-insensitive).
    static func collisionIssues(among names: [String]) -> [String: ValidationIssue] {
        var seen: [String: Int] = [:]
        for n in names { seen[n.lowercased(), default: 0] += 1 }
        var out: [String: ValidationIssue] = [:]
        for n in names where seen[n.lowercased(), default: 0] > 1 {
            out[n] = ValidationIssue(
                field: .name, severity: .error, code: .nameCollision,
                message: "Another rule has the same name when case is ignored; APFS would treat the files as one.")
        }
        return out
    }
}
