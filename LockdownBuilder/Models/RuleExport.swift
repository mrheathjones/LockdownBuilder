import CryptoKit
import Foundation

/// Pure functions that turn a `RuleModel` into the files an admin uploads. No I/O, no clock, no randomness,
/// so output is byte-stable and golden-testable.
enum RuleExport {
    // MARK: Rule plist

    /// The rule's keys as a plist dictionary. Absent optionals are omitted, never written empty.
    static func plistDictionary(for rule: RuleModel) -> [String: PlistValue] {
        var d: [String: PlistValue] = [
            "KillProcess": .string(rule.killProcess),
            "DialogMessage": .string(rule.dialogMessage),
        ]
        if let v = rule.predicate { d["Predicate"] = .string(v) }
        if let v = rule.watchProcess { d["WatchProcess"] = .string(v) }
        if let v = rule.cooldownSeconds { d["CooldownSeconds"] = .integer(v) }
        if let v = rule.buttonText { d["ButtonText"] = .string(v) }
        if let v = rule.buttonAction { d["ButtonAction"] = .string(v) }
        if let v = rule.dismissButtonText { d["DismissButtonText"] = .string(v) }
        if let v = rule.dialogWidth { d["DialogWidth"] = .integer(v) }
        if let v = rule.dialogHeight { d["DialogHeight"] = .integer(v) }
        if let v = rule.dialogPosition { d["DialogPosition"] = .string(v.rawValue) }
        if let v = rule.dialogOnTop { d["DialogOnTop"] = .bool(v) }
        if let v = rule.dialogMoveable { d["DialogMoveable"] = .bool(v) }
        if let v = rule.dialogBlurScreen { d["DialogBlurScreen"] = .bool(v) }
        if let v = rule.dialogShowBanner { d["DialogShowBanner"] = .bool(v) }
        if let v = rule.dialogShowIcon { d["DialogShowIcon"] = .bool(v) }
        if let v = rule.dialogMessageAlignment { d["DialogMessageAlignment"] = .string(v.rawValue) }
        if let v = rule.dialogMessagePosition { d["DialogMessagePosition"] = .string(v.rawValue) }
        return d
    }

    /// XML1 rule plist, identical to what `plutil -convert xml1` would emit.
    static func plist(for rule: RuleModel) -> String {
        PlistXML.serialize(.dict(plistDictionary(for: rule)))
    }

    // MARK: JSON schema (draft-04) for the Jamf "custom schema" field

