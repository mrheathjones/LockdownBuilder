import Foundation

/// One event line from `log stream --style compact`:
/// `2026-10-01 21:22:53.705 Df System Settings[123:4af] [com.apple.extensionkit:Default] message`
/// The two header lines and tab-indented continuation lines are not events and don't parse.
struct LogLine: Equatable, Sendable {
    enum Level: String, Sendable {
        case `default` = "Df"
        case info = "I"
        case debug = "Db"
        case error = "E"
        case fault = "F"
        case activity = "A"
    }

    var timestamp: String
    var level: Level
    var process: String
    var pid: Int
    var subsystem: String?
    var category: String?
    /// `(library.dylib)` sender, when the line has no subsystem.
    var sender: String?
    var message: String

    /// Hand-written (no Regex) because discovery parses thousands of lines a second and Swift's `Regex`
    /// isn't `Sendable`, so it can't be cached in a static.
    static func parse(_ raw: String) -> LogLine? {
        guard isEvent(raw) else { return nil }
        var rest = Substring(raw)

        func takeToken() -> Substring? {
            rest = rest.drop(while: { $0 == " " })
            guard let end = rest.firstIndex(of: " ") else { return nil }
            defer { rest = rest[end...] }
            return rest[..<end]
        }
        guard let date = takeToken(), let time = takeToken(),
              let levelToken = takeToken(), let level = Level(rawValue: String(levelToken))
        else { return nil }
        rest = rest.drop(while: { $0 == " " })

        // Process name (may contain spaces and brackets) runs up to the first "[<pid>:<tid>]".
        var search = rest.startIndex
        var found: (name: Substring, pid: Int, after: Substring.Index)?
        while found == nil, let open = rest[search...].firstIndex(of: "[") {
            let inner = rest[rest.index(after: open)...]
            if let close = inner.firstIndex(of: "]") {
                let parts = inner[..<close].split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, let pid = Int(parts[0]), !parts[1].isEmpty, parts[1].allSatisfy(\.isHexDigit) {
                    found = (rest[..<open], pid, rest.index(after: close))
                }
            }
            search = rest.index(after: open)
        }
        guard let found, !found.name.isEmpty else { return nil }
        rest = rest[found.after...].drop(while: { $0 == " " })

        var subsystem: String?, category: String?, sender: String?
        if rest.first == "[", let close = rest.firstIndex(of: "]") {
            let inner = rest[rest.index(after: rest.startIndex)..<close]
            if let colon = inner.firstIndex(of: ":") {
                subsystem = String(inner[..<colon])
                category = String(inner[inner.index(after: colon)...])
                rest = rest[rest.index(after: close)...]
            }
        } else if rest.first == "(", let close = rest.firstIndex(of: ")") {
            sender = String(rest[rest.index(after: rest.startIndex)..<close])
            rest = rest[rest.index(after: close)...]
        }
        if rest.first == " " { rest = rest.dropFirst() }

        return LogLine(
            timestamp: "\(date) \(time)", level: level, process: String(found.name), pid: found.pid,
            subsystem: subsystem, category: category, sender: sender, message: String(rest))
    }

    /// Event lines start with `YYYY-MM-DD HH:MM:SS`; everything else (headers, continuations) is ignored.
    static func isEvent(_ raw: String) -> Bool {
        let shape = Array("dddd-dd-dd dd:dd:dd".utf8)
        let bytes = raw.utf8.prefix(shape.count)
        guard bytes.count == shape.count else { return false }
        return zip(bytes, shape).allSatisfy { b, s in s == UInt8(ascii: "d") ? (48...57).contains(b) : b == s }
    }
}

/// Groups log lines that differ only in variable parts (numbers, UUIDs, addresses).
struct LogKey: Hashable, Sendable {
    var process: String
    var subsystem: String?
    var category: String?
    var normalizedMessage: String

    init(_ line: LogLine) {
        process = line.process
        subsystem = line.subsystem
        category = line.category
        normalizedMessage = LogNormalizer.normalize(line.message)
    }
}

enum LogNormalizer {
    static let placeholders = ["<uuid>", "<hex>", "<id>", "<n>", "<…>"]

