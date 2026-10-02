import AppKit
import Observation
import UniformTypeIdentifiers

enum TargetChoice: Equatable {
    case kill(String)
    case watch(String)
    case watchAndKill(watch: String, kill: String)
}

@MainActor
@Observable
final class TargetPickerModel {
    enum Tab: String, CaseIterable, Identifiable {
        case running = "Running"
        case app = "App"
        case extensions = "Extensions"
        case path = "Command Line"
        var id: String { rawValue }
    }

    var tab: Tab = .running
    var search = ""
    var pathText = ""
    private(set) var running: [ProcessTarget] = []
    private(set) var extensions: [ProcessTarget] = []
    private(set) var selected: ProcessTarget?
    /// `pgrep -x` count for the selected target; nil while checking.
    private(set) var matchCount: Int?
    private(set) var message: String?

    private let runner: ProcessRunner

    init(runner: ProcessRunner = .shared) {
        self.runner = runner
    }

    func load() async {
        var byName: [String: ProcessTarget] = [:]
        do {
            for target in try await runner.runningProcesses() { byName[target.name] = target }
        } catch {
            message = "Couldn't list processes: \(error.localizedDescription)"
        }
        // GUI apps add bundle IDs and app paths.
        for app in NSWorkspace.shared.runningApplications {
            guard let name = app.executableURL?.lastPathComponent else { continue }
            byName[name] = ProcessTarget(
                name: name, kind: app.bundleURL?.pathExtension == "appex" ? .appExtension : .application,
                bundleID: app.bundleIdentifier, path: app.bundleURL?.path ?? app.executableURL?.path)
        }
        running = byName.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        extensions = await Task.detached { TargetResolver.extensions() }.value
    }

    func filtered(_ list: [ProcessTarget]) -> [ProcessTarget] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
                || ($0.path?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    func select(_ target: ProcessTarget?) {
        selected = target
        matchCount = nil
        message = nil
        guard let target else { return }
        Task {
            let count = (try? await runner.pgrep(target.name).count) ?? 0
            if selected == target { matchCount = count }
        }
    }

    func resolveBundle(_ url: URL) {
        if let target = TargetResolver.target(forBundleAt: url) {
            select(target)
        } else {
            message = "\(url.lastPathComponent) isn't an app or extension bundle with a CFBundleExecutable."
        }
    }

    func resolvePath() {
        guard let target = TargetResolver.target(forExecutablePath: pathText) else {
            message = "Enter an absolute path, e.g. /usr/bin/fm."
            return
        }
        select(target)
        if target.kind == .commandLine, !FileManager.default.isExecutableFile(atPath: target.path ?? "") {
            message = "There's no executable at \(target.path ?? "") on this Mac. The name “\(target.name)” is still usable."
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle, .applicationExtension]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose an app (or extension) to get its process name."
        if panel.runModal() == .OK, let url = panel.url { resolveBundle(url) }
    }

    var denylisted: Bool { selected.map { RuleModel.killDenylist.contains($0.name) } ?? false }
}
