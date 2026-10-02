import Foundation

/// Builds the Jamf installer script for the Restricted Item Watcher from the template bundled with the app,
/// with this deployment's Settings written into the installer's own variables. The installer embeds the
/// watcher, so the app and the watcher it deploys always understand the same rule keys.
enum WatcherInstaller {
    static let fileName = "Restricted-Item-Watcher-Installer.sh"
    static let defaultScriptName = "Restricted-Item-Watcher-Installer"
    /// The generated script is the app's output, so both script headers name the app, not a person.
    static let author = "LockdownBuilder"
    private static let authorPrefix = "# Author:"
    /// Everything after this line is the embedded watcher; only its author line is changed.
    private static let watcherMarker = "<<'WATCHER_SCRIPT_EOF'"

    enum BuildError: LocalizedError, Equatable {
        case templateMissing
        case templateChanged(String)
        case invalidSettings([String])

        var errorDescription: String? {
            switch self {
            case .templateMissing: "The installer template is missing from the app bundle."
            case .templateChanged(let name): "The installer template has no single \(name) line to fill in."
            case .invalidSettings(let issues): issues.joined(separator: "\n")
            }
        }
    }

    static func bundledTemplate() throws -> String {
        guard let url = Bundle.main.url(forResource: "Restricted-Item-Watcher-Installer", withExtension: "sh"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { throw BuildError.templateMissing }
        return text
    }

    /// The installer's own version, e.g. "1.7".
    static func version(of template: String) -> String? {
        template.firstMatch(of: /readonly SCRIPT_VERSION="([0-9.]+)"/).map { String($0.1) }
    }

    /// The values written into the installer, in the order they appear in it.
    static func values(for settings: RuleSettings) -> [(name: String, value: String)] {
        [
            ("ORG_NAME_FRIENDLY", settings.orgNameFriendly.trimmingCharacters(in: .whitespaces)),
            ("ORG_PLIST_DOMAIN", settings.orgPlistDomain),
            ("PREFERENCE", settings.preference),
            ("BANNER_IMAGE", settings.bannerImagePath),
            ("BANNER_HEIGHT", settings.bannerHeight.map(String.init) ?? ""),
            ("DIALOG_ICON", settings.iconPath),
            ("DIALOG_ICON_SIZE", settings.iconSize.map(String.init) ?? ""),
        ]
    }

    /// Problems that would make the generated installer wrong or refuse to run.
    static func issues(for settings: RuleSettings) -> [String] {
        var out = settings.issues
        // The values land inside double quotes in a shell script, so nothing that the shell would expand.
        let unsafe = CharacterSet(charactersIn: "\"$`\\").union(.controlCharacters).union(.newlines)
        for (name, value) in values(for: settings) where value.unicodeScalars.contains(where: unsafe.contains) {
            out.append("\(label(name)) can't contain quotes, $, backticks, backslashes or line breaks.")
        }
        if settings.orgNameFriendly.contains("/") {
            out.append("Company name can't contain “/” (it becomes a folder name on managed Macs).")
        }
        // The installer itself refuses to run with its sample values.
        if settings.orgPlistDomain == "com.company" {
            out.append("Set your organization domain in Settings → General. The installer refuses to run with the sample “com.company”.")
        }
        if settings.orgNameFriendly.trimmingCharacters(in: .whitespaces) == "Company Name" {
            out.append("Set your company name in Settings → General. The installer refuses to run with the sample “Company Name”.")
        }
        return out
    }

    private static func label(_ name: String) -> String {
        switch name {
        case "ORG_NAME_FRIENDLY": "Company name"
        case "ORG_PLIST_DOMAIN": "Organization domain"
        case "PREFERENCE": "Preference"
        case "BANNER_IMAGE": "Banner image path"
        case "DIALOG_ICON": "Icon path"
        default: name
        }
    }

    static func build(template: String, settings: RuleSettings) throws -> String {
        let problems = issues(for: settings)
        guard problems.isEmpty else { throw BuildError.invalidSettings(problems) }
        guard let marker = template.range(of: watcherMarker) else { throw BuildError.templateChanged("watcher heredoc") }

        var head = template[..<marker.lowerBound].components(separatedBy: "\n")
        for (name, value) in values(for: settings) {
            let prefix = "readonly \(name)=\""
            let matches = head.indices.filter { head[$0].hasPrefix(prefix) }
            guard matches.count == 1 else { throw BuildError.templateChanged(name) }
            head[matches[0]] = "\(prefix)\(value)\""
        }
        let script = head.joined(separator: "\n") + template[marker.lowerBound...]
        let lines = script.components(separatedBy: "\n")
        // One header for the installer, one for the watcher it embeds.
        guard lines.filter({ $0.hasPrefix(authorPrefix) }).count == 2 else { throw BuildError.templateChanged("Author") }
        return lines.map { $0.hasPrefix(authorPrefix) ? "\(authorPrefix) \(author)" : $0 }.joined(separator: "\n")
    }
}
