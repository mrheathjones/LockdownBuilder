import Foundation

/// A minimal property-list value tree, just enough for rule plists and .mobileconfig profiles.
enum PlistValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case bool(Bool)
    case array([PlistValue])
    case dict([String: PlistValue])
}

/// Serialises a `PlistValue` as XML1 exactly the way `plutil -convert xml1` does:
/// standard Apple DOCTYPE, tab indentation, keys sorted, `<dict/>` / `<array/>` for empties,
/// real newlines inside `<string>`, trailing newline.
///
/// Matching plutil's canonical form means Jamf (or an admin) re-serialising a file never
/// produces a diff, and `plutil -lint` always passes.
enum PlistXML {
    static func serialize(_ root: PlistValue) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">

        """
        write(root, depth: 0, into: &out)
        out += "</plist>\n"
        return out
    }

    private static func write(_ value: PlistValue, depth: Int, into out: inout String) {
        let indent = String(repeating: "\t", count: depth)
        switch value {
        case .string(let s):
            out += "\(indent)<string>\(escape(s))</string>\n"
        case .integer(let i):
            out += "\(indent)<integer>\(i)</integer>\n"
        case .bool(let b):
            out += "\(indent)<\(b ? "true" : "false")/>\n"
        case .array(let items):
            if items.isEmpty {
                out += "\(indent)<array/>\n"
                return
            }
            out += "\(indent)<array>\n"
            for item in items { write(item, depth: depth + 1, into: &out) }
            out += "\(indent)</array>\n"
        case .dict(let entries):
            if entries.isEmpty {
                out += "\(indent)<dict/>\n"
                return
            }
            out += "\(indent)<dict>\n"
            for key in entries.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }) {
                out += "\(indent)\t<key>\(escape(key))</key>\n"
                write(entries[key]!, depth: depth + 1, into: &out)
            }
            out += "\(indent)</dict>\n"
        }
    }

    /// plutil escapes only `&`, `<` and `>`.
    private static func escape(_ s: String) -> String {
        guard s.contains(where: { $0 == "&" || $0 == "<" || $0 == ">" }) else { return s }
        var r = ""
        r.reserveCapacity(s.count + 8)
        for c in s {
            switch c {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.append(c)
            }
        }
        return r
    }
}
