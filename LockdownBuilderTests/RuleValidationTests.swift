import Testing
@testable import LockdownBuilder

struct RuleValidationTests {
    private func codes(_ rule: RuleModel) -> Set<ValidationCode> { Set(rule.validate().map(\.code)) }

    @Test func baselineRuleIsValid() {
        #expect(TestSupport.validRule().validate().isEmpty)
    }

    // MARK: Name

    @Test(arguments: ["apple-account", "fm", "a1", "app-store-2", "x-y-z"])
    func acceptsKebabCase(name: String) {
        var rule = TestSupport.validRule(); rule.name = name
        #expect(rule.isValid)
    }

    @Test(arguments: ["Apple-Account", "apple_account", "apple.account", "apple account", "-apple", "apple-", "apple--account", "ÄPFEL", "com.company.restrict.x"])
    func rejectsNonKebabCase(name: String) {
        var rule = TestSupport.validRule(); rule.name = name
        #expect(codes(rule).contains(.nameNotKebabCase))
    }

    @Test func rejectsEmptyName() {
        var rule = TestSupport.validRule(); rule.name = ""
        #expect(codes(rule) == [.nameEmpty])
    }

    @Test func rejectsReservedWatcherName() {
        var rule = TestSupport.validRule(); rule.name = "watcher"
        #expect(codes(rule) == [.nameReserved])
        rule.name = "Watcher"   // case-only variants collide on APFS
        #expect(codes(rule).contains(.nameNotKebabCase))
    }

    @Test func detectsCaseInsensitiveCollisions() {
        let issues = RuleModel.collisionIssues(among: ["apple-account", "Apple-Account", "fm"])
        #expect(Set(issues.keys) == ["apple-account", "Apple-Account"])
        #expect(issues.values.allSatisfy { $0.code == .nameCollision })
    }

    // MARK: KillProcess

    @Test(arguments: ["launchd", "kernel_task", "loginwindow", "WindowServer", "bash", "log", "dialog", "Restricted-Item-Watcher.sh"])
    func rejectsDenylistedKillProcess(process: String) {
        var rule = TestSupport.validRule(); rule.killProcess = process
        #expect(codes(rule).contains(.killProcessDenylisted))
        #expect(!rule.isValid)
    }

    @Test func denylistIsExactMatchOnly() {
        var rule = TestSupport.validRule(); rule.killProcess = "logger"
        #expect(rule.isValid)
        rule.killProcess = "Log"
        #expect(rule.isValid)
    }

    @Test func killProcessMayContainSpaces() {
        var rule = TestSupport.validRule(); rule.killProcess = "System Settings"
        #expect(rule.validate().isEmpty)
    }

    @Test func rejectsEmptyKillProcess() {
        var rule = TestSupport.validRule(); rule.killProcess = ""
        #expect(codes(rule) == [.emptyString])
    }

    @Test func rejectsPathsAndControlCharactersInProcessNames() {
        var rule = TestSupport.validRule(); rule.killProcess = "/usr/bin/fm"
        #expect(codes(rule).contains(.processNameUnmatchable) && !rule.isValid)
        rule.killProcess = "fm\n"
        #expect(!rule.isValid)
        rule.killProcess = "fm "   // never matches: warning, not error
        #expect(rule.isValid && !rule.validate().isEmpty)
    }

    // MARK: DialogMessage

    @Test(arguments: ["", "   ", "\n\n"])
    func rejectsBlankMessage(message: String) {
        var rule = TestSupport.validRule(); rule.dialogMessage = message
        #expect(codes(rule) == [.emptyString])
    }

    @Test func messageAllowsNewlinesButNotOtherControlCharacters() {
        var rule = TestSupport.validRule(); rule.dialogMessage = "# T\n\nA\tB\r\n"
        #expect(rule.isValid)
        rule.dialogMessage = "# T\u{0001}"
        #expect(codes(rule) == [.messageIllegalCharacters])
    }

    // MARK: Predicate / WatchProcess

