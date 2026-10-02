import Foundation

/// Something the user can point KillProcess or WatchProcess at, resolved to the name `pgrep -x` sees.
struct ProcessTarget: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case application = "App"
        case appExtension = "Extension"
        case commandLine = "Command-line tool"
        case process = "Process"
    }

    var name: String
    var kind: Kind
    var bundleID: String?
    var path: String?

    var id: String { "\(kind.rawValue)|\(path ?? name)" }

    /// Guidance shown when this target is picked.
    var notes: [String] {
        switch kind {
        case .appExtension:
            [
                "Extension processes only exist while their host app has loaded them.",
                "Don't kill only the extension: System Settings then shows “Extension process exited”. Watch the extension (or use a predicate) and kill the host; the extension exits with it and a relaunch re-arms the rule.",
            ]
        case .commandLine:
            [
                "One-shot commands can exit before the 0.5 s poll sees them. If the command logs something distinctive, an event rule (Predicate) is more reliable.",
            ]
        case .application, .process:
            []
        }
    }
}

enum TargetResolver {
    static let systemExtensionsDirectory = "/System/Library/ExtensionKit/Extensions"

    /// An `.app` or `.appex`: the process name is its `CFBundleExecutable`.
    static func target(forBundleAt url: URL) -> ProcessTarget? {
        guard let bundle = Bundle(url: url),
              let executable = bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String,
              !executable.isEmpty
        else { return nil }
        return ProcessTarget(
            name: executable,
            kind: url.pathExtension == "appex" ? .appExtension : .application,
            bundleID: bundle.bundleIdentifier,
            path: url.path)
    }

    /// A path to a binary (e.g. `/usr/bin/fm`): the process name is the file name as invoked
    /// (a symlink's own name, not its destination's).
    static func target(forExecutablePath path: String) -> ProcessTarget? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let url = URL(fileURLWithPath: trimmed)
        if url.pathExtension == "app" || url.pathExtension == "appex" { return target(forBundleAt: url) }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != "/" else { return nil }
        return ProcessTarget(name: name, kind: .commandLine, bundleID: nil, path: trimmed)
    }

    /// Parses `ps -axo pid=,comm=` output into unique process names (comm is usually the full executable path).
    static func parsePS(_ output: String) -> [ProcessTarget] {
        var seen: [String: ProcessTarget] = [:]
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "), Int(trimmed[..<space]) != nil else { continue }
            let comm = trimmed[space...].trimmingCharacters(in: .whitespaces)
            guard !comm.isEmpty else { continue }
            let name = comm.hasPrefix("/") ? URL(fileURLWithPath: comm).lastPathComponent : comm
            let kind: ProcessTarget.Kind = comm.contains(".appex/Contents/MacOS/") ? .appExtension
                : comm.contains(".app/Contents/MacOS/") ? .application : .process
            if seen[name] == nil {
                seen[name] = ProcessTarget(name: name, kind: kind, bundleID: nil, path: comm.hasPrefix("/") ? comm : nil)
            }
        }
        return seen.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Extensions shipped in /System/Library/ExtensionKit/Extensions (or another directory, for tests).
    static func extensions(in directory: String = systemExtensionsDirectory) -> [ProcessTarget] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        return names.filter { $0.hasSuffix(".appex") }.sorted()
            .compactMap { target(forBundleAt: URL(fileURLWithPath: directory).appendingPathComponent($0)) }
    }
}
