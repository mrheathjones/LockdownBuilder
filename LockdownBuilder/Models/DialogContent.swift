import Foundation

/// The swiftDialog invocation the watcher makes, reproduced flag for flag (and in the watcher's order) so
/// "Simulate Dialog" shows what users will see. Keep in step with `show_rule_dialog` in the watcher script.
enum DialogCommand {
    static let dialogPath = "/usr/local/bin/dialog"

    /// The watcher's window height when a rule sets none (its `appSizeSmall`).
    static let defaultHeight = 500
    /// swiftDialog's own width, used when a rule sets none.
    static let defaultWidth = 820
    /// The watcher's icon when Settings has none.
    static let defaultIcon = "SF=exclamationmark.shield.fill,colour=red"

    /// The banner is shown when Settings has one and the rule hasn't turned it off.
    static func showsBanner(_ rule: RuleModel, settings: RuleSettings) -> Bool {
        !settings.bannerImagePath.isEmpty && (rule.dialogShowBanner ?? true)
    }

    static func arguments(for rule: RuleModel, settings: RuleSettings) -> [String] {
        var args = [
            "--height", String(rule.dialogHeight ?? defaultHeight),
            "--message", rule.dialogMessage,
            "--button1text", rule.buttonText ?? "OK",
        ]
        if let width = rule.dialogWidth { args += ["--width", String(width)] }
        if let position = rule.dialogPosition { args += ["--position", position.rawValue] }
        if let alignment = rule.dialogMessageAlignment { args += ["--messagealignment", alignment.rawValue] }
        if let position = rule.dialogMessagePosition { args += ["--messageposition", position.rawValue] }
        if rule.dialogShowIcon == false {
            args += ["--icon", "none"]
        } else {
            args += ["--icon", settings.iconPath.isEmpty ? defaultIcon : settings.iconPath]
            if let size = settings.iconSize { args += ["--iconsize", String(size)] }
        }
        if rule.dialogOnTop ?? true { args.append("--ontop") }
        if rule.dialogMoveable ?? true { args.append("--moveable") }
        if rule.dialogBlurScreen ?? false { args.append("--blurscreen") }
        if let dismiss = rule.dismissButtonText { args += ["--button2text", dismiss] }
        if showsBanner(rule, settings: settings) {
            args += ["--bannerimage", settings.bannerImagePath, "--title", "none"]
            if let height = settings.bannerHeight { args += ["--bannerheight", String(height)] }
        } else {
            args += ["--title", settings.orgNameFriendly]
        }
        return args
    }

    /// A copy-pasteable shell rendering of the command (single-quoted, real newlines kept).
    static func shellCommand(for rule: RuleModel, settings: RuleSettings) -> String {
        ([dialogPath] + arguments(for: rule, settings: settings)).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// What a swiftDialog exit code means for this rule.
    static func describeExit(_ status: Int32, rule: RuleModel) -> String {
        switch status {
        case 0:
            if let action = rule.buttonAction {
                "“\(rule.buttonText ?? "OK")” pressed. The watcher would now open \(action)."
            } else {
                "“\(rule.buttonText ?? "OK")” pressed. The dialog just closes."
            }
        case 2: "“\(rule.dismissButtonText ?? "Button 2")” pressed. The dialog just closes."
        case 10: "Dialog quit with ⌘Q."
        case 15: "Dialog was closed (terminated)."
        default: "Dialog exited with code \(status)."
        }
    }
}

/// A deliberately small subset of swiftDialog's Markdown, enough for a faithful preview.
enum DialogMarkdown {
    enum Block: Equatable {
        case heading(String)
        case paragraph(String)
        case bullet(String)
    }

    struct Document: Equatable {
        /// From a leading `# Title` line; swiftDialog renders it large and bold.
        var title: String?
        var blocks: [Block]
    }

    static func parse(_ message: String) -> Document {
        var lines = message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var title: String?
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].hasPrefix("# ") {
            title = String(lines[first].dropFirst(2)).trimmingCharacters(in: .whitespaces)
            lines.removeSubrange(...first)
        }
        var blocks: [Block] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flush()
            } else if let range = line.range(of: #"^#{1,6} "#, options: .regularExpression) {
                flush()
                blocks.append(.heading(String(line[range.upperBound...])))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush()
                blocks.append(.bullet(String(line.dropFirst(2))))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return Document(title: title, blocks: blocks)
    }
}

/// Starting points for DialogMessage. Always editable; applying one replaces the message.
enum DialogPreset: String, CaseIterable, Identifiable {
    case appBlocked = "App blocked"
    case featureBlocked = "Feature blocked"
    case policyNotice = "Policy notice"

    var id: String { rawValue }

    func message(appName: String, org: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespaces).isEmpty ? "This app" : appName
        switch self {
        case .appBlocked:
            return "# \(app) Blocked\n\n\(app) isn't available on this Mac.\n\nThis is a policy of \(org). If you believe you need access, please contact the Service Desk."
        case .featureBlocked:
            return "# Feature Unavailable\n\nThis feature of \(app) has been turned off on this Mac by \(org).\n\nIf you need it for your work, please contact the Service Desk."
        case .policyNotice:
            return "# Policy Notice\n\nThis action isn't permitted under the acceptable use policy of \(org).\n\nIf you have questions, please contact the Service Desk."
        }
    }
}