    @Test func emptyOptionalStringsAreInvalid() {
        for keyPath in [\RuleModel.predicate, \.watchProcess, \.buttonText, \.buttonAction, \.dismissButtonText] as [WritableKeyPath<RuleModel, String?>] {
            var rule = TestSupport.validRule()
            rule[keyPath: keyPath] = ""
            #expect(codes(rule).contains(.emptyString), "\(keyPath)")
        }
    }

    @Test func watchProcessWithPredicateIsInvalid() {
        var rule = TestSupport.validRule()
        rule.predicate = #"process == "X""#
        rule.watchProcess = "Y"
        #expect(codes(rule) == [.predicateWithWatchProcess])
    }

    @Test func watchProcessAloneIsValidPresenceRule() {
        var rule = TestSupport.validRule()
        rule.killProcess = "System Settings"
        rule.watchProcess = "InternetAccountsSettingsExtension"
        #expect(rule.validate().isEmpty)
        #expect(rule.kind == .watchOneKillAnother)
    }

    @Test func watchProcessEqualToKillIsAWarning() {
        var rule = TestSupport.validRule(); rule.watchProcess = rule.killProcess
        #expect(codes(rule) == [.watchProcessSameAsKill])
        #expect(rule.isValid)
    }

    @Test func ruleKinds() {
        var rule = TestSupport.validRule()
        #expect(rule.kind == .presence)
        rule.predicate = "x"
        #expect(rule.kind == .event)
    }

    // MARK: Notify-only (Predicate without KillProcess)

    private func notifyRule() -> RuleModel {
        RuleModel(name: "my-notice", dialogMessage: "# Blocked\n\nNot allowed.", predicate: #"process == "X""#)
    }

    @Test func predicateWithoutKillProcessIsAValidNotifyOnlyRule() {
        let rule = notifyRule()
        #expect(rule.validate().isEmpty)
        #expect(rule.kind == .notifyOnly)
    }

    @Test func presenceRuleWithoutKillProcessIsInvalid() {
        let rule = RuleModel(name: "my-rule", dialogMessage: "# Blocked")
        #expect(rule.validate().map(\.id) == ["KillProcess/emptyString"])
        #expect(!rule.isValid)
    }

    @Test func watchRuleWithoutKillProcessIsInvalid() {
        let rule = RuleModel(name: "my-rule", dialogMessage: "# Blocked", watchProcess: "Extension")
        #expect(rule.validate().map(\.id) == ["KillProcess/emptyString"])
    }

    @Test func emptyKillProcessIsInvalidEvenWithAPredicate() {
        var rule = notifyRule(); rule.killProcess = ""
        #expect(rule.validate().map(\.id) == ["KillProcess/emptyString"])
    }

    @Test func watchProcessWithPredicateIsInvalidWithoutKillProcessToo() {
        var rule = notifyRule(); rule.watchProcess = "Y"
        #expect(codes(rule) == [.predicateWithWatchProcess])
    }

    @Test func denylistStillAppliesToAnEventRuleWithKillProcess() {
        var rule = notifyRule(); rule.killProcess = "loginwindow"
        #expect(codes(rule) == [.killProcessDenylisted])
        rule.killProcess = "Finder"
        #expect(rule.validate().isEmpty)
        #expect(rule.kind == .event)
    }

    // MARK: Message variables / info button

    @Test func knownVariablesExpandAndUnknownOnesWarn() {
        var rule = TestSupport.validRule()
        rule.dialogMessage = "# {{killProcess}} blocked\n\n{{companyName}} / {{ruleName}} / {{nope}} / {computername}"
        #expect(rule.validate().map(\.id) == ["DialogMessage/unknownVariable"])
        #expect(rule.isValid)   // a warning, not an error
        var s = RuleSettings(); s.orgNameFriendly = "Acme & Sons"
        #expect(MessageVariables.expand(rule.dialogMessage, rule: rule, settings: s)
                == "# Some App blocked\n\nAcme & Sons / my-rule / {{nope}} / {computername}")
        #expect(MessageVariables.unknownNames(in: "{{a}} {{a}} {{companyName}} {{b}}") == ["a", "b"])
        #expect(rule.requiredWatcherVersion == "1.10")
        rule.dialogMessage = "# Plain"
        #expect(rule.requiredWatcherVersion == nil)
    }

