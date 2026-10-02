import AppKit
import Foundation
import Testing
@testable import LockdownBuilder

@MainActor
struct ProjectStoreTests {
    private let store: ProjectStore
    private let folder: URL
    private let defaults: UserDefaults
    /// Every store in a test gets its own workspace file, never the user's real one.
    private let workspaceFile: WorkspaceFile

    init() throws {
        let suite = "ProjectStoreTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        workspaceFile = WorkspaceFile(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suite).workspace", isDirectory: true).appendingPathComponent("Workspace.json"))
        store = ProjectStore(defaults: defaults, workspace: workspaceFile)
    }

    /// A store started from the same settings and workspace file, as if the app had been quit and reopened.
    private func relaunch() -> ProjectStore {
        store.flushWorkspace()
        return ProjectStore(defaults: defaults, workspace: workspaceFile)
    }

    private func copySamples() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: TestSupport.samplesDirectory.path) {
            try FileManager.default.copyItem(
                at: TestSupport.samplesDirectory.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
    }

    @Test func presetsPersistWithTheSettingsAndManagePresetsOpensTheDialogTab() throws {
        let suite = "ProjectStoreTests.presets.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = ProjectStore(defaults: defaults, workspace: workspaceFile)
        first.settings.dialogPresets.append(DialogPreset(name: "Mine", message: "# Hi {{appName}}"))
        first.settings.dialogPresets.removeAll { $0.id == DialogPreset.appBlocked.id }
        let second = ProjectStore(defaults: defaults, workspace: workspaceFile)
        #expect(second.settings.dialogPresets == first.settings.dialogPresets)
        #expect(second.settings.missingBuiltInPresets == [DialogPreset.appBlocked])
        #expect(second.settingsTab == .general)
        second.showSettings(.dialog)
        #expect(second.selection == .settings)
        #expect(second.settingsTab == .dialog)
    }

    @Test func loadsAFolderOfRulePlistsAndSkipsOthers() throws {
        try copySamples()
        store.loadFolder(folder)
        #expect(store.drafts.map(\.rule.name).sorted() == BuiltInTemplates.all.map(\.id).sorted())
        #expect(store.drafts.allSatisfy { !store.isDirty($0) && !store.hasErrors($0) })
        #expect(store.message == nil)   // only .plist files are considered, so the schema .json is not "skipped"
        let accounts = try #require(store.drafts.first { $0.rule.name == "apple-account" })
        #expect(accounts.mode == .event)
    }

    @Test func savesEditsBackAsCanonicalPlists() throws {
        try copySamples()
        store.loadFolder(folder)
        let index = try #require(store.drafts.firstIndex { $0.rule.name == "fm" })
        store.drafts[index].rule.cooldownSeconds = 30
        #expect(store.isDirty(store.drafts[index]))
        store.save()
        #expect(!store.isDirty(store.drafts[index]))
        let data = try Data(contentsOf: folder.appendingPathComponent("com.company.restrict.fm.plist"))
        #expect(String(decoding: data, as: UTF8.self) == RuleExport.plist(for: store.drafts[index].rule))
    }

    @Test func neverWritesAFileForAnUnsafeName() throws {
        store.loadFolder(folder)
        let id = store.newRule(from: RuleModel(name: "../escape", killProcess: "X", dialogMessage: "m"))
        store.save()
        #expect(store.message?.contains("../escape") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        #expect(store.draft(id: id).map(store.hasErrors) == true)
    }

    @Test func newRulesGetUniqueNames() {
        store.newRule(); store.newRule(); store.newRule()
        #expect(store.drafts.map(\.rule.name) == ["new-rule", "new-rule-2", "new-rule-3"])
    }

    @Test func duplicatingATemplateCopiesItAndSelectsIt() throws {
        store.duplicateTemplate(id: "app-store")
        store.duplicateTemplate(id: "app-store")
        #expect(store.drafts.map(\.rule.name) == ["app-store", "app-store-2"])
        #expect(store.selection == .rule(try #require(store.drafts.last).id))
    }

    @Test func caseOnlyNameCollisionsAreErrors() throws {
        store.newRule(from: RuleModel(name: "same", killProcess: "A", dialogMessage: "m"))
        let id = store.newRule(from: RuleModel(name: "x", killProcess: "B", dialogMessage: "m"))
        let index = try #require(store.drafts.firstIndex { $0.id == id })
        store.drafts[index].rule.name = "same"
        #expect(store.issues(for: store.drafts[index]).contains { $0.code == .nameCollision })
    }

    @Test func eventModeRequiresAPredicateEvenBeforeOneIsTyped() throws {
        let id = store.newRule(from: TestSupport.validRule())
        let index = try #require(store.drafts.firstIndex { $0.id == id })
        #expect(!store.hasErrors(store.drafts[index]))
        store.drafts[index].mode = .event
        #expect(store.issues(for: store.drafts[index]).contains { $0.field == .predicate && $0.isError })
        store.drafts[index].mode = .watchOneKillAnother
        #expect(store.issues(for: store.drafts[index]).contains { $0.field == .watchProcess && $0.isError })
    }

    @Test func notifyOnlyModeNeedsAPredicateAndNoKillProcess() throws {
        let id = store.newRule()
        let index = try #require(store.drafts.firstIndex { $0.id == id })
        store.drafts[index].mode = .notifyOnly
        // Only the predicate is asked for; KillProcess is not part of this rule type.
        #expect(store.issues(for: store.drafts[index]).map(\.field) == [.predicate])
        store.drafts[index].rule.predicate = #"process == "X""#
        #expect(!store.hasErrors(store.drafts[index]))
        // The same data under "Event" is missing its process to quit.
        store.drafts[index].mode = .event
        #expect(store.issues(for: store.drafts[index]).map(\.field) == [.killProcess])
    }

    @Test func aDuplicatedNotifyOnlyTemplateOpensInNotifyOnlyMode() throws {
        store.duplicateTemplate(id: "usb-block")
        let draft = try #require(store.drafts.last)
        #expect(draft.mode == .notifyOnly)
        #expect(!store.hasErrors(draft))
    }

    @Test func settingsPersistPerDefaultsSuite() throws {
        let suite = "ProjectStoreTests.persist.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = ProjectStore(defaults: defaults, workspace: workspaceFile)
        first.settings.orgPlistDomain = "com.acme"
        #expect(ProjectStore(defaults: defaults, workspace: workspaceFile).settings.orgPlistDomain == "com.acme")
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: Workspace: rules survive quitting, updating and reinstalling the app

    @Test func rulesComeBackAfterARelaunchWithTheirModeAndSelection() throws {
        let id = store.newRule(from: TestSupport.validRule())
        let index = try #require(store.drafts.firstIndex { $0.id == id })
        store.drafts[index].mode = .event
        store.drafts[index].rule.predicate = #"process == "X""#
        store.newRule()
        store.selection = .rule(id)

        let relaunched = relaunch()
        #expect(relaunched.drafts == store.drafts)
        #expect(relaunched.drafts.map(\.mode) == [.event, .presence])
        #expect(relaunched.selection == .rule(id))
        #expect(relaunched.folderURL == nil)
        // Nothing was saved to a folder, so everything still shows as unsaved.
        #expect(relaunched.drafts.allSatisfy { relaunched.isDirty($0) })
    }

    @Test func theOpenFolderAndWhatIsSavedInItComeBackToo() throws {
        try copySamples()
        store.loadFolder(folder)
        let index = try #require(store.drafts.firstIndex { $0.rule.name == "fm" })
        store.drafts[index].rule.cooldownSeconds = 30

        let relaunched = relaunch()
        #expect(relaunched.folderURL?.path == folder.path)
        #expect(relaunched.drafts == store.drafts)
        #expect(relaunched.drafts.filter { relaunched.isDirty($0) }.map(\.rule.name) == ["fm"])
        // Save goes straight to the remembered folder, no dialog.
        relaunched.save()
        #expect(relaunched.drafts.allSatisfy { !relaunched.isDirty($0) })
        let data = try Data(contentsOf: folder.appendingPathComponent("com.company.restrict.fm.plist"))
        #expect(String(decoding: data, as: UTF8.self) == RuleExport.plist(for: relaunched.drafts[index].rule))
    }

    @Test func aFolderThatIsGoneIsForgottenButItsRulesAreKept() throws {
        try copySamples()
        store.loadFolder(folder)
        store.flushWorkspace()
        try FileManager.default.removeItem(at: folder)

        let relaunched = ProjectStore(defaults: defaults, workspace: workspaceFile)
        #expect(relaunched.folderURL == nil)
        #expect(relaunched.drafts == store.drafts)
        #expect(relaunched.drafts.allSatisfy { relaunched.isDirty($0) })
    }

    @Test func unsavedRuleNamesListWhatOpeningAFolderWouldLose() throws {
        #expect(store.unsavedRuleNames.isEmpty)
        try copySamples()
        store.loadFolder(folder)
        #expect(store.unsavedRuleNames.isEmpty)
        let index = try #require(store.drafts.firstIndex { $0.rule.name == "fm" })
        store.drafts[index].rule.cooldownSeconds = 30
        store.newRule(from: RuleModel(name: "", killProcess: "X", dialogMessage: "m"))
        #expect(store.unsavedRuleNames == ["fm", "(unnamed)"])
        store.save()
        #expect(store.unsavedRuleNames == ["(unnamed)"])   // an invalid name is never written, so it stays unsaved
    }

    @Test func aDeletedRuleStaysDeletedAfterARelaunch() throws {
        store.newRule(from: TestSupport.validRule())
        let gone = store.newRule()
        store.delete(id: gone)
        let relaunched = relaunch()
        #expect(relaunched.drafts.map(\.rule.name) == ["my-rule"])
    }

    @Test func editsAreWrittenOnTheirOwnShortlyAfterTheyHappen() async throws {
        store.newRule()
        #expect(workspaceFile.load() == nil)
        try await Task.sleep(for: .seconds(1))
        #expect(workspaceFile.load()?.drafts.map(\.rule.name) == ["new-rule"])
    }

    @Test func quittingWritesAPendingChangeStraightAway() throws {
        store.newRule()
        #expect(workspaceFile.load() == nil)
        // Posted on the main thread to a main-queue observer, so it runs before `post` returns.
        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        #expect(workspaceFile.load()?.drafts.map(\.rule.name) == ["new-rule"])
    }

    @Test func anUnreadableWorkspaceFileStartsEmptyRatherThanCrashing() throws {
        try FileManager.default.createDirectory(
            at: workspaceFile.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: workspaceFile.fileURL)
        let relaunched = ProjectStore(defaults: defaults, workspace: workspaceFile)
        #expect(relaunched.drafts.isEmpty)
        #expect(relaunched.selection == .home)
        #expect(relaunched.message == nil)
    }

    @Test func theWorkspaceFileToleratesMissingKeys() throws {
        let json = #"{"drafts":[{"id":"0B4E7C3A-1F7E-4C7E-9F0B-2C4B9D1E8A11","rule":{"name":"a","dialogMessage":"m"},"mode":"event"}]}"#
        let workspace = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        #expect(workspace.version == Workspace.currentVersion)
        #expect(workspace.folderPath == nil)
        #expect(workspace.selectedRuleID == nil)
        #expect(workspace.drafts.count == 1)
        #expect(workspace.drafts[0].mode == .event)
        #expect(workspace.drafts[0].importNotes.isEmpty)
        #expect(workspace.drafts[0].rule == RuleModel(name: "a", dialogMessage: "m"))
    }
}
