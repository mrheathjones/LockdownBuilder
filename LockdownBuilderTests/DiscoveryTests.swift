import Foundation
import Testing
@testable import LockdownBuilder

/// Synthetic fixture logs in `log stream --style compact` format. They are modelled on real captures but
/// contain no data from any real Mac.
enum DiscoveryFixtures {
    static let header = """
    Filtering the log data using "composedMessage CONTAINS ..."
    Timestamp               Ty Process[PID:TID]
    """

    /// System Settings already open on another pane; background noise from other processes.
    static let internetAccountsBaseline = """
    \(header)
    2026-10-01 10:00:00.100 Df System Settings[812:1a2b] [com.apple.systempreferences:main] Navigated to pane com.apple.Wallpaper-Settings.extension
    2026-10-01 10:00:00.200 Df System Settings[812:1a2b] [com.apple.extensionkit:NSExtension] Beginning extension request for WallpaperSettingsExtension with identifier com.apple.Wallpaper-Settings.extension
    2026-10-01 10:00:00.300 Df IMTransferAgent[3207:2538] [com.apple.Messages.blastdoor:Default] Received notification com.apple.system.logging.prefschanged with state 0
    2026-10-01 10:00:01.400 Df IMTransferAgent[3207:2538] [com.apple.Messages.blastdoor:Default] Received notification com.apple.system.logging.prefschanged with state 1
    2026-10-01 10:00:02.500 A  xpcproxy[6957:253c] (libsystem_info.dylib) Retrieve User by ID
    2026-10-01 10:00:03.600 Df System Settings[812:1a2b] [com.apple.AppKit:Window] Window 0x7f8a1c0 became key
    \tcontinuation line that is not an event
    2026-10-01 10:00:04.700 E  cfprefsd[400:99] [com.apple.defaults:User Defaults] Couldn't read values in CFPrefsPlistSource<0x6000033>
    """

    /// The user clicks Internet Accounts.
    static let internetAccountsAction = """
    2026-10-01 10:00:10.100 Df System Settings[812:1a2b] [com.apple.systempreferences:main] Navigated to pane com.apple.Internet-Accounts-Settings.extension
    2026-10-01 10:00:10.150 Df System Settings[812:1a2b] [com.apple.extensionkit:NSExtension] Beginning extension request for InternetAccountsSettingsExtension with identifier com.apple.Internet-Accounts-Settings.extension
    2026-10-01 10:00:10.200 Df IMTransferAgent[3207:2538] [com.apple.Messages.blastdoor:Default] Received notification com.apple.system.logging.prefschanged with state 7
    2026-10-01 10:00:10.300 Df System Settings[812:1a2b] [com.apple.AppKit:Window] Window 0x7f8a1c8 became key
    2026-10-01 10:00:10.400 Df InternetAccountsSettingsExtension[9001:77] [com.apple.accounts:Accounts] Loaded 3 accounts for display
    2026-10-01 10:00:10.410 Df InternetAccountsSettingsExtension[9001:77] [com.apple.accounts:Accounts] Loaded 3 accounts for display
    2026-10-01 10:00:10.420 Df InternetAccountsSettingsExtension[9001:77] [com.apple.accounts:Accounts] Loaded 4 accounts for display
    2026-10-01 10:00:10.430 Df InternetAccountsSettingsExtension[9001:77] [com.apple.accounts:Accounts] Loaded 4 accounts for display
    2026-10-01 10:00:10.440 Df InternetAccountsSettingsExtension[9001:77] [com.apple.accounts:Accounts] Loaded 5 accounts for display
    2026-10-01 10:00:10.500 Df InternetAccountsSettingsExtension[9001:77] [com.apple.UIKit:Scene] Scene did activate
    """

    static let appleAccountBaseline = """
    \(header)
    2026-10-01 11:00:00.100 Df AppleIDSettings[700:1] [com.apple.AppleIDSettings:UI] Showing sign-in view
    2026-10-01 11:00:00.200 Df AppleIDSettings[700:1] [com.apple.AppKit:Window] Window 0x1 became key
    """

