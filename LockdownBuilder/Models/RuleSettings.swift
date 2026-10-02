import Foundation

/// App-level settings that shape every rule's preference domain and generated text.
struct RuleSettings: Equatable, Codable, Sendable {
    /// e.g. `com.company`
    var orgPlistDomain = "com.company"
    /// e.g. `restrict`
    var preference = "restrict"
    /// Used in generated message text, e.g. "Company Name".
    var orgNameFriendly = "Company Name"

    /// `<ORG_PLIST_DOMAIN>.<PREFERENCE>.<rule-name>`
    func ruleDomain(for ruleName: String) -> String {
        "\(orgPlistDomain).\(preference).\(ruleName)"
    }

    /// The rule file name: the preference domain plus `.plist`.
    func fileName(for ruleName: String) -> String {
        ruleDomain(for: ruleName) + ".plist"
    }

    /// The watcher LaunchDaemon label, shown for reference only.
    var watcherLabel: String { "\(orgPlistDomain).\(preference).watcher" }

    /// Suggested Jamf configuration profile name: `Restrict - <rule-name>`.
    func profileName(for ruleName: String) -> String {
        "\(preference.prefix(1).uppercased() + preference.dropFirst()) - \(ruleName)"
    }

    /// Recovers a rule name from a file name produced by `fileName(for:)`, or nil if it doesn't match.
    func ruleName(fromFileName fileName: String) -> String? {
        let prefix = "\(orgPlistDomain).\(preference)."
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(".plist") else { return nil }
        let name = fileName.dropFirst(prefix.count).dropLast(".plist".count)
        return name.isEmpty ? nil : String(name)
    }

    /// Problems with the settings themselves (they feed every file name, so they matter).
    var issues: [String] {
        var out: [String] = []
        let domainShape = /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+/
        if orgPlistDomain.wholeMatch(of: domainShape) == nil {
            out.append("ORG_PLIST_DOMAIN must be a reverse-DNS style domain such as com.company.")
        }
        if preference.wholeMatch(of: /[a-z0-9]+(-[a-z0-9]+)*/) == nil {
            out.append("PREFERENCE must be lowercase letters, digits and hyphens (default: restrict).")
        }
        if orgNameFriendly.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("ORG_NAME_FRIENDLY must not be empty.")
        }
        return out
    }
}
