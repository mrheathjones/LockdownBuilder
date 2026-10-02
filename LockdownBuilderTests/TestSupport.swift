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

    /// Checks a rule dictionary against the draft-04 keywords the rule schema uses (required,
    /// additionalProperties, type, minLength, minimum, enum, pattern). Returns one line per violation.
    static func schemaViolations(_ rule: [String: Any], schema: [String: Any]) -> [String] {
        var out: [String] = []
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] where rule[key] == nil { out.append("\(key): required") }
        for (key, value) in rule.sorted(by: { $0.key < $1.key }) {
            guard let spec = properties[key] else {
                if schema["additionalProperties"] as? Bool == false { out.append("\(key): not allowed") }
                continue
            }
            let number = value as? NSNumber
            let isBool = number.map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
            switch spec["type"] as? String {
            case "string":
                guard let s = value as? String else { out.append("\(key): not a string"); continue }
                if let min = spec["minLength"] as? Int, s.count < min { out.append("\(key): too short") }
                if let allowed = spec["enum"] as? [String], !allowed.contains(s) { out.append("\(key): not in enum") }
                if let pattern = spec["pattern"] as? String,
                   s.range(of: pattern, options: .regularExpression) == nil { out.append("\(key): pattern") }
            case "integer":
                guard let n = number, !isBool, !CFNumberIsFloatType(n) else { out.append("\(key): not an integer"); continue }
                if let min = spec["minimum"] as? Int, n.intValue < min { out.append("\(key): below minimum") }
            case "boolean":
                if !isBool { out.append("\(key): not a boolean") }
            default:
                out.append("\(key): unsupported schema type")
            }
        }
        return out
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
