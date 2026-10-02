import Foundation

/// Everything the app needs to come back exactly as it was left: the rules being edited (saved to a folder or
/// not), what is on disk for each of them, the open folder and the selected rule.
///
/// The folder of plists stays the deployable copy; this is the app's own working copy, so closing, updating or
/// reinstalling the app never loses a rule.
struct Workspace: Equatable, Codable, Sendable {
    struct Draft: Equatable, Codable, Sendable {
        var id: UUID
        var rule: RuleModel
        var mode: RuleModel.Kind
        var importNotes: [ValidationIssue] = []
        /// The rule as last written to `savedFileName` in the folder, for the unsaved-changes dot.
        var savedRule: RuleModel?
        var savedFileName: String?

        init(id: UUID, rule: RuleModel, mode: RuleModel.Kind, importNotes: [ValidationIssue] = [],
             savedRule: RuleModel? = nil, savedFileName: String? = nil) {
            self.id = id
            self.rule = rule
            self.mode = mode
            self.importNotes = importNotes
            self.savedRule = savedRule
            self.savedFileName = savedFileName
        }

        /// Optional and defaulted keys may be absent.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UUID.self, forKey: .id)
            rule = try c.decode(RuleModel.self, forKey: .rule)
            mode = try c.decodeIfPresent(RuleModel.Kind.self, forKey: .mode) ?? rule.kind
            importNotes = try c.decodeIfPresent([ValidationIssue].self, forKey: .importNotes) ?? []
            savedRule = try c.decodeIfPresent(RuleModel.self, forKey: .savedRule)
            savedFileName = try c.decodeIfPresent(String.self, forKey: .savedFileName)
        }
    }

    static let currentVersion = 1

    var version = Workspace.currentVersion
    var folderPath: String?
    var drafts: [Draft] = []
    /// Files to move to the Trash on the next save (rules renamed or deleted since).
    var pendingDeletions: [String] = []
    var selectedRuleID: UUID?

    init() {}

    /// Tolerates files written by older versions that lack newer keys.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Workspace.currentVersion
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        drafts = try c.decodeIfPresent([Draft].self, forKey: .drafts) ?? []
        pendingDeletions = try c.decodeIfPresent([String].self, forKey: .pendingDeletions) ?? []
        selectedRuleID = try c.decodeIfPresent(UUID.self, forKey: .selectedRuleID)
    }
}

/// Where the workspace is kept: one JSON file under Application Support. Nothing leaves the Mac.
struct WorkspaceFile: Sendable {
    let fileURL: URL

    /// `~/Library/Application Support/<bundle id>/Workspace.json`, next to the export history.
    static var standard: WorkspaceFile {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return WorkspaceFile(fileURL: base
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "LockdownBuilder", isDirectory: true)
            .appendingPathComponent("Workspace.json"))
    }

    /// The saved workspace, or nil when there is none yet or the file can't be read.
    func load() -> Workspace? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Workspace.self, from: data)
    }

    func save(_ workspace: Workspace) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(workspace).write(to: fileURL, options: .atomic)
    }
}
