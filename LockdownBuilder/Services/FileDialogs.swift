import AppKit
import UniformTypeIdentifiers

/// Thin wrappers over the AppKit panels. The app is not sandboxed, so plain URLs are enough.
@MainActor
enum FileDialogs {
    static func chooseFolder(message: String, prompt: String = "Choose", startingAt: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = message
        panel.prompt = prompt
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func chooseFiles(types: [UTType], message: String, startingAt: URL? = nil) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        panel.message = message
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func saveFile(suggestedName: String, type: UTType, startingAt: URL? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = startingAt
        return panel.runModal() == .OK ? panel.url : nil
    }

    /// Returns true if the user agrees to overwrite `names`.
    static func confirmOverwrite(_ names: [String], in folder: URL) -> Bool {
        guard !names.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Replace \(names.count) existing file\(names.count == 1 ? "" : "s")?"
        alert.informativeText = "\(folder.lastPathComponent) already contains:\n" + names.prefix(8).joined(separator: "\n")
            + (names.count > 8 ? "\n…and \(names.count - 8) more" : "")
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