    /// The user clicks into the sign-in email field.
    static let appleAccountAction = """
    2026-10-01 11:00:05.000 Df AppleIDSettings[700:1] [com.apple.inputmethodkitClient:IMKClient] IMKClient subclass: IMKInputSessionXPCClient, document: <private>
    2026-10-01 11:00:05.010 I  AppleIDSettings[700:1] [com.apple.inputmethodkitClient:IMKClient] Input session activated for <private>
    2026-10-01 11:00:05.020 Df AppleIDSettings[700:1] [com.apple.AppKit:Window] Window 0x2 became key
    """

    static func aggregate(baseline: String, action: String) -> DiscoveryAggregate {
        var aggregate = DiscoveryAggregate()
        for raw in baseline.split(separator: "\n") { if let l = LogLine.parse(String(raw)) { aggregate.add(l, inAction: false) } }
        for raw in action.split(separator: "\n") { if let l = LogLine.parse(String(raw)) { aggregate.add(l, inAction: true) } }
        return aggregate
    }
}

struct LogLineTests {
    @Test func parsesProcessNamesWithSpacesAndSubsystem() throws {
        let line = try #require(LogLine.parse(
            "2026-10-01 21:22:53.705 Df System Settings[812:1a2b] [com.apple.extensionkit:NSExtension] Beginning request [x]"))
        #expect(line.timestamp == "2026-10-01 21:22:53.705")
        #expect(line.level == .default)
        #expect(line.process == "System Settings")
        #expect(line.pid == 812)
        #expect(line.subsystem == "com.apple.extensionkit")
        #expect(line.category == "NSExtension")
        #expect(line.message == "Beginning request [x]")
    }

    @Test func parsesLibrarySenderAndTwoCharacterPaddedLevels() throws {
        let line = try #require(LogLine.parse("2026-10-01 21:22:53.716 A  xpcproxy[6957:253cd81] (libsystem_info.dylib) Retrieve User by ID"))
        #expect(line.level == .activity)
        #expect(line.subsystem == nil)
        #expect(line.sender == "libsystem_info.dylib")
        #expect(line.message == "Retrieve User by ID")
    }

    @Test func emptyCategoryIsAllowed() throws {
        let line = try #require(LogLine.parse("2026-10-01 21:22:53.716 E  foo[1:a] [com.x:] boom"))
        #expect(line.subsystem == "com.x" && line.category == "" && line.message == "boom")
    }

    @Test(arguments: [
        "Timestamp               Ty Process[PID:TID]",
        #"Filtering the log data using "process == \"x\"""#,
        "\tConnected Path: satisfied",
        "",
        "2026-10-01 21:22:53.705 ZZ foo[1:a] message",
        "2026-10-01 21:22:53.705 Df no pid here",
    ])
    func nonEventsDoNotParse(raw: String) {
        #expect(LogLine.parse(raw) == nil)
    }

    @Test func isEventChecksTheDatePrefix() {
        #expect(LogLine.isEvent("2026-10-01 21:22:53.705 Df x[1:a] y"))
        #expect(!LogLine.isEvent("Timestamp               Ty"))
        #expect(!LogLine.isEvent("2026-10-01"))
    }
}

struct LogNormalizerTests {
    @Test func replacesVariableParts() {
        #expect(LogNormalizer.normalize("Window 0x7f8a1c0 became key") == "Window <hex> became key")
        #expect(LogNormalizer.normalize("id FE308C66-ABBD-4AAC-8C66-A41621831CB2 ok") == "id <uuid> ok")
        #expect(LogNormalizer.normalize("Loaded 3 accounts in 0.25s") == "Loaded <n> accounts in <n>.<n>s")
        #expect(LogNormalizer.normalize("token deadbeef01 and C6.1") == "token <id> and C<n>.<n>")
        #expect(LogNormalizer.normalize("com.apple.Internet-Accounts-Settings.extension") == "com.apple.Internet-Accounts-Settings.extension")
    }

    @Test func redactionsAndRandomTokensAreVariable() {
        #expect(LogNormalizer.normalize("Last Navigation Event: <mask.hash: 'fRjC4s94I34Mmx6xou5huw=='>") == "Last Navigation Event: <…>")
        #expect(LogNormalizer.normalize("view `<private>` for <NSView <inner>> done") == "view `<…>` for <…> done")
        #expect(LogNormalizer.normalize("build 4~CV22ugDCSGBhEYWNLn ok") == "build <n>~<id> ok")
        #expect(LogNormalizer.stableFragment(of: "Last Navigation Event: <mask.hash: 'fRjC4s94I34Mmx6xou5huw=='>") == "Last Navigation Event")
    }

