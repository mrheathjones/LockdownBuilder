import Foundation
import Testing
@testable import LockdownBuilder

struct DialogCommandTests {
    private var appStore: RuleModel { BuiltInTemplates.appStore.rule(settings: RuleSettings()) }

    @Test func withoutBannerUsesOrgTitle() {
        let args = DialogCommand.arguments(for: appStore, settings: RuleSettings())
        #expect(args == [
            "--title", "Company Name",
            "--message", appStore.dialogMessage,
            "--button1text", "Self Service",
            "--button2text", "Done",
            "--ontop", "--moveable",
        ])
    }

    @Test func withBannerUsesBannerAndTitleNone() {
        var settings = RuleSettings(); settings.bannerImagePath = "/Library/Org/banner.png"
        let rule = BuiltInTemplates.freeform.rule(settings: settings)
        let args = DialogCommand.arguments(for: rule, settings: settings)
        #expect(Array(args.prefix(4)) == ["--bannerimage", "/Library/Org/banner.png", "--title", "none"])
        #expect(args.contains("--button1text") && args[args.firstIndex(of: "--button1text")! + 1] == "OK")
        #expect(!args.contains("--button2text"))
        #expect(Array(args.suffix(2)) == ["--ontop", "--moveable"])
    }

    @Test func messageIsPassedVerbatimAsOneArgument() {
        var rule = TestSupport.validRule()
        rule.dialogMessage = "# T\n\n$(touch /tmp/x) `id` 'q' \"d\""
        let args = DialogCommand.arguments(for: rule, settings: RuleSettings())
        #expect(args[args.firstIndex(of: "--message")! + 1] == rule.dialogMessage)
    }

    @Test func shellQuotingIsSafe() {
        #expect(DialogCommand.shellQuote("--ontop") == "--ontop")
        #expect(DialogCommand.shellQuote("System Settings") == "'System Settings'")
        #expect(DialogCommand.shellQuote("it's") == #"'it'\''s'"#)
        #expect(DialogCommand.shellQuote("") == "''")
    }

    @Test func exitCodesAreDescribed() {
        #expect(DialogCommand.describeExit(0, rule: appStore).contains("/Applications/Self Service.app"))
        #expect(DialogCommand.describeExit(2, rule: appStore).contains("Done"))
        #expect(DialogCommand.describeExit(0, rule: TestSupport.validRule()).contains("just closes"))
    }
}

struct DialogMarkdownTests {
    @Test func leadingHashLineBecomesTitle() {
        let doc = DialogMarkdown.parse("\n# Blocked\n\nFirst para\nsecond line\n\n## Sub\n- one\n* two\n\nLast")
        #expect(doc.title == "Blocked")
        #expect(doc.blocks == [
            .paragraph("First para\nsecond line"),
            .heading("Sub"),
            .bullet("one"), .bullet("two"),
            .paragraph("Last"),
        ])
    }

    @Test func noTitleWhenMessageDoesNotStartWithHeading() {
        let doc = DialogMarkdown.parse("Hello\n# Not a title")
        #expect(doc.title == nil)
        #expect(doc.blocks == [.paragraph("Hello"), .heading("Not a title")])
    }

    @Test func handlesCRLFAndEmptyInput() {
        #expect(DialogMarkdown.parse("# A\r\n\r\nB").blocks == [.paragraph("B")])
        #expect(DialogMarkdown.parse("") == .init(title: nil, blocks: []))
    }
}

struct DialogPresetTests {
    @Test(arguments: DialogPreset.allCases)
    func presetsProduceValidTitledMessages(preset: DialogPreset) {
        let message = preset.message(appName: "Freeform", org: "Acme")
        var rule = TestSupport.validRule(); rule.dialogMessage = message
        #expect(rule.isValid)
        #expect(DialogMarkdown.parse(message).title != nil)
        #expect(message.contains("Acme"))
    }

    @Test func emptyAppNameFallsBack() {
        #expect(DialogPreset.appBlocked.message(appName: " ", org: "Acme").hasPrefix("# This app Blocked"))
    }
}

struct DryRunTests {
    private let settings = RuleSettings()

    @Test func eventRuleDescribesPredicateAndNoPolling() {
        let steps = DryRun.steps(for: BuiltInTemplates.appleAccount.rule(settings: settings), settings: settings)
        #expect(steps[0].contains("IMKClient subclass"))
        #expect(steps.contains { $0.contains("pkill -x") && $0.contains("System Settings") })
        #expect(steps.contains { $0.contains("/Library/Managed Preferences/com.company.restrict.apple-account.plist") })
    }

    @Test func presenceRuleWarnsAboutShortLivedProcesses() {
        let steps = DryRun.steps(for: BuiltInTemplates.fm.rule(settings: settings), settings: settings)
        #expect(steps.contains { $0.contains("0.5 s") })
        #expect(steps.contains { $0.contains("can be missed") })
    }

    @Test func watchRuleNamesBothProcessesAndCooldown() {
        var rule = TestSupport.validRule()
        rule.killProcess = "System Settings"; rule.watchProcess = "InternetAccountsSettingsExtension"; rule.cooldownSeconds = 9
        let steps = DryRun.steps(for: rule, settings: settings).joined(separator: "\n")
        #expect(steps.contains("InternetAccountsSettingsExtension") && steps.contains("System Settings"))
        #expect(steps.contains("once every 9 s"))
    }
}

struct LineDiffTests {
    @Test func identicalTextHasNoChanges() {
        #expect(!LineDiff.hasChanges(LineDiff.diff(old: "a\nb", new: "a\nb")))
    }

