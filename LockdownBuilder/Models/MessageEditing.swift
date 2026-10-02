import Foundation

/// The editor shows the dialog's title and body as two fields; the rule still stores one `DialogMessage`
/// whose first line is `# Title`, which is what the watcher and swiftDialog expect.
enum DialogMessageParts {
    static func split(_ message: String) -> (title: String, body: String) {
        var lines = message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].hasPrefix("# ")
        else { return ("", message) }
        let title = String(lines[first].dropFirst(2)).trimmingCharacters(in: .whitespaces)
        lines.removeSubrange(...first)
        while let next = lines.first, next.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return (title, lines.joined(separator: "\n"))
    }

    static func join(title: String, body: String) -> String {
        let title = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if title.isEmpty { return body }
        return body.isEmpty ? "# \(title)" : "# \(title)\n\n\(body)"
    }
}

/// Markdown edits behind the message toolbar. Each returns the new text and what should be selected afterwards.
enum MarkdownStyling {
    typealias Edit = (text: String, selection: Range<String.Index>)

    /// Wraps the selection in `marker` (e.g. `**`), or removes the marker if the selection already has it.
    /// With nothing selected, inserts an empty pair and puts the cursor between the markers.
    static func toggleInline(_ marker: String, in text: String, range: Range<String.Index>) -> Edit {
        var range = range
        // Markdown doesn't style "**word **", so the markers hug the text, not the surrounding spaces.
        while range.lowerBound < range.upperBound, text[range.lowerBound].isWhitespace {
            range = text.index(after: range.lowerBound)..<range.upperBound
        }
        while range.lowerBound < range.upperBound, text[text.index(before: range.upperBound)].isWhitespace {
            range = range.lowerBound..<text.index(before: range.upperBound)
        }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let length = text.distance(from: range.lowerBound, to: range.upperBound)
        let selected = String(text[range])
        let before = String(text[..<range.lowerBound]), after = String(text[range.upperBound...])
        let m = marker.count

        func result(_ newText: String, _ from: Int, _ count: Int) -> Edit {
            let lower = newText.index(newText.startIndex, offsetBy: from)
            return (newText, lower..<newText.index(lower, offsetBy: count))
        }

        if length >= 2 * m, selected.hasPrefix(marker), selected.hasSuffix(marker) {
            // The markers are inside the selection.
            let inner = String(selected.dropFirst(m).dropLast(m))
            return result(before + inner + after, start, inner.count)
        }
        if before.hasSuffix(marker), after.hasPrefix(marker) {
            // The markers are just outside the selection.
            return result(String(before.dropLast(m)) + selected + String(after.dropFirst(m)), start - m, length)
        }
        return result(before + marker + selected + marker + after, start + m, length)
    }

    /// Adds `prefix` (e.g. `- `) to every line the selection touches, or removes it if they all have it.
    static func toggleLinePrefix(_ prefix: String, in text: String, range: Range<String.Index>) -> Edit {
        let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
        let lines = text[lineStart..<lineEnd].components(separatedBy: "\n")
        let allPrefixed = lines.allSatisfy { $0.hasPrefix(prefix) }
        let changed = lines.map { allPrefixed ? String($0.dropFirst(prefix.count)) : prefix + $0 }.joined(separator: "\n")
        let newText = text[..<lineStart] + changed + text[lineEnd...]
        let lower = newText.index(newText.startIndex, offsetBy: text.distance(from: text.startIndex, to: lineStart))
        return (String(newText), lower..<newText.index(lower, offsetBy: changed.count))
    }

    /// Turns the selection into `[selection](https://)` and selects the address so it can be typed over.
    static func link(in text: String, range: Range<String.Index>) -> Edit {
        let label = text[range].isEmpty ? "link text" : String(text[range])
        let placeholder = "https://"
        let newText = text[..<range.lowerBound] + "[\(label)](\(placeholder))" + text[range.upperBound...]
        let offset = text.distance(from: text.startIndex, to: range.lowerBound) + label.count + 3
        let lower = newText.index(newText.startIndex, offsetBy: offset)
        return (String(newText), lower..<newText.index(lower, offsetBy: placeholder.count))
    }
}