    @Test func hintPicksTheTokenThatMentionsIt() {
        let message = "Launching process with config: identity: RecordIdentity(record: ExtensionFoundation.Database._ExtensionRecord(InternetAccountsSettingsExtension))"
        #expect(LogNormalizer.stableFragment(of: message, hint: "Internet Accounts") == "InternetAccountsSettingsExtension")
        #expect(LogNormalizer.compact("Internet-Accounts_X y") == "internetaccountsxy")
    }

    @Test func linesDifferingOnlyInNumbersShareAKey() throws {
        let a = try #require(LogLine.parse("2026-10-01 10:00:00.100 Df p[1:a] [s:c] Loaded 3 accounts"))
        let b = try #require(LogLine.parse("2026-10-01 10:00:00.200 Df p[2:b] [s:c] Loaded 12 accounts"))
        #expect(LogKey(a) == LogKey(b))
    }

    @Test func fragmentPrefersADistinctiveToken() {
        #expect(LogNormalizer.stableFragment(of: "Beginning extension request for InternetAccountsSettingsExtension with identifier com.apple.Internet-Accounts-Settings.extension")
                == "InternetAccountsSettingsExtension")
    }

    @Test func fragmentFallsBackToTheLongestStableRun() {
        #expect(LogNormalizer.stableFragment(of: "IMKClient subclass: <private>") == "IMKClient subclass")
        #expect(LogNormalizer.stableFragment(of: "Loaded 3 accounts for display") == "accounts for display")
    }
}

struct PredicateBuilderTests {
    @Test func buildsTheTemplateShape() {
        #expect(PredicateBuilder.predicate(process: "System Settings", subsystem: "com.apple.extensionkit",
                                           fragment: "InternetAccountsSettingsExtension")
                == BuiltInTemplates.internetAccounts.rule(settings: RuleSettings()).predicate)
    }

    @Test func omitsMissingPartsAndEscapesQuotes() {
        #expect(PredicateBuilder.predicate(process: "fm", subsystem: nil, fragment: "")  == #"process == "fm""#)
        #expect(PredicateBuilder.quote(#"say "hi" \ bye"#) == #""say \"hi\" \\ bye""#)
    }
}

