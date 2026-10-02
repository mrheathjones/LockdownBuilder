import Foundation
import Observation
import Synchronization

/// Shared between the main actor and the background capture loop.
final class CaptureControl: Sendable {
    let inAction = Atomic<Bool>(false)
    let lines = Atomic<Int>(0)
    let finished = Atomic<Bool>(false)
}

/// Guided predicate discovery: record a baseline, record the user's action, diff, rank.
@MainActor
@Observable
final class DiscoveryModel {
    enum Phase: Equatable {
        case ready
        case baseline
        case between
        case action
        case analysing
        case results
        case failed(String)
    }

    var target: String
    /// Optional words for the thing being blocked, e.g. "Internet Accounts". Steers ranking.
    var hint = ""
    private(set) var phase: Phase = .ready
    private(set) var linesSeen = 0
    private(set) var secondsInWindow = 0
    private(set) var candidates: [DiscoveryCandidate] = []
    private(set) var summary = ""

    let baselineSeconds = 10
    let maxActionSeconds = 60

    private let runner: ProcessRunner
    private var control = CaptureControl()
    private var captureTask: Task<DiscoveryAggregate, Never>?
    private var tickTask: Task<Void, Never>?
    private var windowStart = Date.now
    private var lastAggregate: DiscoveryAggregate?

    init(target: String, runner: ProcessRunner = .shared) {
        self.target = target
        self.runner = runner
    }

    var isRecording: Bool { [.baseline, .between, .action].contains(phase) }

    func startBaseline() {
        cancel()
        control = CaptureControl()
        candidates = []
        linesSeen = 0
        phase = .baseline
        windowStart = .now
        let stream = runner.lines("/usr/bin/log", ["stream", "--style", "compact"])
        let control = control
        captureTask = Task.detached(priority: .userInitiated) {
            await Self.capture(stream, control: control)
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Ends the baseline window early. The stream keeps running; lines until "Start Action" still count as
    /// baseline, so nothing that happens before the action can become a candidate.
    func stopBaseline() {
        guard phase == .baseline else { return }
        phase = .between
    }

    func startAction() {
        guard phase == .between || phase == .baseline else { return }
        control.inAction.store(true, ordering: .relaxed)
        phase = .action
        windowStart = .now
        secondsInWindow = 0
    }

    func stop() async {
        guard phase == .action, let captureTask else { return }
        phase = .analysing
        tickTask?.cancel()
        captureTask.cancel()
        let aggregate = await captureTask.value
        self.captureTask = nil
        lastAggregate = aggregate
        candidates = DiscoveryRanker.rank(aggregate, target: target, hint: hint)
        summary = "\(aggregate.baselineLines.formatted()) baseline lines, \(aggregate.actionLines.formatted()) action lines, "
            + "\(aggregate.action.count.formatted()) distinct action line shapes, \(candidates.count) candidates."
        phase = .results
    }

    /// Re-ranks the last recording, e.g. after the hint changes.
    func rerank() {
        guard let lastAggregate else { return }
        candidates = DiscoveryRanker.rank(lastAggregate, target: target, hint: hint)
    }

    func cancel() {
        tickTask?.cancel()
        tickTask = nil
        captureTask?.cancel()
        captureTask = nil
        if phase != .results { phase = .ready }
    }

    func startOver() {
        cancel()
        candidates = []
        phase = .ready
    }

    private func tick() {
        linesSeen = control.lines.load(ordering: .relaxed)
        secondsInWindow = Int(Date.now.timeIntervalSince(windowStart))
        if control.finished.load(ordering: .relaxed), isRecording, let captureTask {
            // The stream ended on its own: almost always `log stream` refusing to run.
            tickTask?.cancel()
            Task {
                let aggregate = await captureTask.value
                phase = .failed(aggregate.error ?? "log stream stopped unexpectedly.")
            }
            return
        }
        if phase == .baseline, secondsInWindow >= baselineSeconds { stopBaseline() }
        if phase == .action, secondsInWindow >= maxActionSeconds { Task { await stop() } }
    }

    @concurrent
    nonisolated private static func capture(
        _ lines: AsyncThrowingStream<String, Error>, control: CaptureControl
    ) async -> DiscoveryAggregate {
        var aggregate = DiscoveryAggregate()
        do {
            for try await raw in lines {
                guard let line = LogLine.parse(raw) else { continue }
                control.lines.add(1, ordering: .relaxed)
                aggregate.add(line, inAction: control.inAction.load(ordering: .relaxed))
            }
        } catch {
            aggregate.error = error.localizedDescription
        }
        control.finished.store(true, ordering: .relaxed)
        return aggregate
    }
}

/// Streams `log stream --predicate …` and counts event lines, so a predicate can be proven live.
@MainActor
@Observable
final class PredicateLiveTester {
    private(set) var predicate: String?
    private(set) var isRunning = false
    private(set) var hits = 0
    private(set) var lastMatch: String?
    private(set) var error: String?
    /// Increments on every hit; views animate on change.
    private(set) var pulse = 0

    private let runner: ProcessRunner
    private var task: Task<Void, Never>?

    init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }

    func start(_ predicate: String) {
        stop()
        self.predicate = predicate
        hits = 0
        lastMatch = nil
        error = nil
        isRunning = true
        let stream = runner.lines("/usr/bin/log", ["stream", "--style", "compact", "--predicate", predicate])
        task = Task { [weak self] in
            do {
                for try await raw in stream where LogLine.isEvent(raw) {
                    guard let self else { return }
                    hits += 1
                    pulse += 1
                    lastMatch = raw
                }
            } catch {
                self?.error = error.localizedDescription
            }
            self?.isRunning = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }
}
