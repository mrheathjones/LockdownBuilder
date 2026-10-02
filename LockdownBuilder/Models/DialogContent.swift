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
            "--message", MessageVariables.expand(rule.dialogMessage, rule: rule, settings: settings),
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
        if rule.infoButtonAction != nil { args += ["--infobuttontext", rule.infoButtonText ?? RuleModel.defaultInfoButtonText] }
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
        case 3:
            if let action = rule.infoButtonAction {
                "“\(rule.infoButtonText ?? RuleModel.defaultInfoButtonText)” pressed. The watcher would now open \(action)."
            } else {
                "Info button pressed. The dialog just closes."
            }
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

/// A starting point for `DialogMessage`, managed in Settings → Dialog and offered by the editor's Presets menu.
/// Applying one replaces the rule's message; the result is always editable. Stored in `RuleSettings.dialogPresets`.
struct DialogPreset: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    /// Markdown, like `DialogMessage`. `{{appName}}` is replaced when the preset is applied; the watcher's own
    /// variables (`{{companyName}}` …) are kept so the watcher fills them in when the dialog is shown.
    var message: String

    init(id: UUID = UUID(), name: String, message: String) {
        self.id = id
        self.name = name
        self.message = message
    }

    /// Replaced when the preset is applied (not by the watcher): the rule's process name, or "This app".
    static let appNameToken = "{{appName}}"
    static let appNameFallback = "This app"

    /// The message for a rule whose process is `appName` (empty for a notify-only rule).
    func message(appName: String) -> String {
        let app = appName.trimmingCharacters(in: .whitespaces)
        return message.replacingOccurrences(of: Self.appNameToken, with: app.isEmpty ? Self.appNameFallback : app)
    }

    /// The `# Title` line, or the first line of text, for lists.
    var summaryLine: String {
        let parts = DialogMessageParts.split(message)
        if !parts.title.isEmpty { return parts.title }
        return parts.body.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
    }

    /// Why the preset can't be saved as it is. `others` are the presets it will sit beside (itself included or not).
    func issues(among others: [DialogPreset]) -> [String] {
        var out: [String] = []
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            out.append("Give the preset a name.")
        } else if others.contains(where: { $0.id != id && Self.sameName($0.name, trimmed) }) {
            out.append("Another preset is already called “\(trimmed)”.")
        }
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("Write the message the preset should insert.")
        }
        return out
    }

    /// A copy with its own identity and a name no other preset uses ("App blocked copy", then "… copy 2").
    func duplicate(among existing: [DialogPreset]) -> DialogPreset {
        DialogPreset(name: Self.uniqueName("\(name.trimmingCharacters(in: .whitespaces)) copy", among: existing), message: message)
    }

    /// `base`, or `base 2`, `base 3`… when a preset already has that name (ignoring case and outer spaces).
    static func uniqueName(_ base: String, among existing: [DialogPreset]) -> String {
        let base = base.trimmingCharacters(in: .whitespaces)
        func taken(_ candidate: String) -> Bool { existing.contains { sameName($0.name, candidate) } }
        if !taken(base) { return base }
        var n = 2
        while taken("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    private static func sameName(_ a: String, _ b: String) -> Bool {
        a.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(b.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }

    /// A preset made from a rule's message. The rule's process name becomes `{{appName}}` so the preset fits
    /// other rules; watcher variables already in the message are kept as typed.
    static func generalizing(_ message: String, appName: String, name: String) -> DialogPreset {
        let app = appName.trimmingCharacters(in: .whitespaces)
        let template = app.isEmpty ? message : message.replacingOccurrences(of: app, with: appNameToken)
        return DialogPreset(name: name, message: template)
    }

    // MARK: Built-in

    /// The three presets every installation starts with. Fixed IDs let "Restore Built-in Presets" see which are missing.
    static let builtIn = [appBlocked, featureBlocked, policyNotice]

    static let appBlocked = DialogPreset(
        id: UUID(uuidString: "5D1F0C3A-7B2E-4E8A-9C44-1A6B3F9D2E01")!,
        name: "App blocked",
        message: "# \(appNameToken) Blocked\n\n\(appNameToken) isn't available on this Mac.\n\nThis is a policy of \(MessageVariable.companyName.token). If you believe you need access, please contact the Service Desk.")

    static let featureBlocked = DialogPreset(
        id: UUID(uuidString: "5D1F0C3A-7B2E-4E8A-9C44-1A6B3F9D2E02")!,
        name: "Feature blocked",
        message: "# Feature Unavailable\n\nThis feature of \(appNameToken) has been turned off on this Mac by \(MessageVariable.companyName.token).\n\nIf you need it for your work, please contact the Service Desk.")

    static let policyNotice = DialogPreset(
        id: UUID(uuidString: "5D1F0C3A-7B2E-4E8A-9C44-1A6B3F9D2E03")!,
        name: "Policy notice",
        message: "# Policy Notice\n\nThis action isn't permitted under the acceptable use policy of \(MessageVariable.companyName.token).\n\nIf you have questions, please contact the Service Desk.")
}

/// Plain-language description of what the watcher will do with a rule. Never runs anything.
enum DryRun {
    static func steps(for rule: RuleModel, settings: RuleSettings) -> [String] {
        var steps: [String] = []
        let cooldown = rule.cooldownSeconds ?? RuleModel.defaultCooldownSeconds
        switch rule.kind {
        case .event, .notifyOnly:
            steps.append("Streams the unified log with the predicate:\n\(rule.predicate ?? "")")
            steps.append("Each matching log line (about 0.25 s after the event) triggers the rule. No polling.")
        case .presence:
            steps.append("Polls every 0.5 s for a process named exactly “\(rule.killProcess ?? "")” (pgrep -x).")
            steps.append("Caveat: a process that starts and exits within one poll interval can be missed.")
        case .watchOneKillAnother:
            steps.append("Polls every 0.5 s for a process named exactly “\(rule.watchProcess ?? "")” (pgrep -x).")
        }
        if let kill = rule.killProcess {
            steps.append("Kills every process named exactly “\(kill)” (pkill -x). The kill happens every time.")
            steps.append("Shows the dialog, at most once every \(cooldown) s (CooldownSeconds rate-limits the dialog only).")
        } else {
            steps.append("Shows the dialog; nothing is killed. The dialog appears at most once every \(cooldown) s (CooldownSeconds).")
        }
        if MessageVariables.usesVariables(rule.dialogMessage) {
            let used = MessageVariable.allCases.filter { rule.dialogMessage.contains($0.token) }
            steps.append("Fills in " + used.map { "\($0.token) → “\($0.value(rule: rule, settings: settings))”" }.joined(separator: ", ") + " when the dialog is shown.")
        }
        var buttons = "Primary button “\(rule.buttonText ?? "OK")”"
        buttons += rule.buttonAction.map { " opens \($0)" } ?? " closes the dialog"
        if let dismiss = rule.dismissButtonText { buttons += "; secondary button “\(dismiss)” only closes the dialog" }
        if let info = rule.infoButtonAction {
            buttons += "; “\(rule.infoButtonText ?? RuleModel.defaultInfoButtonText)” button (bottom left) closes the dialog and opens \(info)"
        }
        steps.append(buttons + ".")
        if let version = rule.requiredWatcherVersion {
            steps.append("Needs Restricted Item Watcher \(version) or later."
                + (rule.kind == .notifyOnly ? " Older watchers skip a rule without KillProcess as invalid." : "")
                + (version == RuleModel.variablesAndInfoButtonMinimumWatcherVersion ? " Older watchers show {{…}} variables as typed and have no info button." : ""))
        }
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
         rule.dialogMessageAlignment?.rawValue, rule.dialogMessagePosition?.rawValue,
         rule.infoButtonAction == nil ? nil : (rule.infoButtonText ?? RuleModel.defaultInfoButtonText)]
            .map { $0 ?? "-" }
    }

    /// Command lines that bring a dialog showing `old` up to date with `new` (empty if nothing visible changed).
    static func commands(from old: RuleModel, to new: RuleModel, oldSettings: RuleSettings, newSettings: RuleSettings) -> [String] {
        var lines: [String] = []
        if !DialogCommand.showsBanner(new, settings: newSettings), oldSettings.orgNameFriendly != newSettings.orgNameFriendly {
            lines.append("title: \(encode(newSettings.orgNameFriendly))")
        }
        // Compared expanded, so a changed company name or rule name updates a message that uses the variable.
        let oldMessage = MessageVariables.expand(old.dialogMessage, rule: old, settings: oldSettings)
        let newMessage = MessageVariables.expand(new.dialogMessage, rule: new, settings: newSettings)
        if oldMessage != newMessage {
            lines.append("message: \(encode(newMessage))")
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
