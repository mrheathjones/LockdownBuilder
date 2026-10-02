import AppKit
import Observation
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case rule(UUID)
    case template(String)
}

/// A rule being edited, plus UI-only state that isn't part of the rule file.
struct RuleDraft: Identifiable, Equatable {
    let id: UUID
    var rule: RuleModel
    /// The rule type the author chose. An event rule with a still-empty predicate stores `predicate == nil`,
    /// so the choice has to be remembered separately from the data.
    var mode: RuleModel.Kind
    /// Problems found while importing (wrong types, unknown keys) that the typed model can't represent.
    var importNotes: [ValidationIssue] = []

    init(id: UUID = UUID(), rule: RuleModel, importNotes: [ValidationIssue] = []) {
        self.id = id
        self.rule = rule
        self.mode = rule.kind
        self.importNotes = importNotes
    }
}

enum ExportFormat {
    case plist, mobileconfig

    var fileExtension: String { self == .plist ? "plist" : "mobileconfig" }
    var contentType: UTType { self == .plist ? .propertyList : UTType(filenameExtension: "mobileconfig") ?? .xml }
}

@MainActor
@Observable
final class ProjectStore {
    var drafts: [RuleDraft] = []
    var selection: SidebarItem?
    private(set) var folderURL: URL?
    var settings: RuleSettings {
        didSet { persist() }
    }
    /// Shown in an alert by the main window.
    var message: String?
    /// Set by ⌘T; the rule editor presents the test harness for the selected rule.
    var isShowingTestHarness = false

    /// What is on disk, per draft, for the unsaved-changes dot and for cleaning up renamed files.
    private var savedRules: [UUID: RuleModel] = [:]
    private var savedFileNames: [UUID: String] = [:]

    private static let settingsKey = "RuleSettings.v1"
    private let defaults: UserDefaults
    let history: ExportHistory

