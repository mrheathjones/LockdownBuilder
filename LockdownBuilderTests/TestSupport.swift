import Foundation
@testable import LockdownBuilder

enum TestSupport {
    /// Repository root, derived from this file's location (LockdownBuilderTests/ sits at the root).
    static let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let samplesDirectory = repoRoot.appendingPathComponent("Samples", isDirectory: true)
    static let schemaFileName = "restricted-item-rule.schema.json"

    /// A valid baseline rule to mutate in the validation matrix.
    static func validRule() -> RuleModel {
        RuleModel(name: "my-rule", killProcess: "Some App", dialogMessage: "# Blocked\n\nNot allowed.")
    }

    struct ToolResult { var status: Int32; var output: String }

    /// Runs a tool synchronously (tests only).
    static func run(_ path: String, _ arguments: [String], input: Data? = nil) throws -> ToolResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        let inPipe = Pipe()
        process.standardInput = inPipe
        try process.run()
        if let input { inPipe.fileHandleForWriting.write(input) }
        try inPipe.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ToolResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// `plutil -lint -` on the given text.
    static func lint(_ text: String) throws -> ToolResult {
        try run("/usr/bin/plutil", ["-lint", "-"], input: Data(text.utf8))
    }

    /// `plutil -convert xml1 -o - -` (Apple's canonical serialisation) of the given plist text.
    static func canonicalXML(_ text: String) throws -> String {
        try run("/usr/bin/plutil", ["-convert", "xml1", "-o", "-", "-"], input: Data(text.utf8)).output
    }
}
