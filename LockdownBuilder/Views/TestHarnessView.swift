import SwiftUI

struct TestHarnessView: View {
    @State private var model: TestHarnessModel
    @Environment(\.dismiss) private var dismiss

    init(rule: RuleModel, settings: RuleSettings) {
        _model = State(initialValue: TestHarnessModel(rule: rule, settings: settings))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "play.circle.fill").font(.system(size: 22)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Test “\(model.rule.name)”").font(.system(size: 15, weight: .semibold))
                    Text("Uses a snapshot of the rule. Edits made after opening aren't included.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            ScrollView {
                VStack(spacing: 12) {
                    dryRunSection
                    simulateSection
                    liveKillSection
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 620)
        .task { await model.refreshMatches() }
        .onDisappear { model.stopDialog() }
    }

    // MARK: Sections

    private func cardHeader(_ symbol: String, _ tint: Color, _ title: String, _ subtitle: String, badge: String, badgeTint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Badge(text: badge, tint: badgeTint)
        }
    }

    private var dryRunSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("checklist", .green, "Dry run", "What the watcher would do. Nothing is quit or shown.",
                       badge: "SAFE", badgeTint: .green)
            ForEach(Array(model.dryRunSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1)")
                        .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .background(.quaternary, in: Circle())
                    Text(step).font(.system(size: 12)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 7))
                    .foregroundStyle((model.killMatches?.isEmpty ?? true) ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.green))
                Text("Running now:").foregroundStyle(.secondary)
                matchSummary
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refreshMatches() }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Run pgrep -x again")
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .card()
    }

    @ViewBuilder
    private var matchSummary: some View {
        if let error = model.matchError {
            Text(error).foregroundStyle(.red)
        } else if let kill = model.killMatches {
            VStack(alignment: .leading) {
                Text(describe(kill, name: model.rule.killProcess))
                if let watch = model.watchMatches, let name = model.rule.watchProcess {
                    Text(describe(watch, name: name))
                }
            }
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
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("macwindow", .accentColor, "Simulate dialog",
                       model.dialogInstalled
                           ? "Opens swiftDialog with the watcher's flags. ButtonAction is reported, not opened."
                           : "swiftDialog isn't installed at \(DialogCommand.dialogPath).",
                       badge: "SAFE", badgeTint: .green)
            ScrollView {
                Text(model.shellCommand)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 96)
            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
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
                    Label(text, systemImage: "xmark.circle.fill").foregroundStyle(.red)
                }
                Spacer()
                Button("Copy Command") { FileDialogs.copyToClipboard(model.shellCommand) }
                if model.dialogState == .running {
                    Button("Close Dialog") { model.stopDialog() }
                } else {
                    Button("Simulate Dialog") { model.simulateDialog() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!model.dialogInstalled)
                }
            }
            .font(.system(size: 11))
        }
        .padding(14)
        .card()
    }

    private var liveKillSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            cardHeader("exclamationmark.triangle.fill", .orange, "Live kill test (optional)",
                       "Runs pkill -x on this Mac right now. Unsaved work in that app is lost. No dialog is shown.",
                       badge: "DESTRUCTIVE", badgeTint: .orange)
            if let reason = model.killBlockedReason {
                Label(reason, systemImage: "xmark.circle.fill").foregroundStyle(.red)
            } else {
                HStack {
                    TextField("Type “\(model.rule.killProcess)” to confirm", text: $model.confirmation)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Process name confirmation")
                    Button("Quit Now", role: .destructive) {
                        Task { await model.liveKill() }
                    }
                    .disabled(!model.canLiveKill)
                }
                if let result = model.killResult {
                    Text(result).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .card(border: .red.opacity(0.3), fill: .red.opacity(0.06))
    }
}