    /// Replaces variable parts with placeholders: UUIDs → `<uuid>`, `0x…` → `<hex>`, long hex ids → `<id>`,
    /// digit runs → `<n>`. Single pass, no Regex (hot path).
    static func normalize(_ message: String) -> String {
        var out = ""
        out.reserveCapacity(message.utf8.count)
        var word = ""
        var depth = 0  // inside <…>: redactions such as <private> or <mask.hash: '…'>, object descriptions
        func isWordChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "-") }
        func flush() {
            guard !word.isEmpty else { return }
            out += normalizeWord(word)
            word = ""
        }
        for c in message {
            if c == "<" {
                flush()
                if depth == 0 { out += "<…>" }
                depth += 1
            } else if c == ">" && depth > 0 {
                depth -= 1
            } else if depth > 0 {
                continue
            } else if isWordChar(c) {
                word.append(c)
            } else {
                flush()
                out.append(c)
            }
        }
        flush()
        return out
    }

    private static func normalizeWord(_ word: String) -> String {
        if isUUID(word) { return "<uuid>" }
        return word.split(separator: "-", omittingEmptySubsequences: false).map { part -> String in
            let p = Substring(part)
            if p.count > 2, p.hasPrefix("0x") || p.hasPrefix("0X"), p.dropFirst(2).allSatisfy(\.isHexDigit) { return "<hex>" }
            if p.count >= 8, p.allSatisfy({ $0.isNumber || ("a"..."f").contains($0) }), p.contains(where: \.isNumber) {
                return "<id>"
            }
            // Random-looking tokens (hashes, base64, build ids): long, with both letters and digits.
            if p.count >= 6, p.contains(where: \.isNumber), p.contains(where: \.isLetter) {
                return "<id>"
            }
            // Replace each run of digits with <n>.
            var result = "", inDigits = false
            for c in p {
                if c.isNumber {
                    if !inDigits { result += "<n>"; inDigits = true }
                } else {
                    inDigits = false
                    result.append(c)
                }
            }
            return result
        }.joined(separator: "-")
    }

    private static func isUUID(_ s: String) -> Bool {
        let chars = Array(s)
        guard chars.count == 36 else { return false }
        for (i, c) in chars.enumerated() {
            if [8, 13, 18, 23].contains(i) { if c != "-" { return false } } else if !c.isHexDigit { return false }
        }
        return true
    }

    /// The literal text to use with `eventMessage CONTAINS`: the longest stable token if it's distinctive
    /// (≥ 12 characters), otherwise the longest stable run of text.
    static func stableFragment(of message: String, hint: String = "") -> String {
        let normalized = normalize(message)
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "()[]{}<>:;,\"'=.`/…"))
        let tokens = normalized.components(separatedBy: separators)
            .filter { !$0.isEmpty && !placeholders.contains($0) && !$0.contains("<") }
        let key = compact(hint)
        if !key.isEmpty, let token = tokens.filter({ compact($0).contains(key) }).max(by: { $0.count < $1.count }) {
            return token
        }
        if let token = tokens.max(by: { $0.count < $1.count }), token.count >= 12 {
            return token
        }
        var segments = [normalized]
        for p in placeholders {
            segments = segments.flatMap { $0.components(separatedBy: p) }
        }
        let trim = CharacterSet.whitespaces.union(.punctuationCharacters)
        let best = segments.map { $0.trimmingCharacters(in: trim) }.max(by: { $0.count < $1.count }) ?? ""
        return best.count > 100 ? String(best.prefix(100)).trimmingCharacters(in: trim) : best
    }
}

extension LogNormalizer {
    /// Lowercased, with spaces, hyphens and underscores removed: "Internet Accounts" ≈ "InternetAccounts…".
    static func compact(_ s: String) -> String {
        s.lowercased().filter { !" -_".contains($0) }
    }
}

enum PredicateBuilder {
    /// Escapes a value for a double-quoted NSPredicate string literal.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func predicate(process: String, subsystem: String?, fragment: String) -> String {
        var parts = ["process == \(quote(process))"]
        if let subsystem { parts.append("subsystem == \(quote(subsystem))") }
        if !fragment.isEmpty { parts.append("eventMessage CONTAINS \(quote(fragment))") }
        return parts.joined(separator: " AND ")
    }
}

/// What a discovery session recorded: every distinct line shape seen outside the action window,
/// and counts for those seen during it.
struct DiscoveryAggregate: Sendable {
    struct Stats: Sendable {
        var count: Int
        var level: LogLine.Level
        var sample: LogLine
    }

    var baseline: Set<LogKey> = []
    var action: [LogKey: Stats] = [:]
    var baselineLines = 0
    var actionLines = 0
    var error: String?

    /// Processes that are never useful candidates (ourselves and the log tool).
    static let ignoredProcesses: Set<String> = ["LockdownBuilder", "log", "logd"]

    mutating func add(_ line: LogLine, inAction: Bool) {
        guard !Self.ignoredProcesses.contains(line.process) else { return }
        let key = LogKey(line)
        if inAction {
            actionLines += 1
            action[key, default: Stats(count: 0, level: line.level, sample: line)].count += 1
        } else {
            baselineLines += 1
            baseline.insert(key)
        }
    }
}

