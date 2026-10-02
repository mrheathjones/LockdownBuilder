import SwiftUI

/// Guided predicate discovery: baseline → action → ranked candidates, each with a live test.
struct DiscoveryView: View {
    let onUse: (String) -> Void
    @State private var model: DiscoveryModel
    @State private var tester = PredicateLiveTester()
    @Environment(\.dismiss) private var dismiss

    init(target: String, onUse: @escaping (String) -> Void) {
        self.onUse = onUse
        _model = State(initialValue: DiscoveryModel(target: target))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Discover a Predicate").font(.title2.bold())
            HStack {
                Text("Target app")
                TextField("System Settings", text: $model.target)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .disabled(model.isRecording)
                Text("Action")
                TextField("e.g. Internet Accounts (optional)", text: $model.hint)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit { model.rerank() }
                    .help("Words for the thing you're blocking. Lines that mention it rank higher and match on it.")
                if model.phase == .results {
                    Button("Re-rank") { model.rerank() }
                }
                Spacer()
            }
            stepPanel
            if model.phase == .results { results }
            Spacer(minLength: 0)
            HStack {
                Text("Streams the unified log as you (no data leaves this Mac). Never use a predicate that hasn't fired in a live test.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.phase == .results { Button("Start Over") { tester.stop(); model.startOver() } }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(width: 880, height: 680)
        .onDisappear {
            tester.stop()
            model.cancel()
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var stepPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                switch model.phase {
                case .ready:
                    step(1, "Get \(targetName) ready, but don't do the thing yet (e.g. open System Settings on another pane).")
                    step(2, "Start Baseline records ~\(model.baselineSeconds) s of normal log activity.")
                    step(3, "Start Action, do the thing once (click the pane, the field, launch the tool), then Stop.")
                    HStack { Spacer(); Button("Start Baseline") { model.startBaseline() }.buttonStyle(.borderedProminent) }
                case .baseline:
                    recording("Recording baseline… \(max(0, model.baselineSeconds - model.secondsInWindow)) s left. Don't touch \(targetName).")
                    HStack { Spacer(); Button("Stop Baseline Early") { model.stopBaseline() } }
                case .between:
                    recording("Baseline recorded. Click Start Action, then do the thing in \(targetName) once.")
                    HStack { Spacer(); Button("Start Action") { model.startAction() }.buttonStyle(.borderedProminent) }
                case .action:
                    recording("Recording action (\(model.secondsInWindow) s)… do it now, then click Stop.")
                    HStack {
                        Spacer()
                        Button("Stop") { Task { await model.stop() } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                case .analysing:
                    HStack { ProgressView().controlSize(.small); Text("Ranking candidates…") }
                case .results:
                    Text(model.summary).font(.callout).foregroundStyle(.secondary)
                case .failed(let message):
                    Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("log stream needs an administrator account. Run Rule Builder as an admin user, or capture on a test Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack { Spacer(); Button("Try Again") { model.startBaseline() } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private var targetName: String { model.target.isEmpty ? "the app" : model.target }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("\(n).").monospacedDigit().foregroundStyle(.secondary)
            Text(text)
        }
    }

    private func recording(_ text: String) -> some View {
        HStack {
            Image(systemName: "record.circle").foregroundStyle(.red).symbolEffect(.pulse)
            Text(text)
            Spacer()
            Text("\(model.linesSeen.formatted()) lines").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    // MARK: Results

    private var results: some View {
        Group {
            if model.candidates.isEmpty {
                ContentUnavailableView(
                    "No Candidates", systemImage: "magnifyingglass",
                    description: Text("Nothing appeared only during the action. Try again and perform the action more deliberately, or use a presence rule."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(model.candidates) { candidate in
                            CandidateRow(candidate: candidate, tester: tester, onUse: {
                                tester.stop()
                                onUse(candidate.predicate)
                                dismiss()
                            })
                        }
                    }
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: DiscoveryCandidate
    let tester: PredicateLiveTester
    let onUse: () -> Void

    private var isTesting: Bool { tester.predicate == candidate.predicate }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(candidate.predicate)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                Spacer()
                Text("\(candidate.score)")
                    .font(.caption.bold().monospacedDigit())
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
                    .help("Ranking score")
            }
            ForEach(candidate.reasons, id: \.self) { Label($0, systemImage: "checkmark").foregroundStyle(.green) }
            ForEach(candidate.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
            ForEach(candidate.notes, id: \.self) { Label($0, systemImage: "info.circle").foregroundStyle(.blue) }
            Text("\(candidate.sample.process): \(candidate.sample.message)")
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                if isTesting {
                    LiveTestStatus(tester: tester)
                }
                Spacer()
                if isTesting && tester.isRunning {
                    Button("Stop Test") { tester.stop() }
                } else {
                    Button("Test") { tester.start(candidate.predicate) }
                        .help("Stream the log with this predicate; repeat the action and watch it fire")
                }
                Button("Use") { onUse() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Hit counter that flashes each time the predicate fires.
struct LiveTestStatus: View {
    let tester: PredicateLiveTester
    @State private var flash = false

    var body: some View {
        HStack(spacing: 6) {
            if let error = tester.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(2)
            } else if tester.hits > 0 {
                Label("Fired \(tester.hits)×", systemImage: "bolt.fill")
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(flash ? Color.green.opacity(0.35) : .clear, in: Capsule())
            } else if tester.isRunning {
                ProgressView().controlSize(.small)
                Text("Listening… do the action again")
            }
        }
        .onChange(of: tester.pulse) {
            flash = true
            withAnimation(.easeOut(duration: 0.8)) { flash = false }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Live test for a hand-written (or AI-suggested) predicate from the editor.
struct PredicateLiveTestView: View {
    let predicate: String
    @State private var tester = PredicateLiveTester()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Live Test").font(.title2.bold())
            Text(predicate).font(.callout.monospaced()).textSelection(.enabled)
            Text("Do the action now. Each matching log line counts as a hit. The watcher would kill on the first one.")
                .foregroundStyle(.secondary)
            LiveTestStatus(tester: tester)
            if let last = tester.lastMatch {
                Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Spacer()
                if tester.isRunning {
                    Button("Stop") { tester.stop() }
                } else {
                    Button("Start Again") { tester.start(predicate) }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 560, height: 320)
        .onAppear { tester.start(predicate) }
        .onDisappear { tester.stop() }
    }
}
