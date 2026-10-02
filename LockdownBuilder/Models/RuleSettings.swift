import Foundation

/// App-level settings that shape every rule's preference domain and generated text.
struct RuleSettings: Equatable, Codable, Sendable {
    /// e.g. `com.company`
    var orgPlistDomain = "com.company"
    /// e.g. `restrict`
    var preference = "restrict"
    /// Used in generated message text, e.g. "Company Name".
    var orgNameFriendly = "Company Name"
    /// Where open/save/export panels start. Empty means "no preference".
    var defaultOutputFolder = ""
    /// Banner image the watcher uses, for "Simulate dialog" and the dialog preview. Empty means no banner.
    var bannerImagePath = ""
    /// Icon the watcher's dialog shows (`--icon`). Empty means swiftDialog's default icon.
    var iconPath = ""
    /// Banner height and icon size in points (`--bannerheight`, `--iconsize`). Nil means swiftDialog's default.
    var bannerHeight: Int?
    var iconSize: Int?
    /// Jamf Pro server, e.g. `https://company.jamfcloud.com`. The client secret lives in the Keychain, not here.
    var jamfURL = ""
    /// Jamf Pro API client ID (not a secret on its own).
    var jamfClientID = ""
    /// Configuration profile names chosen when publishing, by rule name, so a republish updates the same profile.
    var profileNames: [String: String] = [:]
    /// Optional Apple Intelligence features (draft message, suggest predicate). Nothing depends on them.
    var aiEnabled = true

    init() {}

    /// Tolerates settings saved by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RuleSettings()
        orgPlistDomain = try c.decodeIfPresent(String.self, forKey: .orgPlistDomain) ?? d.orgPlistDomain
        preference = try c.decodeIfPresent(String.self, forKey: .preference) ?? d.preference
        orgNameFriendly = try c.decodeIfPresent(String.self, forKey: .orgNameFriendly) ?? d.orgNameFriendly
        defaultOutputFolder = try c.decodeIfPresent(String.self, forKey: .defaultOutputFolder) ?? d.defaultOutputFolder
        bannerImagePath = try c.decodeIfPresent(String.self, forKey: .bannerImagePath) ?? d.bannerImagePath
        iconPath = try c.decodeIfPresent(String.self, forKey: .iconPath) ?? d.iconPath
        bannerHeight = try c.decodeIfPresent(Int.self, forKey: .bannerHeight)
        iconSize = try c.decodeIfPresent(Int.self, forKey: .iconSize)
        jamfURL = try c.decodeIfPresent(String.self, forKey: .jamfURL) ?? d.jamfURL
        jamfClientID = try c.decodeIfPresent(String.self, forKey: .jamfClientID) ?? d.jamfClientID
        profileNames = try c.decodeIfPresent([String: String].self, forKey: .profileNames) ?? d.profileNames
        aiEnabled = try c.decodeIfPresent(Bool.self, forKey: .aiEnabled) ?? d.aiEnabled
    }

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

    /// Default Jamf configuration profile name: `Restrict - <rule-name>`.
    func defaultProfileName(for ruleName: String) -> String {
        "\(preference.prefix(1).uppercased() + preference.dropFirst()) - \(ruleName)"
    }

    /// The configuration profile name for a rule: the one chosen when publishing, or the default.
    func profileName(for ruleName: String) -> String {
        if let custom = profileNames[ruleName]?.trimmingCharacters(in: .whitespaces), !custom.isEmpty { return custom }
        return defaultProfileName(for: ruleName)
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
            out.append("Company name must not be empty.")
        }
        return out
    }
}