    static func jsonSchema(settings: RuleSettings) -> String {
        let pathOrURL = "^(/|(?![Ff][Ii][Ll][Ee]:)[A-Za-z][A-Za-z0-9+.-]*://[^\\s]).*$"
        let schema: [String: Any] = [
            "$schema": "http://json-schema.org/draft-04/schema#",
            "title": "\(settings.orgPlistDomain).\(settings.preference).<rule-name>",
            "description": "A Restricted Item Watcher rule. One preference domain per rule; the domain is \(settings.orgPlistDomain).\(settings.preference).<rule-name> with a lowercase kebab-case rule name.",
            "type": "object",
            "required": ["KillProcess", "DialogMessage"],
            "additionalProperties": false,
            "properties": [
                "KillProcess": [
                    "title": "Process to kill",
                    "description": "Exact process name (pgrep -x / pkill -x). Full names match and may contain spaces, e.g. System Settings.",
                    "type": "string",
                    "minLength": 1,
                ] as [String: Any],
                "DialogMessage": [
                    "title": "Dialog message",
                    "description": "swiftDialog Markdown. Start with “# Title” for a large bold title. Real newlines and blank lines make paragraphs.",
                    "type": "string",
                    "minLength": 1,
                ] as [String: Any],
                "Predicate": [
                    "title": "Unified-log predicate",
                    "description": "Present: event-driven rule. Absent: presence rule, polled every 0.5 s.",
                    "type": "string",
                    "minLength": 1,
                ] as [String: Any],
                "WatchProcess": [
                    "title": "Process to watch",
                    "description": "Presence rules only: poll this process but still kill KillProcess. Invalid together with Predicate.",
                    "type": "string",
                    "minLength": 1,
                ] as [String: Any],
                "CooldownSeconds": [
                    "title": "Dialog cooldown (seconds)",
                    "description": "Dialog rate limit only; the kill happens every time.",
                    "type": "integer",
                    "minimum": 0,
                    "default": RuleModel.defaultCooldownSeconds,
                ] as [String: Any],
                "ButtonText": [
                    "title": "Primary button label",
                    "type": "string",
                    "minLength": 1,
                    "default": "OK",
                ] as [String: Any],
                "ButtonAction": [
                    "title": "Primary button action",
                    "description": "Opened when the primary button is pressed: an absolute path or a scheme://… URL. file:// is refused.",
                    "type": "string",
                    "pattern": pathOrURL,
                ] as [String: Any],
                "DismissButtonText": [
                    "title": "Dismiss button label",
                    "description": "Adds a secondary button that only closes the dialog.",
                    "type": "string",
                    "minLength": 1,
                ] as [String: Any],
                "DialogWidth": [
                    "title": "Dialog width (points)",
                    "description": "Absent: swiftDialog's default width.",
                    "type": "integer",
                    "minimum": RuleModel.minimumDialogSize,
                ] as [String: Any],
                "DialogHeight": [
                    "title": "Dialog height (points)",
                    "description": "Absent: the watcher's default height (\(DialogCommand.defaultHeight)).",
                    "type": "integer",
                    "minimum": RuleModel.minimumDialogSize,
                ] as [String: Any],
                "DialogPosition": [
                    "title": "Dialog position",
                    "description": "Where the dialog appears on screen. Absent: centred.",
                    "type": "string",
                    "enum": RuleModel.DialogPosition.allCases.map(\.rawValue),
                    "default": "center",
                ] as [String: Any],
                "DialogOnTop": [
                    "title": "Keep the dialog on top",
                    "description": "Keeps the dialog above other windows.",
                    "type": "boolean",
                    "default": true,
                ] as [String: Any],
                "DialogMoveable": [
                    "title": "Let the user move the dialog",
                    "type": "boolean",
                    "default": true,
                ] as [String: Any],
                "DialogBlurScreen": [
                    "title": "Blur the screen behind the dialog",
                    "type": "boolean",
                    "default": false,
                ] as [String: Any],
                "DialogShowBanner": [
                    "title": "Show the banner image",
                    "description": "False: no banner; the dialog title is the organisation name instead.",
                    "type": "boolean",
                    "default": true,
                ] as [String: Any],
                "DialogShowIcon": [
                    "title": "Show the icon",
                    "type": "boolean",
                    "default": true,
                ] as [String: Any],
                "DialogMessageAlignment": [
                    "title": "Message alignment",
                    "description": "Horizontal alignment of the message text. Absent: left.",
                    "type": "string",
                    "enum": RuleModel.MessageAlignment.allCases.map(\.rawValue),
                    "default": "left",
                ] as [String: Any],
                "DialogMessagePosition": [
                    "title": "Message position",
                    "description": "Vertical position of the message in the dialog. Absent: top.",
                    "type": "string",
                    "enum": RuleModel.MessagePosition.allCases.map(\.rawValue),
                    "default": "top",
                ] as [String: Any],
            ] as [String: Any],
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: schema,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: .mobileconfig

    /// One profile per rule, one payload per domain, computer-level `com.apple.ManagedClient.preferences`.
    /// UUIDs are derived from the identifiers, so re-exporting a rule yields the same profile and
    /// Jamf treats an upload as an update.
    static func mobileconfig(for rule: RuleModel, settings: RuleSettings) -> String {
        let domain = settings.ruleDomain(for: rule.name)
        let payloadIdentifier = "\(domain).payload"
        let payload: [String: PlistValue] = [
            "PayloadType": .string("com.apple.ManagedClient.preferences"),
            "PayloadVersion": .integer(1),
            "PayloadIdentifier": .string(payloadIdentifier),
            "PayloadUUID": .string(stableUUID(for: payloadIdentifier)),
            "PayloadDisplayName": .string("Managed Preferences: \(domain)"),
            "PayloadContent": .dict([
                domain: .dict([
                    "Forced": .array([
                        .dict(["mcx_preference_settings": .dict(plistDictionary(for: rule))])
                    ])
                ])
            ]),
        ]
        let profile: [String: PlistValue] = [
            "PayloadType": .string("Configuration"),
            "PayloadVersion": .integer(1),
            "PayloadScope": .string("System"),
            "PayloadIdentifier": .string(domain),
            "PayloadUUID": .string(stableUUID(for: domain)),
            "PayloadDisplayName": .string(settings.profileName(for: rule.name)),
            "PayloadOrganization": .string(settings.orgNameFriendly),
            "PayloadContent": .array([.dict(payload)]),
        ]
        return PlistXML.serialize(.dict(profile))
    }

    /// Name-based (SHA-256, version-5-style) UUID in a fixed namespace.
    static func stableUUID(for identifier: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("restricted-item-rule-builder:\(identifier)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )).uuidString
    }
}
