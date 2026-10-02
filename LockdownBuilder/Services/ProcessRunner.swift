import Foundation
import Synchronization

struct ProcessOutput: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    /// True when the process ended because we terminated it (cancellation or timeout).
    var wasTerminated: Bool
}

enum ProcessRunnerError: LocalizedError, Equatable {
    case notFound(String)
    case failed(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path) was not found."
        case .failed(let status, let message):
            message.isEmpty ? "Exited with code \(status)." : message.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

/// All subprocess work (`dialog`, `pgrep`, `pkill`, `plutil`, later `log stream`) goes through here so it never
/// blocks the main actor. Cancelling the calling task terminates the child process.
actor ProcessRunner {
    static let shared = ProcessRunner()

    func run(_ executable: String, _ arguments: [String], timeout: Duration? = nil) async throws -> ProcessOutput {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw ProcessRunnerError.notFound(executable)
        }
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let exit = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { p in
            exit.continuation.yield(p.terminationStatus)
            exit.continuation.finish()
        }
        let stdout = PipeCollector(out.fileHandleForReading)
        let stderr = PipeCollector(err.fileHandleForReading)
        try process.run()

        // Unstructured on purpose: it must not be cancelled with the caller, so that after we terminate the
        // child we still wait for the real exit (reading terminationReason earlier raises an ObjC exception).
        let exitStatus = Task<Int32, Never> {
            for await code in exit.stream { return code }
            return -1
        }

        let timeoutTask = timeout.map { limit in
            Task {
                try await Task.sleep(for: limit)
                if process.isRunning { process.terminate() }
            }
        }
        defer { timeoutTask?.cancel() }

        return await withTaskCancellationHandler {
            let status = await exitStatus.value
            return ProcessOutput(
                status: status,
                stdout: await stdout.text(),
                stderr: await stderr.text(),
                wasTerminated: process.terminationReason == .uncaughtSignal)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    /// Streams stdout line by line (e.g. `log stream`). Ending iteration or cancelling the consuming task
    /// terminates the process. A non-zero exit that we didn't cause finishes the stream with `.failed`.
    nonisolated func lines(_ executable: String, _ arguments: [String]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: executable) else {
                continuation.finish(throwing: ProcessRunnerError.notFound(executable))
                return
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let exit = AsyncStream<Int32>.makeStream()
            process.terminationHandler = { p in
                exit.continuation.yield(p.terminationStatus)
                exit.continuation.finish()
            }
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            let stderr = PipeCollector(err.fileHandleForReading)
            let reader = Task {
                do {
                    for try await line in out.fileHandleForReading.bytes.lines {
                        continuation.yield(line)
                    }
                } catch {
                    // Read error: fall through to the exit status.
                }
                var status: Int32 = -1
                for await code in exit.stream { status = code }
                let message = await stderr.text()
                if status != 0, process.terminationReason != .uncaughtSignal {
                    continuation.finish(throwing: ProcessRunnerError.failed(status: status, message: message))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
                _ = reader
            }
        }
    }

    // MARK: Conveniences

    /// PIDs of processes whose name is exactly `name` (`pgrep -x`). Empty when none match.
    func pgrep(_ name: String) async throws -> [Int32] {
        let output = try await run("/usr/bin/pgrep", ["-x", name], timeout: .seconds(5))
        return output.stdout.split(separator: "\n").compactMap { Int32($0) }
    }

    /// Checks a unified-log predicate the way the watcher will use it: `log stream --predicate` exits at once
    /// (rc 64) on a bad predicate, and keeps running on a good one.
    func checkPredicate(_ predicate: String) async throws -> String? {
        let output = try await run(
            "/usr/bin/log", ["stream", "--style", "compact", "--predicate", predicate], timeout: .seconds(1))
        if output.wasTerminated { return nil }
        let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "log stream exited with code \(output.status)." : message
    }

    /// `ps -axo pid=,comm=`, parsed into unique process names.
    func runningProcesses() async throws -> [ProcessTarget] {
        TargetResolver.parsePS(try await run("/bin/ps", ["-axo", "pid=,comm="], timeout: .seconds(5)).stdout)
    }

    /// `pkill -x`; returns true if at least one process was signalled.
    func pkill(_ name: String) async throws -> Bool {
        try await run("/usr/bin/pkill", ["-x", name], timeout: .seconds(5)).status == 0
    }
}

/// Drains a pipe on GCD's readability handler (not the cooperative pool), so a chatty child such as `ps`
/// never blocks on a full 64 KB pipe buffer. `text()` returns everything once the writer closes.
private final class PipeCollector: Sendable {
    private let data = Mutex(Data())
    private let eof: AsyncStream<Void>

    init(_ handle: FileHandle) {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        eof = stream
        handle.readabilityHandler = { [self] h in
            let chunk = h.availableData
            if chunk.isEmpty {
                h.readabilityHandler = nil
                continuation.finish()
            } else {
                data.withLock { $0.append(chunk) }
            }
        }
    }

    func text() async -> String {
        for await _ in eof {}
        return data.withLock { String(decoding: $0, as: UTF8.self) }
    }
}