    init(defaults: UserDefaults = .standard, history: ExportHistory = .standard) {
        self.defaults = defaults
        self.history = history
        if let data = defaults.data(forKey: Self.settingsKey),
           let stored = try? JSONDecoder().decode(RuleSettings.self, from: data) {
            settings = stored
        } else {
            settings = RuleSettings()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private var startingFolder: URL? {
        if let folderURL { return folderURL }
        return settings.defaultOutputFolder.isEmpty ? nil : URL(fileURLWithPath: settings.defaultOutputFolder, isDirectory: true)
    }

    // MARK: Lookup and validation

    func draft(id: UUID) -> RuleDraft? { drafts.first { $0.id == id } }

    func issues(for draft: RuleDraft) -> [ValidationIssue] {
        var out = draft.rule.validate()
        switch draft.mode {
        case .event where draft.rule.predicate == nil:
            out.append(ValidationIssue(field: .predicate, severity: .error, code: .emptyString,
                                       message: "Enter the log predicate for this event rule."))
        case .watchOneKillAnother where draft.rule.watchProcess == nil:
            out.append(ValidationIssue(field: .watchProcess, severity: .error, code: .emptyString,
                                       message: "Enter the process to watch."))
        default: break
        }
        if let collision = RuleModel.collisionIssues(among: drafts.map(\.rule.name))[draft.rule.name] {
            out.append(collision)
        }
        return out
    }

    func hasErrors(_ draft: RuleDraft) -> Bool { issues(for: draft).contains(where: \.isError) }

    func isDirty(_ draft: RuleDraft) -> Bool { savedRules[draft.id] != draft.rule }

    /// A name that is safe to use in a file name. Anything else is never written to disk.
    private func hasSafeName(_ rule: RuleModel) -> Bool {
        !rule.validate().contains { $0.code == .nameNotKebabCase || $0.code == .nameEmpty }
    }

    // MARK: Editing

    @discardableResult
    func newRule(from rule: RuleModel? = nil) -> UUID {
        var base = rule ?? RuleModel(name: "new-rule", killProcess: "", dialogMessage: "# Title\n\nMessage for the user.")
        let taken = Set(drafts.map { $0.rule.name.lowercased() })
        var candidate = base.name, n = 2
        while taken.contains(candidate) { candidate = "\(base.name)-\(n)"; n += 1 }
        base.name = candidate
        let draft = RuleDraft(rule: base)
        drafts.append(draft)
        selection = .rule(draft.id)
        return draft.id
    }

    func duplicateTemplate(id: String) {
        guard let template = BuiltInTemplates.template(id: id) else { return }
        newRule(from: template.rule(settings: settings))
    }

    func delete(id: UUID) {
        drafts.removeAll { $0.id == id }
        if selection == .rule(id) { selection = drafts.first.map { .rule($0.id) } }
        // The file on disk (if any) is left alone until the next save, which moves it to the Trash.
        pendingDeletions.append(contentsOf: savedFileNames[id].map { [$0] } ?? [])
        savedFileNames[id] = nil
        savedRules[id] = nil
    }

    private var pendingDeletions: [String] = []

    // MARK: Project folder

    func openFolder() {
        guard let url = FileDialogs.chooseFolder(
            message: "Choose a folder of rule plists.", prompt: "Open", startingAt: startingFolder)
        else { return }
        loadFolder(url)
    }

    func loadFolder(_ url: URL) {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { $0.hasSuffix(".plist") }.sorted()
        var loaded: [RuleDraft] = []
        var skipped: [String] = []
        var newSaved: [UUID: RuleModel] = [:], newNames: [UUID: String] = [:]
        for file in names {
            guard let name = settings.ruleName(fromFileName: file),
                  let data = try? Data(contentsOf: url.appendingPathComponent(file))
            else { skipped.append(file); continue }
            let result = RuleImporter.importRule(data: data, name: name)
            guard let rule = result.rule else { skipped.append(file); continue }
            let notes = result.issues.filter { $0.code == .wrongType || $0.code == .unknownKey || $0.code == .plistUnreadable }
            let draft = RuleDraft(rule: rule, importNotes: notes)
            loaded.append(draft)
            newSaved[draft.id] = rule
            newNames[draft.id] = file
        }
        folderURL = url
        drafts = loaded
        savedRules = newSaved
        savedFileNames = newNames
        pendingDeletions = []
        selection = loaded.first.map { .rule($0.id) }
        if !skipped.isEmpty {
            message = "Skipped \(skipped.count) file\(skipped.count == 1 ? "" : "s") that don't match \(settings.orgPlistDomain).\(settings.preference).<rule-name>.plist:\n"
                + skipped.prefix(6).joined(separator: "\n")
        }
    }

    func importPlists() {
        let urls = FileDialogs.chooseFiles(
            types: [.propertyList], message: "Choose rule plists to import and validate.", startingAt: startingFolder)
        var lastID: UUID?
        for url in urls {
            let fileName = url.lastPathComponent
            let name = settings.ruleName(fromFileName: fileName) ?? url.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: url) else {
                message = "Couldn't read \(fileName)."
                continue
            }
            let result = RuleImporter.importRule(data: data, name: name)
            guard let rule = result.rule else {
                message = "\(fileName) isn't a rule plist: \(result.issues.first?.message ?? "unreadable")"
                continue
            }
            let notes = result.issues.filter { $0.code == .wrongType || $0.code == .unknownKey }
            // The file's own name is kept so validation can flag it; collisions with existing drafts are flagged too.
            let draft = RuleDraft(rule: rule, importNotes: notes)
            drafts.append(draft)
            lastID = draft.id
        }
        if let lastID { selection = .rule(lastID) }
    }

    func save() {
        guard let folder = folderURL ?? FileDialogs.chooseFolder(
            message: "Choose a folder to save the rule plists in.", prompt: "Save Here", startingAt: startingFolder)
        else { return }
        folderURL = folder
        let fm = FileManager.default
        var written = 0
        var unsaved: [String] = []

        for draft in drafts {
            guard hasSafeName(draft.rule) else { unsaved.append(draft.rule.name.isEmpty ? "(unnamed)" : draft.rule.name); continue }
            let fileName = settings.fileName(for: draft.rule.name)
            do {
                try Data(RuleExport.plist(for: draft.rule).utf8).write(to: folder.appendingPathComponent(fileName), options: .atomic)
                if let old = savedFileNames[draft.id], old != fileName, old.lowercased() != fileName.lowercased() {
                    pendingDeletions.append(old)
                }
                savedFileNames[draft.id] = fileName
                savedRules[draft.id] = draft.rule
                written += 1
            } catch {
                message = "Couldn't save \(fileName): \(error.localizedDescription)"
                return
            }
        }
        // Renamed or deleted rules: move their old files to the Trash (recoverable) rather than deleting.
        let stillUsed = Set(savedFileNames.values.map { $0.lowercased() })
        for old in pendingDeletions where !stillUsed.contains(old.lowercased()) {
            try? fm.trashItem(at: folder.appendingPathComponent(old), resultingItemURL: nil)
        }
        pendingDeletions = []
        if !unsaved.isEmpty {
            message = "Not saved because the name isn't valid kebab-case: \(unsaved.joined(separator: ", ")). Fix the name and save again."
        }
    }

    // MARK: Export

    /// Rules that can be exported, plus the names of those that can't.
    private func exportable() -> (ok: [RuleDraft], blocked: [String]) {
        (drafts.filter { !hasErrors($0) }, drafts.filter { hasErrors($0) }.map(\.rule.name))
    }

    func text(for rule: RuleModel, format: ExportFormat) -> String {
        switch format {
        case .plist: RuleExport.plist(for: rule)
        case .mobileconfig: RuleExport.mobileconfig(for: rule, settings: settings)
        }
    }

    func fileName(for rule: RuleModel, format: ExportFormat) -> String {
        "\(settings.ruleDomain(for: rule.name)).\(format.fileExtension)"
    }

    func export(_ draft: RuleDraft, format: ExportFormat) {
        guard !hasErrors(draft) else {
            message = "Fix the errors in “\(draft.rule.name)” before exporting."
            return
        }
        guard let url = FileDialogs.saveFile(
            suggestedName: fileName(for: draft.rule, format: format), type: format.contentType, startingAt: startingFolder)
        else { return }
        let text = text(for: draft.rule, format: format)
        if write(text, to: url) { history.record(text, fileName: fileName(for: draft.rule, format: format)) }
    }

    func exportAll(format: ExportFormat) {
        let (ok, blocked) = exportable()
        guard !ok.isEmpty else {
            message = drafts.isEmpty ? "There are no rules to export." : "No rule is valid yet. Fix the errors first."
            return
        }
        guard let folder = FileDialogs.chooseFolder(
            message: "Choose a folder for the exported .\(format.fileExtension) files.", prompt: "Export", startingAt: startingFolder)
        else { return }
        let existing = ok.map { fileName(for: $0.rule, format: format) }
            .filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        guard FileDialogs.confirmOverwrite(existing, in: folder) else { return }
        for draft in ok {
            let name = fileName(for: draft.rule, format: format)
            let text = text(for: draft.rule, format: format)
            if write(text, to: folder.appendingPathComponent(name)) { history.record(text, fileName: name) }
        }
        message = "Exported \(ok.count) file\(ok.count == 1 ? "" : "s") to \(folder.lastPathComponent)."
            + (blocked.isEmpty ? "" : "\nSkipped rules with errors: \(blocked.joined(separator: ", "))")
    }

    func exportSchema() {
        guard let url = FileDialogs.saveFile(
            suggestedName: "restricted-item-rule.schema.json", type: .json, startingAt: startingFolder)
        else { return }
        write(RuleExport.jsonSchema(settings: settings), to: url)
    }

    /// The plist text from the last time this rule was exported, if any.
    func lastExportedPlist(for draft: RuleDraft) -> String? {
        history.lastExport(fileName: fileName(for: draft.rule, format: .plist))
    }

    @discardableResult
    private func write(_ text: String, to url: URL) -> Bool {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            return true
        } catch {
            message = "Couldn't write \(url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }
}
