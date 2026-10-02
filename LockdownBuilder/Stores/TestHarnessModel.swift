import Foundation
import Observation

/// State for the local, non-destructive test harness. Only the clearly labelled live kill test kills anything.
@MainActor
@Observable
final class TestHarnessModel {
    enum DialogState: Equatable {
        case idle
        case running
        case finished(String)
        case failed(String)
    }

    let rule: RuleModel
    let settings: RuleSettings
    private let runner: ProcessRunner

    private(set) var killMatches: [Int32]?
    private(set) var watchMatches: [Int32]?
    private(set) var matchError: String?
    private(set) var dialogState: DialogState = .idle
    var confirmation = ""
    private(set) var killResult: String?
    private(set) var isKilling = false
    private var dialogTask: Task<Void, Never>?

    init(rule: RuleModel, settings: RuleSettings, runner: ProcessRunner = .shared) {
        self.rule = rule
        self.settings = settings
        self.runner = runner
    }

    var dryRunSteps: [String] { DryRun.steps(for: rule, settings: settings) }
    var dialogInstalled: Bool { FileManager.default.isExecutableFile(atPath: DialogCommand.dialogPath) }
    var shellCommand: String { DialogCommand.shellCommand(for: rule, settings: settings) }

    /// Issues on KillProcess (empty, denylisted, unmatchable) block the live kill test, and a rule
    /// without KillProcess has nothing to kill.
    var killBlockedReason: String? {
        if let issue = rule.validate().first(where: { $0.field == .killProcess && $0.isError }) { return issue.message }
        return rule.killProcess == nil ? "This rule has no KillProcess: it shows the dialog and nothing is killed." : nil
    }

    var canLiveKill: Bool {
        killBlockedReason == nil && rule.killProcess != nil && confirmation == rule.killProcess && !isKilling
    }

    func refreshMatches() async {
        matchError = nil
        do {
            if let kill = rule.killProcess {
                killMatches = try await runner.pgrep(kill)
            }
            if let watch = rule.watchProcess {
                watchMatches = try await runner.pgrep(watch)
            }
        } catch {
            matchError = error.localizedDescription
        }
    }

    func simulateDialog() {
        dialogTask?.cancel()
        dialogState = .running
        let arguments = DialogCommand.arguments(for: rule, settings: settings)
        let rule = rule
        dialogTask = Task {
            do {
                let output = try await runner.run(DialogCommand.dialogPath, arguments)
                guard !Task.isCancelled else { dialogState = .idle; return }
                dialogState = .finished(output.wasTerminated
                    ? "Dialog was closed from LockdownBuilder."
                    : DialogCommand.describeExit(output.status, rule: rule))
            } catch {
                dialogState = .failed(error.localizedDescription)
            }
        }
    }

    func stopDialog() {
        dialogTask?.cancel()
        dialogTask = nil
        if dialogState == .running { dialogState = .idle }
    }

    func liveKill() async {
        guard canLiveKill, let kill = rule.killProcess else { return }
        isKilling = true
        defer { isKilling = false; confirmation = "" }
        do {
            let killed = try await runner.pkill(kill)
            killResult = killed
                ? "Sent SIGTERM to every process named “\(kill)”."
                : "No process named “\(kill)” was running."
            await refreshMatches()
        } catch {
            killResult = error.localizedDescription
        }
    }
}