struct DiscoveryRankerTests {
    @Test func rediscoversTheInternetAccountsTemplatePredicate() throws {
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction)
        let candidates = DiscoveryRanker.rank(aggregate, target: "System Settings")
        let top = try #require(candidates.first)
        #expect(top.predicate == BuiltInTemplates.internetAccounts.rule(settings: RuleSettings()).predicate)
        #expect(top.actionMatches == 1)
        #expect(top.notes.contains { $0.contains("re-arms") })
        #expect(top.warnings.isEmpty)
    }

    @Test func hintBoostsLinesThatMentionTheBlockedThing() throws {
        var aggregate = DiscoveryAggregate()
        for raw in [
            "2026-10-01 10:00:01.000 Df System Settings[1:a] [com.apple.Settings:nav] Processing URL destination for pane",
            "2026-10-01 10:00:01.100 Df System Settings[1:a] [com.apple.extensionkit:launch] Launching process with config: record(InternetAccountsSettingsExtension)",
        ] {
            aggregate.add(try #require(LogLine.parse(raw)), inAction: true)
        }
        let top = try #require(DiscoveryRanker.rank(aggregate, target: "System Settings", hint: "Internet Accounts").first)
        #expect(top.predicate == BuiltInTemplates.internetAccounts.rule(settings: RuleSettings()).predicate)
        #expect(top.reasons.contains { $0.contains("Internet Accounts") })
    }

    @Test func excludesLinesSeenInTheBaseline() {
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction)
        let predicates = DiscoveryRanker.rank(aggregate, target: "System Settings").map(\.predicate)
        #expect(!predicates.contains { $0.contains("prefschanged") })   // same shape as baseline, differs only by number
        #expect(!predicates.contains { $0.contains("became key") })
    }

    @Test func penalisesNoisyAndLaunchLikeLines() throws {
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction)
        let candidates = DiscoveryRanker.rank(aggregate, target: "System Settings")
        let noisy = try #require(candidates.first { $0.fragment == "accounts for display" })
        #expect(noisy.actionMatches == 5)
        #expect(noisy.warnings.contains { $0.contains("noisy") })
        let scene = try #require(candidates.first { $0.sample.message.contains("Scene did activate") })
        #expect(scene.warnings.contains { $0.contains("launches") })
        #expect(candidates.first!.score > noisy.score && candidates.first!.score > scene.score)
    }

    @Test func appleAccountTopCandidateIsTheIMKClientLine() throws {
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.appleAccountBaseline, action: DiscoveryFixtures.appleAccountAction)
        let top = try #require(DiscoveryRanker.rank(aggregate, target: "System Settings").first)
        #expect(top.process == "AppleIDSettings")
        #expect(top.subsystem == "com.apple.inputmethodkitClient")
        #expect(top.predicate.contains("IMKClient subclass") || top.predicate.contains("IMKInputSessionXPCClient"))
        #expect(top.actionMatches == 1)
    }

    @Test func fragmentThatAlsoMatchesBaselineIsWarned() throws {
        var aggregate = DiscoveryAggregate()
        let base = try #require(LogLine.parse("2026-10-01 10:00:00.000 Df p[1:a] [s:c] Opened Wallpaper-Settings pane quickly"))
        let act = try #require(LogLine.parse("2026-10-01 10:00:01.000 Df p[1:a] [s:c] Opened Wallpaper-Settings pane"))
        aggregate.add(base, inAction: false)
        aggregate.add(act, inAction: true)
        let candidate = try #require(DiscoveryRanker.rank(aggregate, target: "").first)
        #expect(candidate.warnings.contains { $0.contains("baseline") })
    }

    @Test func ignoresOurOwnProcessAndLog() throws {
        var aggregate = DiscoveryAggregate()
        aggregate.add(try #require(LogLine.parse("2026-10-01 10:00:01.000 Df LockdownBuilder[1:a] [s:c] Something unique happened")), inAction: true)
        aggregate.add(try #require(LogLine.parse("2026-10-01 10:00:01.000 Df log[2:a] [s:c] Something else unique")), inAction: true)
        #expect(DiscoveryRanker.rank(aggregate, target: "").isEmpty)
    }
}

struct TargetResolverTests {
    @Test func resolvesAppBundlesToTheirExecutable() throws {
        let settings = try #require(TargetResolver.target(forBundleAt: URL(fileURLWithPath: "/System/Applications/System Settings.app")))
        #expect(settings.name == "System Settings")
        #expect(settings.kind == .application)
        #expect(settings.bundleID == "com.apple.systempreferences")
    }

    @Test func resolvesExtensionsAndExplainsThem() throws {
        let ext = try #require(TargetResolver.target(forBundleAt: URL(fileURLWithPath:
            "/System/Library/ExtensionKit/Extensions/InternetAccountsSettingsExtension.appex")))
        #expect(ext.name == "InternetAccountsSettingsExtension")
        #expect(ext.kind == .appExtension)
        #expect(ext.notes.contains { $0.contains("Extension process exited") })
        #expect(TargetResolver.extensions().contains { $0.name == "InternetAccountsSettingsExtension" })
    }

    @Test func resolvesCommandLinePathsToTheirFileName() throws {
        let fm = try #require(TargetResolver.target(forExecutablePath: " /usr/bin/fm "))
        #expect(fm.name == "fm" && fm.kind == .commandLine && fm.path == "/usr/bin/fm")
        #expect(fm.notes.contains { $0.contains("0.5 s poll") })
        #expect(TargetResolver.target(forExecutablePath: "fm") == nil)
        #expect(TargetResolver.target(forExecutablePath: "/System/Applications/System Settings.app")?.name == "System Settings")
    }

    @Test func nonBundlesDoNotResolve() {
        #expect(TargetResolver.target(forBundleAt: URL(fileURLWithPath: "/nonexistent/Foo.app")) == nil)
    }

    @Test func parsesPSOutput() {
        let ps = """
          1283 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
          2234 /System/Applications/System Settings.app/Contents/PlugIns/SettingsImportExtension.appex/Contents/MacOS/SettingsImportExtension
          2235 /System/Applications/System Settings.app/Contents/MacOS/System Settings
          2236 /System/Applications/System Settings.app/Contents/MacOS/System Settings
            99 (kernel_task)
          garbage line
        """
        let targets = TargetResolver.parsePS(ps)
        #expect(targets.map(\.name) == ["(kernel_task)", "Finder", "SettingsImportExtension", "System Settings"])
        #expect(targets.first { $0.name == "SettingsImportExtension" }?.kind == .appExtension)
        #expect(targets.first { $0.name == "System Settings" }?.kind == .application)
    }
}

