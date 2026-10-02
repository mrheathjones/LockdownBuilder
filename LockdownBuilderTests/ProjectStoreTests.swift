import Foundation
import Testing
@testable import LockdownBuilder

@MainActor
struct ProjectStoreTests {
    private let store: ProjectStore
    private let folder: URL

    init() throws {
        let suite = "ProjectStoreTests.\(UUID().uuidString)"
        store = ProjectStore(defaults: try #require(UserDefaults(suiteName: suite)))
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func copySamples() throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: TestSupport.samplesDirectory.path) {
            try FileManager.default.copyItem(
                at: TestSupport.samplesDirectory.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
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
        let first = ProjectStore(defaults: defaults)
        first.settings.orgPlistDomain = "com.acme"
        #expect(ProjectStore(defaults: defaults).settings.orgPlistDomain == "com.acme")
        defaults.removePersistentDomain(forName: suite)
    }
}