/// Plain-language description of what the watcher will do with a rule. Never runs anything.
enum DryRun {
    static func steps(for rule: RuleModel, settings: RuleSettings) -> [String] {
        var steps: [String] = []
        let cooldown = rule.cooldownSeconds ?? RuleModel.defaultCooldownSeconds
        switch rule.kind {
        case .event:
            steps.append("Streams the unified log with the predicate:\n\(rule.predicate ?? "")")
            steps.append("Each matching log line (about 0.25 s after the event) triggers the rule. No polling.")
        case .presence:
            steps.append("Polls every 0.5 s for a process named exactly “\(rule.killProcess)” (pgrep -x).")
            steps.append("Caveat: a process that starts and exits within one poll interval can be missed.")
        case .watchOneKillAnother:
            steps.append("Polls every 0.5 s for a process named exactly “\(rule.watchProcess ?? "")” (pgrep -x).")
        }
        steps.append("Kills every process named exactly “\(rule.killProcess)” (pkill -x). The kill happens every time.")
        steps.append("Shows the dialog, at most once every \(cooldown) s (CooldownSeconds rate-limits the dialog only).")
        var buttons = "Primary button “\(rule.buttonText ?? "OK")”"
        buttons += rule.buttonAction.map { " opens \($0)" } ?? " closes the dialog"
        if let dismiss = rule.dismissButtonText { buttons += "; secondary button “\(dismiss)” only closes the dialog" }
        steps.append(buttons + ".")
        steps.append("Preference domain \(settings.ruleDomain(for: rule.name)), read from /Library/Managed Preferences/\(settings.fileName(for: rule.name)).")
        return steps
    }
}

/// Minimal LCS line diff for comparing a rule with its last export.
enum LineDiff {
    enum Line: Equatable {
        case same(String)
        case removed(String)
        case added(String)
    }

    static func diff(old: String, new: String) -> [Line] {
        let a = old.components(separatedBy: "\n"), b = new.components(separatedBy: "\n")
        let n = a.count, m = b.count
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(.same(a[i])); i += 1; j += 1
            } else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append(.removed(a[i])); i += 1
            } else {
                out.append(.added(b[j])); j += 1
            }
        }
        return out
    }

    static func hasChanges(_ lines: [Line]) -> Bool {
        lines.contains { if case .same = $0 { false } else { true } }
    }
}

/// Live preview support: swiftDialog re-reads `--commandfile` and applies `message:`, `title:`,
/// `button1text:` and `button2text:` to the open window. Anything else (adding/removing the second button,
/// switching the banner) needs a relaunch.
enum DialogLiveUpdate {
    /// Command-file lines are newline-delimited, so real newlines in a value are sent as `\n`, which
    /// swiftDialog turns back into line breaks.
    static func encode(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\\n")
    }

    static func needsRelaunch(from old: RuleModel, to new: RuleModel, oldSettings: RuleSettings, newSettings: RuleSettings) -> Bool {
        (old.dismissButtonText == nil) != (new.dismissButtonText == nil)
            || windowOptions(old) != windowOptions(new)
            || oldSettings.bannerImagePath != newSettings.bannerImagePath
            || oldSettings.iconPath != newSettings.iconPath
            || oldSettings.bannerHeight != newSettings.bannerHeight
            || oldSettings.iconSize != newSettings.iconSize
    }

    /// The launch-time window flags; swiftDialog can't change them on an open window.
    private static func windowOptions(_ rule: RuleModel) -> [String] {
        // Width and height are not here: the open window resizes through the command file.
        [rule.dialogPosition?.rawValue, rule.dialogOnTop.map(String.init), rule.dialogMoveable.map(String.init),
         rule.dialogBlurScreen.map(String.init), rule.dialogShowBanner.map(String.init), rule.dialogShowIcon.map(String.init),
         rule.dialogMessageAlignment?.rawValue, rule.dialogMessagePosition?.rawValue]
            .map { $0 ?? "-" }
    }

    /// Command lines that bring a dialog showing `old` up to date with `new` (empty if nothing visible changed).
    static func commands(from old: RuleModel, to new: RuleModel, oldSettings: RuleSettings, newSettings: RuleSettings) -> [String] {
        var lines: [String] = []
        if !DialogCommand.showsBanner(new, settings: newSettings), oldSettings.orgNameFriendly != newSettings.orgNameFriendly {
            lines.append("title: \(encode(newSettings.orgNameFriendly))")
        }
        if old.dialogMessage != new.dialogMessage {
            lines.append("message: \(encode(new.dialogMessage))")
        }
        if (old.buttonText ?? "OK") != (new.buttonText ?? "OK") {
            lines.append("button1text: \(encode(new.buttonText ?? "OK"))")
        }
        if let text = new.dismissButtonText, text != old.dismissButtonText {
            lines.append("button2text: \(encode(text))")
        }
        if old.dialogWidth != new.dialogWidth {
            lines.append("width: \(new.dialogWidth ?? DialogCommand.defaultWidth)")
        }
        if old.dialogHeight != new.dialogHeight {
            lines.append("height: \(new.dialogHeight ?? DialogCommand.defaultHeight)")
        }
        return lines
    }
}
