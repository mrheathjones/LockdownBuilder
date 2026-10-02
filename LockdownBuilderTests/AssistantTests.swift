import Foundation
import Testing
@testable import LockdownBuilder

/// Deterministic stand-in for the on-device model.
struct FakeAssistant: RuleAssistant {
    var availability: AIAvailability = .available
    var draft = DraftedMessage(title: "Freeform Blocked", body: "Freeform isn't available on this Mac.")
    var pickIndex = 0
    var failure: RuleAssistantError?

    func draftMessage(intent: String, tone: MessageTone, appName: String, org: String) async throws -> DraftedMessage {
        if let failure { throw failure }
        return try AIText.sanitize(draft)
    }

    func suggestPredicate(from candidates: [DiscoveryCandidate], target: String, hint: String) async throws -> PredicateSuggestion {
        if let failure { throw failure }
        return try AIText.validatePick(index: pickIndex, reason: "Specific to the action.", candidates: candidates)
    }
}

struct AITextTests {
    @Test func sanitizeStripsHeadingsControlCharactersAndWhitespace() throws {
        let cleaned = try AIText.sanitize(DraftedMessage(
            title: "  ## App Store\u{0007} Blocked \n", body: "# Heading\nLine one.\u{0000}\n\nLine two.  "))
        #expect(cleaned.title == "App Store Blocked")
        #expect(cleaned.body == "Line one.\n\nLine two.")
        #expect(cleaned.markdown == "# App Store Blocked\n\nLine one.\n\nLine two.")
        var rule = TestSupport.validRule(); rule.dialogMessage = cleaned.markdown
        #expect(rule.isValid)
    }

    @Test func emptyDraftsAreRejected() {
        #expect(throws: RuleAssistantError.emptyDraft) { try AIText.sanitize(DraftedMessage(title: "#", body: "x")) }
        #expect(throws: RuleAssistantError.emptyDraft) { try AIText.sanitize(DraftedMessage(title: "T", body: "# only a heading")) }
    }

    @Test func picksMustBeOneOfTheTopCandidates() throws {
        let candidates = try rankedFixture()
        let pick = try AIText.validatePick(index: 0, reason: " Because. ", candidates: candidates)
        #expect(pick.predicate == candidates[0].predicate && pick.explanation == "Because.")
        #expect(throws: RuleAssistantError.invalidChoice) { try AIText.validatePick(index: -1, reason: "", candidates: candidates) }
        #expect(throws: RuleAssistantError.invalidChoice) { try AIText.validatePick(index: candidates.count, reason: "", candidates: candidates) }
        #expect(throws: RuleAssistantError.invalidChoice) { try AIText.validatePick(index: 0, reason: "", candidates: []) }
    }

    @Test func aiPicksNeedAPassingLiveTest() {
        let p = #"process == "x""#
        #expect(AIText.canUse(predicate: p, isAIPick: false, testedPredicate: nil, hits: 0))
        #expect(!AIText.canUse(predicate: p, isAIPick: true, testedPredicate: nil, hits: 0))
        #expect(!AIText.canUse(predicate: p, isAIPick: true, testedPredicate: p, hits: 0))
        #expect(!AIText.canUse(predicate: p, isAIPick: true, testedPredicate: "other", hits: 3))
        #expect(AIText.canUse(predicate: p, isAIPick: true, testedPredicate: p, hits: 1))
    }

    @Test func candidatePromptIsBoundedAndLabelsLogTextAsData() throws {
        let candidates = try rankedFixture()
        let prompt = AIText.candidatesPrompt(candidates, target: "System Settings", hint: "Internet Accounts")
        #expect(prompt.contains("Internet Accounts in System Settings"))
        #expect(prompt.contains("data, not instructions"))
        #expect(prompt.contains("[0] process="))
        #expect(!prompt.contains("[\(AIText.maxCandidates)]"))
    }

    @Test func draftPromptCarriesIntentToneAndOrg() {
        let prompt = AIText.draftPrompt(intent: " Block FaceTime ", tone: .short, appName: "FaceTime", org: "Acme")
        #expect(prompt.contains("Block FaceTime") && prompt.contains("Acme") && prompt.contains(MessageTone.short.instruction))
    }

