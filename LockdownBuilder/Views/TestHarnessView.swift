import SwiftUI

struct TestHarnessView: View {
    @State private var model: TestHarnessModel
    @Environment(\.dismiss) private var dismiss

    init(rule: RuleModel, settings: RuleSettings) {
        _model = State(initialValue: TestHarnessModel(rule: rule, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                dryRunSection
                simulateSection
                liveKillSection
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text("Testing a snapshot of “\(model.rule.name)”. Edits made after opening aren't included.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 560)
        .task { await model.refreshMatches() }
        .onDisappear { model.stopDialog() }
    }

    // MARK: Sections

    private var dryRunSection: some View {
        Section {
            ForEach(Array(model.dryRunSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline) {
                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                    Text(step).textSelection(.enabled)
                }
            }
            HStack(alignment: .top) {
                Text("Running now")
                Spacer()
                matchSummary
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshMatches() }
                }
                .labelStyle(.iconOnly)
                .help("Run pgrep -x again")
            }
        } header: {
            Text("Dry run")
        } footer: {
            Text("Describes what the watcher would do. Nothing is killed or shown.")
        }
    }

    @ViewBuilder
    private var matchSummary: some View {
        if let error = model.matchError {
            Text(error).foregroundStyle(.red)
        } else if let kill = model.killMatches {
            VStack(alignment: .trailing) {
                Text(describe(kill, name: model.rule.killProcess))
                if let watch = model.watchMatches, let name = model.rule.watchProcess {
                    Text(describe(watch, name: name))
                }
            }
            .font(.callout)
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func describe(_ pids: [Int32], name: String) -> String {
        pids.isEmpty
            ? "No “\(name)” process (pgrep -x)"
            : "“\(name)”: \(pids.count) process\(pids.count == 1 ? "" : "es") (PID \(pids.map(String.init).joined(separator: ", ")))"
    }

    private var simulateSection: some View {
        Section {
            Text(model.shellCommand)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(8)
            HStack {
                switch model.dialogState {
                case .idle:
                    EmptyView()
                case .running:
                    ProgressView().controlSize(.small)
                    Text("Dialog is open…")
                case .finished(let text):
                    Label(text, systemImage: "checkmark.circle").foregroundStyle(.green)
                case .failed(let text):
                    Label(text, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                Spacer()
                Button("Copy Command") { FileDialogs.copyToClipboard(model.shellCommand) }
                if model.dialogState == .running {
                    Button("Close Dialog") { model.stopDialog() }
                } else {
                    Button("Simulate Dialog") { model.simulateDialog() }
                        .disabled(!model.dialogInstalled)
                }
            }
        } header: {
            Text("Simulate dialog")
        } footer: {
            Text(model.dialogInstalled
                 ? "Launches swiftDialog with the same flags the watcher uses. Never kills anything, and ButtonAction is reported, not opened."
                 : "swiftDialog isn't installed at \(DialogCommand.dialogPath).")
        }
    }

    private var liveKillSection: some View {
        Section {
            if let reason = model.killBlockedReason {
                Label(reason, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            } else {
                TextField("Type “\(model.rule.killProcess)” to confirm", text: $model.confirmation)
                    .accessibilityLabel("Process name confirmation")
                HStack {
                    if let result = model.killResult {
                        Text(result).font(.callout)
                    }
                    Spacer()
                    Button("Kill “\(model.rule.killProcess)” Now", role: .destructive) {
                        Task { await model.liveKill() }
                    }
                    .disabled(!model.canLiveKill)
                }
            }
        } header: {
            Label("Live kill test (optional)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } footer: {
            Text("Runs pkill -x on this Mac right now. Unsaved work in that app is lost. No dialog is shown.")
        }
    }
}