struct DiscoveryCandidate: Identifiable, Equatable, Sendable {
    var predicate: String
    var process: String
    var subsystem: String?
    var fragment: String
    var sample: LogLine
    /// Lines in the action window the predicate would match.
    var actionMatches: Int
    var score: Int
    var reasons: [String]
    var warnings: [String]
    var notes: [String]

    var id: String { predicate }
}

/// Deterministic ranking: the ground truth for discovery (any AI suggestion must still pass a live test).
enum DiscoveryRanker {
    static let genericWords = [
        "launch", "activat", "foreground", "become active", "window", "scene", "terminat", "focus", "appear",
        "navigat", "recents", "suggestion",
    ]

    /// - Parameters:
    ///   - target: the app the user acts in (e.g. "System Settings").
    ///   - hint: optional words describing the action (e.g. "Internet Accounts"); lines mentioning it rank higher
    ///     and their predicate matches on it.
    static func rank(_ aggregate: DiscoveryAggregate, target: String, hint: String = "", limit: Int = 25) -> [DiscoveryCandidate] {
        let target = target.trimmingCharacters(in: .whitespaces).lowercased()
        let hintKey = LogNormalizer.compact(hint)
        var byPredicate: [String: DiscoveryCandidate] = [:]

        for (key, stats) in aggregate.action where !aggregate.baseline.contains(key) {
            let fragment = LogNormalizer.stableFragment(of: stats.sample.message, hint: hint)
            let predicate = PredicateBuilder.predicate(process: key.process, subsystem: key.subsystem, fragment: fragment)
            if byPredicate[predicate] != nil { continue }

            func matches(_ k: LogKey) -> Bool {
                k.process == key.process && k.subsystem == key.subsystem
                    && (fragment.isEmpty || k.normalizedMessage.contains(LogNormalizer.normalize(fragment)))
            }
            let actionMatches = aggregate.action.filter { matches($0.key) }.reduce(0) { $0 + $1.value.count }
            let baselineHits = aggregate.baseline.filter(matches).count

            var score = 0
            var reasons: [String] = ["Only in the action window"]
            var warnings: [String] = []
            var notes: [String] = []

            switch actionMatches {
            case 1: score += 30; reasons.append("Fires exactly once")
            case 2...3: score += 15; reasons.append("Fires \(actionMatches) times")
            case 4...10: score -= 5; warnings.append("Fires \(actionMatches) times during the action; noisy")
            default: score -= 10; warnings.append("Fires \(actionMatches) times during the action; noisy")
            }
            switch stats.level {
            case .default: score += 20; reasons.append("Default level (seen by the watcher's stream)")
            case .error, .fault: score += 10
            case .info, .debug: score -= 20; warnings.append("Info/Debug level; the watcher's stream may not see it")
            case .activity: score -= 10
            }
            if key.subsystem != nil { score += 10; reasons.append("Has a subsystem") }
            if !target.isEmpty {
                if key.process.lowercased() == target { score += 15; reasons.append("Logged by the target process") }
                else if key.process.lowercased().contains(target) || stats.sample.message.lowercased().contains(target) {
                    score += 10; reasons.append("Mentions the target")
                }
            }
            if !hintKey.isEmpty {
                let haystack = LogNormalizer.compact(key.process + " " + (key.subsystem ?? "") + " " + stats.sample.message)
                if haystack.contains(hintKey) {
                    score += 30
                    reasons.append("Mentions “\(hint.trimmingCharacters(in: .whitespaces))”")
                }
            }
            if fragment.count >= 12 { score += 10; reasons.append("Distinctive text") }
            else if fragment.count < 6 { score -= 25; warnings.append("Message text is too generic to match on") }
            if baselineHits > 0 {
                score -= 40
                warnings.append("Also matches \(baselineHits) line shape\(baselineHits == 1 ? "" : "s") from the baseline")
            }
            let lowered = stats.sample.message.lowercased()
            if genericWords.contains(where: lowered.contains), !(hintKey.isEmpty == false && LogNormalizer.compact(lowered).contains(hintKey)) {
                score -= 15
                warnings.append("Looks generic: may also fire when the app launches, gains focus or navigates (accidental clicks)")
            }
            if key.subsystem == "com.apple.extensionkit" || stats.sample.message.contains(".appex")
                || stats.sample.message.contains("Extension") {
                notes.append("Fires once per extension process load. Acceptable: the kill re-arms on relaunch.")
            }

            byPredicate[predicate] = DiscoveryCandidate(
                predicate: predicate, process: key.process, subsystem: key.subsystem, fragment: fragment,
                sample: stats.sample, actionMatches: actionMatches, score: score,
                reasons: reasons, warnings: warnings, notes: notes)
        }
        return byPredicate.values
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.predicate < $1.predicate }
            .prefix(limit)
            .map { $0 }
    }
}