    @Test func reportsAddedAndRemovedLinesInOrder() {
        let lines = LineDiff.diff(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(lines == [.same("a"), .removed("b"), .added("B"), .same("c"), .added("d")])
    }

    @Test func detectsAChangedCooldownInRealPlists() {
        var rule = TestSupport.validRule(); rule.cooldownSeconds = 5
        let old = RuleExport.plist(for: rule)
        rule.cooldownSeconds = 30
        let changed = LineDiff.diff(old: old, new: RuleExport.plist(for: rule)).filter { if case .same = $0 { false } else { true } }
        #expect(changed == [.removed("\t<integer>5</integer>"), .added("\t<integer>30</integer>")])
    }
}

struct ExportHistoryTests {
    private let history = ExportHistory(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("ExportHistoryTests-\(UUID().uuidString)", isDirectory: true))

    @Test func recordsAndReadsBack() {
        #expect(history.lastExport(fileName: "com.company.restrict.fm.plist") == nil)
        history.record("one", fileName: "com.company.restrict.fm.plist")
        history.record("two", fileName: "com.company.restrict.fm.plist")
        #expect(history.lastExport(fileName: "com.company.restrict.fm.plist") == "two")
    }

    @Test(arguments: ["../escape.plist", "a/b.plist", ".hidden", ""])
    func refusesUnsafeFileNames(name: String) {
        history.record("x", fileName: name)
        #expect(history.lastExport(fileName: name) == nil)
    }
}

struct SettingsCodingTests {
    @Test func decodesSettingsSavedBeforeNewerKeysExisted() throws {
        let old = #"{"orgPlistDomain":"com.acme","preference":"restrict","orgNameFriendly":"Acme"}"#
        let settings = try JSONDecoder().decode(RuleSettings.self, from: Data(old.utf8))
        #expect(settings.orgPlistDomain == "com.acme")
        #expect(settings.defaultOutputFolder.isEmpty && settings.bannerImagePath.isEmpty)
    }

    @Test func roundTrips() throws {
        var s = RuleSettings(); s.bannerImagePath = "/x.png"; s.defaultOutputFolder = "/out"
        #expect(try JSONDecoder().decode(RuleSettings.self, from: JSONEncoder().encode(s)) == s)
    }
}

/// Exercises the real process plumbing. The kill tests run /bin/sleep through a uniquely named symlink,
/// so `pkill -x` can only ever match the process the test started.
@Suite(.serialized)
struct ProcessRunnerTests {
    private let runner = ProcessRunner()

    @Test func capturesOutputAndStatus() async throws {
        let ok = try await runner.run("/bin/echo", ["hello", "world"])
        #expect(ok == ProcessOutput(status: 0, stdout: "hello world\n", stderr: "", wasTerminated: false))
        let fail = try await runner.run("/bin/sh", ["-c", "echo oops >&2; exit 3"])
        #expect(fail.status == 3 && fail.stderr == "oops\n")
    }

    @Test func missingExecutableThrows() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await runner.run("/nonexistent/tool", [])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func timeoutTerminatesTheProcess() async throws {
        let start = ContinuousClock.now
        let output = try await runner.run("/bin/sleep", ["30"], timeout: .milliseconds(300))
        #expect(output.wasTerminated)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationTerminatesTheProcess() async throws {
        let task = Task { try await runner.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let output = try await task.value
        #expect(output.wasTerminated)
    }

    @Test func pgrepFindsNothingForAnUnknownName() async throws {
        #expect(try await runner.pgrep("no-such-process-\(UUID().uuidString.prefix(8))").isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func pgrepAndPkillMatchTheFullUniqueName() async throws {
        let (name, process) = try startSleeper()
        defer { if process.isRunning { process.terminate() } }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await runner.pgrep(name) == [process.processIdentifier])
        #expect(try await runner.pgrep(String(name.dropLast())).isEmpty)  // -x is an exact match
        #expect(try await runner.pkill(name))
        process.waitUntilExit()
        #expect(!(try await runner.pkill(name)))
    }

    @MainActor
    @Test(.timeLimit(.minutes(1)))
    func liveKillRequiresExactConfirmation() async throws {
        let (name, process) = try startSleeper()
        defer { if process.isRunning { process.terminate() } }
        let model = TestHarnessModel(rule: RuleModel(name: "t", killProcess: name, dialogMessage: "m"),
                                     settings: RuleSettings(), runner: runner)
        #expect(!model.canLiveKill)
        model.confirmation = name.uppercased()
        #expect(!model.canLiveKill)
        await model.liveKill()
        #expect(process.isRunning)
        model.confirmation = name
        #expect(model.canLiveKill)
        await model.liveKill()
        process.waitUntilExit()
        #expect(model.killResult?.contains("SIGTERM") == true)
        #expect(model.confirmation.isEmpty)
    }

    @MainActor
    @Test func denylistedProcessCanNeverBeLiveKilled() {
        let model = TestHarnessModel(rule: RuleModel(name: "t", killProcess: "loginwindow", dialogMessage: "m"),
                                     settings: RuleSettings())
        model.confirmation = "loginwindow"
        #expect(model.killBlockedReason != nil)
        #expect(!model.canLiveKill)
    }

    /// Starts /bin/sleep through a uniquely named symlink; the process name (what pgrep -x sees) is the link name.
    /// (A copied platform binary is SIGKILLed by code-signing enforcement, so a symlink is used instead.)
    private func startSleeper() throws -> (String, Process) {
        let name = "lbtest\(Int.random(in: 100_000...999_999))"
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let binary = dir.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: binary, withDestinationURL: URL(fileURLWithPath: "/bin/sleep"))
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        return (name, process)
    }
}