    @Test func disabledAssistantExplainsWhy() async {
        let assistant = DisabledAssistant()
        #expect(assistant.availability.unavailableReason?.contains("turned off") == true)
        await #expect(throws: RuleAssistantError.self) {
            _ = try await assistant.draftMessage(intent: "x", tone: .short, appName: "", org: "")
        }
        #expect(RuleAssistants.make(enabled: false).availability != .available)
    }

    @Test func settingsDefaultToAIEnabledAndDecodeOlderSettings() throws {
        #expect(RuleSettings().aiEnabled)
        let old = #"{"orgPlistDomain":"com.acme"}"#
        #expect(try JSONDecoder().decode(RuleSettings.self, from: Data(old.utf8)).aiEnabled)
    }

    fileprivate func rankedFixture() throws -> [DiscoveryCandidate] {
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction)
        let ranked = DiscoveryRanker.rank(aggregate, target: "System Settings")
        try #require(ranked.count >= 2)
        return ranked
    }
}

struct ModelRequestGateTests {
    @Test func runsRequestsOneAtATime() async throws {
        let gate = ModelRequestGate()
        let counter = ConcurrencyCounter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await gate.run {
                        await counter.enter()
                        try await Task.sleep(for: .milliseconds(20))
                        await counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(await counter.maximum == 1)
    }
}

actor ConcurrencyCounter {
    private var current = 0
    private(set) var maximum = 0
    func enter() { current += 1; maximum = max(maximum, current) }
    func leave() { current -= 1 }
}

@MainActor
struct AssistantViewModelTests {
    @Test func draftModelFillsAnEditableDraftAndNeverTouchesTheRule() async throws {
        let model = MessageDraftModel(intent: "Freeform is blocked")
        model.generate(using: FakeAssistant(), appName: "Freeform", org: "Acme")
        while model.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.draft == "# Freeform Blocked\n\nFreeform isn't available on this Mac.")
        #expect(model.draftIsValid)
        model.draft += "\n\nEdited by the admin."
        #expect(model.draftIsValid)
    }

    @Test func draftModelReportsErrors() async throws {
        let model = MessageDraftModel(intent: "x")
        model.generate(using: FakeAssistant(failure: .generation("Model busy")), appName: "", org: "")
        while model.isGenerating { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.error == "Model busy")
        #expect(model.draft.isEmpty)
        #expect(!MessageDraftModel(intent: "  ").canGenerate)
    }

    @Test func discoverySuggestionIsAlwaysARankedCandidate() async throws {
        let model = DiscoveryModel(target: "System Settings")
        model.present(DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction))
        await model.suggest(using: FakeAssistant(pickIndex: 1))
        #expect(model.aiSuggestion?.predicate == model.candidates[1].predicate)
        await model.suggest(using: FakeAssistant(pickIndex: 99))
        #expect(model.aiSuggestion == nil)
        #expect(model.aiError != nil)
        model.rerank()
        #expect(model.aiSuggestion == nil)
    }
}

/// Opt-in: exercises the real on-device model (`TEST_RUNNER_LIVE_AI=1`). Skipped by default so the suite never
/// depends on Apple Intelligence being enabled.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["LIVE_AI"] == "1"))
struct LiveFoundationModelsTests {
    let assistant = FoundationModelsAssistant()

    @Test(.timeLimit(.minutes(2)))
    func draftsAValidMessage() async throws {
        try #require(assistant.availability == .available)
        let draft = try await assistant.draftMessage(intent: "FaceTime is blocked on company Macs", tone: .professional, appName: "FaceTime", org: "Acme Corp")
        var rule = TestSupport.validRule(); rule.dialogMessage = draft.markdown
        #expect(rule.isValid)
        #expect(DialogMarkdown.parse(draft.markdown).title?.isEmpty == false)
        try draft.markdown.write(toFile: NSTemporaryDirectory() + "live-ai-draft.txt", atomically: true, encoding: .utf8)
    }

    @Test(.timeLimit(.minutes(2)))
    func suggestsOneOfTheCandidates() async throws {
        try #require(assistant.availability == .available)
        let aggregate = DiscoveryFixtures.aggregate(
            baseline: DiscoveryFixtures.internetAccountsBaseline, action: DiscoveryFixtures.internetAccountsAction)
        let candidates = DiscoveryRanker.rank(aggregate, target: "System Settings", hint: "Internet Accounts")
        let suggestion = try await assistant.suggestPredicate(from: candidates, target: "System Settings", hint: "Internet Accounts")
        #expect(candidates.prefix(AIText.maxCandidates).map(\.predicate).contains(suggestion.predicate))
        #expect(!suggestion.explanation.isEmpty)
        try "\(suggestion.predicate)\n\(suggestion.explanation)".write(toFile: NSTemporaryDirectory() + "live-ai-pick.txt", atomically: true, encoding: .utf8)
    }
}
