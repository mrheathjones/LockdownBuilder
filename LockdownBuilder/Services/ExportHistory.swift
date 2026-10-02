import Foundation

/// Remembers the last exported text of each file, so a rule (or an imported plist) can be diffed against it.
/// Stored under Application Support; nothing leaves the Mac.
struct ExportHistory: Sendable {
    let directory: URL

    static var standard: ExportHistory {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ExportHistory(directory: base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LockdownBuilder", isDirectory: true)
            .appendingPathComponent("LastExports", isDirectory: true))
    }

    func record(_ text: String, fileName: String) {
        guard Self.isSafe(fileName) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: directory.appendingPathComponent(fileName), options: .atomic)
    }

    func lastExport(fileName: String) -> String? {
        guard Self.isSafe(fileName),
              let data = try? Data(contentsOf: directory.appendingPathComponent(fileName))
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isSafe(_ fileName: String) -> Bool {
        !fileName.isEmpty && !fileName.contains("/") && !fileName.hasPrefix(".")
    }
}
