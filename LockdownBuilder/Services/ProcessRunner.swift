import Foundation

struct ProcessOutput: Sendable, Equatable {
    var status: Int32
    var stdout: String
    var stderr: String
    /// True when the process ended because we terminated it (cancellation or timeout).
    var wasTerminated: Bool
}

enum ProcessRunnerError: LocalizedError {
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let path): "\(path) was not found."
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
            async let stdout = Self.collect(out.fileHandleForReading)
            async let stderr = Self.collect(err.fileHandleForReading)
            let status = await exitStatus.value
            return ProcessOutput(
                status: status,
                stdout: await stdout,
                stderr: await stderr,
                wasTerminated: process.terminationReason == .uncaughtSignal)
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }

    private static func collect(_ handle: FileHandle) async -> String {
        var data = Data()
        do {
            for try await byte in handle.bytes { data.append(byte) }
        } catch {
            // A read error just truncates the captured output.
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Conveniences

    /// PIDs of processes whose name is exactly `name` (`pgrep -x`). Empty when none match.
    func pgrep(_ name: String) async throws -> [Int32] {
        let output = try await run("/usr/bin/pgrep", ["-x", name], timeout: .seconds(5))
        return output.stdout.split(separator: "\n").compactMap { Int32($0) }
    }

    /// `pkill -x`; returns true if at least one process was signalled.
    func pkill(_ name: String) async throws -> Bool {
        try await run("/usr/bin/pkill", ["-x", name], timeout: .seconds(5)).status == 0
    }
}