    @Test func infoButtonNeedsAnActionAndFollowsTheActionRules() {
        var rule = TestSupport.validRule()
        rule.infoButtonText = "Why?"
        #expect(codes(rule) == [.infoButtonTextWithoutAction])
        rule.infoButtonAction = "https://example.com/policy"
        #expect(rule.validate().isEmpty)
        #expect(rule.requiredWatcherVersion == "1.10")
        rule.infoButtonAction = "/Library/Docs/policy.pdf"; rule.infoButtonText = nil
        #expect(rule.validate().isEmpty)
        rule.infoButtonAction = "file:///Library/Docs/policy.pdf"
        #expect(rule.validate().map(\.id) == ["InfoButtonAction/buttonActionFileScheme"])
        rule.infoButtonAction = "Docs/policy.pdf"
        #expect(rule.validate().map(\.id) == ["InfoButtonAction/buttonActionInvalid"])
        rule.infoButtonAction = ""
        #expect(rule.validate().map(\.id) == ["InfoButtonAction/emptyString"])
    }

    // MARK: CooldownSeconds

    @Test(arguments: [0, 1, 5, 3600])
    func acceptsNonNegativeCooldown(seconds: Int) {
        var rule = TestSupport.validRule(); rule.cooldownSeconds = seconds
        #expect(rule.isValid)
    }

    @Test func rejectsNegativeCooldown() {
        var rule = TestSupport.validRule(); rule.cooldownSeconds = -1
        #expect(codes(rule) == [.cooldownNegative])
    }

    // MARK: ButtonAction

    @Test(arguments: ["/Applications/Self Service.app", "/usr/bin/true", "jamfselfservice://content", "https://example.com/a?b=c", "x-apple.systempreferences://com.apple.preference"])
    func acceptsPathsAndSchemeURLs(action: String) {
        var rule = TestSupport.validRule(); rule.buttonAction = action
        #expect(rule.isValid, "\(rule.validate())")
    }

    @Test(arguments: ["file:///etc/passwd", "FILE:///etc/passwd", "File://localhost/x", "file:/etc/passwd"])
    func rejectsFileScheme(action: String) {
        var rule = TestSupport.validRule(); rule.buttonAction = action
        #expect(codes(rule).contains(.buttonActionFileScheme))
    }

    @Test(arguments: ["Applications/Self Service.app", "self-service", "https:/missing-slash", "://nothing", "https://", "1http://x"])
    func rejectsMalformedActions(action: String) {
        var rule = TestSupport.validRule(); rule.buttonAction = action
        #expect(codes(rule).contains(.buttonActionInvalid))
    }

    @Test(arguments: ["/Applications/A.app\n", "/x\ty", "https://a.com/\u{0000}", "/x\u{001B}[0m", "/x\r"])
    func rejectsControlCharactersInButtonAction(action: String) {
        var rule = TestSupport.validRule(); rule.buttonAction = action
        #expect(codes(rule).contains(.buttonActionControlCharacters))
        #expect(!rule.isValid)
    }

    // MARK: Whole-rule behaviour

    @Test func multipleProblemsAreAllReported() {
        let rule = RuleModel(name: "Bad Name", killProcess: "launchd", dialogMessage: "",
                             predicate: "", watchProcess: "x", cooldownSeconds: -3, buttonAction: "file:///x")
        #expect(codes(rule).isSuperset(of: [
            .nameNotKebabCase, .killProcessDenylisted, .emptyString, .predicateWithWatchProcess,
            .cooldownNegative, .buttonActionFileScheme,
        ]))
    }
}