@Suite(.serialized)
struct LogStreamingTests {
    private let runner = ProcessRunner()

    @Test(.timeLimit(.minutes(1)))
    func streamsLinesAndFinishes() async throws {
        var lines: [String] = []
        for try await line in runner.lines("/bin/sh", ["-c", "echo one; echo two; echo three"]) { lines.append(line) }
        #expect(lines == ["one", "two", "three"])
    }

    @Test(.timeLimit(.minutes(1)))
    func nonZeroExitFinishesWithAnError() async {
        await #expect(throws: ProcessRunnerError.failed(status: 64, message: "bad\n")) {
            for try await _ in runner.lines("/bin/sh", ["-c", "echo bad >&2; exit 64"]) {}
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func stoppingIterationTerminatesTheProcess() async throws {
        var first: String?
        for try await line in runner.lines("/bin/sh", ["-c", "while true; do echo tick; sleep 0.05; done"]) {
            first = line
            break
        }
        #expect(first == "tick")
    }

    @Test(.timeLimit(.minutes(1)))
    func predicateSyntaxCheckUsesLogStream() async throws {
        #expect(try await runner.checkPredicate(#"process == "System Settings" AND eventMessage CONTAINS "x""#) == nil)
        let error = try #require(try await runner.checkPredicate("process =="))
        #expect(error.contains("Bad predicate"))
    }

    /// Regression: `ps` writes > 64 KB; a slow reader used to leave it blocked on the pipe until the timeout.
    @Test(.timeLimit(.minutes(1)))
    func capturesOutputLargerThanThePipeBuffer() async throws {
        let start = ContinuousClock.now
        let output = try await runner.run("/bin/sh", ["-c", "head -c 400000 /dev/zero | tr '\\0' 'x'"], timeout: .seconds(10))
        #expect(!output.wasTerminated)
        #expect(output.stdout.count == 400_000)
        #expect(ContinuousClock.now - start < .seconds(3))
    }

    @Test(.timeLimit(.minutes(1)))
    func streamsManyLinesQuickly() async throws {
        let start = ContinuousClock.now
        var count = 0
        for try await _ in runner.lines("/bin/sh", ["-c", "yes '2026-10-01 10:00:00.000 Df p[1:a] [s:c] message' | head -n 100000"]) {
            count += 1
        }
        #expect(count == 100_000)
        #expect(ContinuousClock.now - start < .seconds(10))
    }

    @Test func listsRunningProcessesIncludingOurselves() async throws {
        let names = try await runner.runningProcesses().map(\.name)
        #expect(names.contains("LockdownBuilder"))
    }
}

/// Opt-in evaluation on a real capture (never committed): run with
/// `TEST_RUNNER_DISCOVERY_BASELINE=/path/baseline.log TEST_RUNNER_DISCOVERY_ACTION=/path/action.log
///  TEST_RUNNER_DISCOVERY_TARGET="System Settings" TEST_RUNNER_DISCOVERY_HINT="Internet Accounts"`.
struct RealCaptureEvaluation {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DISCOVERY_ACTION"] != nil))
    func printRanking() throws {
        let env = ProcessInfo.processInfo.environment
        let baseline = try String(contentsOfFile: env["DISCOVERY_BASELINE"] ?? "", encoding: .utf8)
        let action = try String(contentsOfFile: env["DISCOVERY_ACTION"] ?? "", encoding: .utf8)
        let aggregate = DiscoveryFixtures.aggregate(baseline: baseline, action: action)
        let ranked = DiscoveryRanker.rank(aggregate, target: env["DISCOVERY_TARGET"] ?? "", hint: env["DISCOVERY_HINT"] ?? "", limit: 10)
        var report = "baseline \(aggregate.baselineLines) action \(aggregate.actionLines)\n"
        for c in ranked {
            report += "[\(c.score)] x\(c.actionMatches) \(c.predicate)\n    warn: \(c.warnings)\n"
        }
        try report.write(toFile: (env["DISCOVERY_ACTION"] ?? "") + ".ranking.txt", atomically: true, encoding: .utf8)
    }
}
