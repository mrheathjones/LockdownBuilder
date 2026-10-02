import Foundation
import Observation

/// Keeps a real swiftDialog window in sync with the rule being edited (like swiftDialog's builder):
/// launches it with the watcher's flags plus a private `--commandfile`, then appends only what changed.
@MainActor
@Observable
final class LiveDialogController {
    private(set) var isRunning = false
    private(set) var status: String?

    private let runner: ProcessRunner
    private var dialogTask: Task<Void, Never>?
    private var pendingUpdate: Task<Void, Never>?
    private var commandFile: URL?
    private var shown: (rule: RuleModel, settings: RuleSettings)?
    private var generation = 0

    init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }

    var dialogInstalled: Bool { FileManager.default.isExecutableFile(atPath: DialogCommand.dialogPath) }

    func start(rule: RuleModel, settings: RuleSettings) {
        stop()
        generation += 1
        let myGeneration = generation
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LockdownBuilder-live-\(UUID().uuidString).log")
            // Private to this user: the command file controls what the dialog shows.
            guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            commandFile = url
            shown = (rule, settings)
            isRunning = true
            status = "Live: edits appear in the swiftDialog window as you type."
            let arguments = DialogCommand.arguments(for: rule, settings: settings) + ["--commandfile", url.path]
            dialogTask = Task {
                let output = try? await runner.run(DialogCommand.dialogPath, arguments)
                // Only the current launch may update state (a relaunch replaces it).
                guard myGeneration == generation else { return }
                isRunning = false
                if let output, !output.wasTerminated {
                    status = "Live preview closed (\(DialogCommand.describeExit(output.status, rule: shown?.rule ?? rule)))"
                } else {
                    status = nil
                }
                cleanUpFile()
            }
        } catch {
            status = "Couldn't start the live preview: \(error.localizedDescription)"
        }
    }

    /// Debounced: typing produces one update ~0.3 s after the last keystroke.
    func update(rule: RuleModel, settings: RuleSettings) {
        guard isRunning else { return }
        pendingUpdate?.cancel()
        pendingUpdate = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            apply(rule: rule, settings: settings)
        }
    }

    func stop() {
        pendingUpdate?.cancel()
        pendingUpdate = nil
        generation += 1
        dialogTask?.cancel()  // terminates the dialog process
        dialogTask = nil
        isRunning = false
        status = nil
        cleanUpFile()
    }

    private func apply(rule: RuleModel, settings: RuleSettings) {
        guard isRunning, let shown, let commandFile else { return }
        if DialogLiveUpdate.needsRelaunch(from: shown.rule, to: rule, oldSettings: shown.settings, newSettings: settings) {
            start(rule: rule, settings: settings)
            return
        }
        let lines = DialogLiveUpdate.commands(from: shown.rule, to: rule, oldSettings: shown.settings, newSettings: settings)
        guard !lines.isEmpty else { return }
        do {
            let handle = try FileHandle(forWritingTo: commandFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
            self.shown = (rule, settings)
        } catch {
            status = "Couldn't update the live preview: \(error.localizedDescription)"
        }
    }

    private func cleanUpFile() {
        if let commandFile { try? FileManager.default.removeItem(at: commandFile) }
        commandFile = nil
    }
}
