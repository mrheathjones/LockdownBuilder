import Foundation
import Testing
@testable import LockdownBuilder

struct DialogMessagePartsTests {
    @Test func splitsTheTitleLineFromTheBody() {
        let parts = DialogMessageParts.split("# App Store Blocked\n\nUse Self Service.\n\nThanks.")
        #expect(parts.title == "App Store Blocked")
        #expect(parts.body == "Use Self Service.\n\nThanks.")
    }

    @Test func aMessageWithoutATitleIsAllBody() {
        let parts = DialogMessageParts.split("Just text.\n\n## Not the title")
        #expect(parts.title.isEmpty)
        #expect(parts.body == "Just text.\n\n## Not the title")
    }

    @Test func joinWritesTheMarkdownTheWatcherExpects() {
        #expect(DialogMessageParts.join(title: " Blocked ", body: "Not allowed.") == "# Blocked\n\nNot allowed.")
        #expect(DialogMessageParts.join(title: "", body: "Not allowed.") == "Not allowed.")
        #expect(DialogMessageParts.join(title: "Blocked", body: "") == "# Blocked")
        #expect(DialogMessageParts.join(title: "Two\nlines", body: "x") == "# Two lines\n\nx")
    }

    @Test func insertPutsTheSnippetAtTheSelectionWithTheCursorAfterIt() {
        let text = "Policy of ."
        let at = text.index(text.startIndex, offsetBy: 10)
        let edit = MarkdownStyling.insert("{{companyName}}", in: text, range: at..<at)
        #expect(edit.text == "Policy of {{companyName}}.")
        #expect(edit.text.distance(from: edit.text.startIndex, to: edit.selection.lowerBound) == 25 && edit.selection.isEmpty)
        let replaced = MarkdownStyling.insert("{{ruleName}}", in: "abc", range: "abc".startIndex..<"abc".endIndex)
        #expect(replaced.text == "{{ruleName}}")
    }

    @Test func everyTemplateAndPresetSurvivesSplitAndJoin() {
        var messages = BuiltInTemplates.all.map { $0.rule(settings: RuleSettings()).dialogMessage }
        messages += DialogPreset.builtIn.map { $0.message(appName: "App") }
        for message in messages {
            let parts = DialogMessageParts.split(message)
            #expect(!parts.title.isEmpty)
            #expect(DialogMessageParts.join(title: parts.title, body: parts.body) == message)
        }
    }
}

struct MarkdownStylingTests {
    private func range(of part: String, in text: String) -> Range<String.Index> { text.range(of: part)! }

    @Test func boldWrapsTheSelectionAndKeepsItSelected() {
        let text = "Freeform isn't available."
        let edit = MarkdownStyling.toggleInline("**", in: text, range: range(of: "isn't", in: text))
        #expect(edit.text == "Freeform **isn't** available.")
        #expect(edit.text[edit.selection] == "isn't")
    }

    @Test func boldAgainRemovesItWhetherOrNotTheMarkersAreSelected() {
        let text = "Freeform **isn't** available."
        #expect(MarkdownStyling.toggleInline("**", in: text, range: range(of: "isn't", in: text)).text == "Freeform isn't available.")
        let withMarkers = MarkdownStyling.toggleInline("**", in: text, range: range(of: "**isn't**", in: text))
        #expect(withMarkers.text == "Freeform isn't available.")
        #expect(withMarkers.text[withMarkers.selection] == "isn't")
    }

    @Test func markersHugTheWordNotTheSpacesAroundIt() {
        let text = "one two three"
        let edit = MarkdownStyling.toggleInline("_", in: text, range: range(of: " two ", in: text))
        #expect(edit.text == "one _two_ three")
    }

    @Test func nothingSelectedInsertsAPairWithTheCursorInside() {
        let text = "abc"
        let edit = MarkdownStyling.toggleInline("**", in: text, range: text.endIndex..<text.endIndex)
        #expect(edit.text == "abc****")
        #expect(edit.selection.isEmpty)
        #expect(edit.text.distance(from: edit.text.startIndex, to: edit.selection.lowerBound) == 5)
    }

    @Test func italicInsideBoldDoesNotUndoTheBold() {
        let text = "**word**"
        let edit = MarkdownStyling.toggleInline("_", in: text, range: range(of: "word", in: text))
        #expect(edit.text == "**_word_**")
    }

    @Test func worksWithEmojiAndAccents() {
        let text = "Café 🚫 blocked"
        let edit = MarkdownStyling.toggleInline("**", in: text, range: range(of: "🚫", in: text))
        #expect(edit.text == "Café **🚫** blocked")
        #expect(edit.text[edit.selection] == "🚫")
    }

    @Test func bulletsEveryTouchedLineAndTogglesBack() {
        let text = "Intro\none\ntwo\nOutro"
        let selected = text.range(of: "ne\ntw")!
        let edit = MarkdownStyling.toggleLinePrefix("- ", in: text, range: selected)
        #expect(edit.text == "Intro\n- one\n- two\nOutro")
        #expect(edit.text[edit.selection] == "- one\n- two")
        #expect(MarkdownStyling.toggleLinePrefix("- ", in: edit.text, range: edit.selection).text == text)
    }

    @Test func linkSelectsTheAddressToTypeOver() {
        let text = "Open Self Service now"
        let edit = MarkdownStyling.link(in: text, range: range(of: "Self Service", in: text))
        #expect(edit.text == "Open [Self Service](https://) now")
        #expect(edit.text[edit.selection] == "https://")
    }

    @Test func styledTextStillPreviewsAsMarkdown() throws {
        let styled = try AttributedString(markdown: "**bold** _italic_ ~~gone~~")
        #expect(String(styled.characters) == "bold italic gone")
    }
}

struct BannerAndIconTests {
    private var branded: RuleSettings {
        var s = RuleSettings(); s.bannerImagePath = "/b.png"; s.iconPath = "/i.png"
        return s
    }

    @Test func sizesArePassedOnlyWhenSet() {
        let rule = TestSupport.validRule()
        var s = branded
        #expect(!DialogCommand.arguments(for: rule, settings: s).contains { $0 == "--bannerheight" || $0 == "--iconsize" })
        s.bannerHeight = 90; s.iconSize = 120
        let args = DialogCommand.arguments(for: rule, settings: s)
        #expect(Array(args.suffix(6)) == ["--bannerimage", "/b.png", "--title", "none", "--bannerheight", "90"])
        #expect(Array(args[6..<10]) == ["--icon", "/i.png", "--iconsize", "120"])
    }

    @Test func aRuleCanTurnTheBannerAndIconOff() {
        var rule = TestSupport.validRule()
        rule.dialogShowBanner = false
        rule.dialogShowIcon = false
        var s = branded; s.bannerHeight = 90; s.iconSize = 120
        let args = DialogCommand.arguments(for: rule, settings: s)
        #expect(Array(args.suffix(2)) == ["--title", "Company Name"])
        #expect(args[args.firstIndex(of: "--icon")! + 1] == "none")
        #expect(!DialogCommand.arguments(for: rule, settings: s).contains { ["--bannerimage", "--bannerheight", "--iconsize"].contains($0) })
        let text = RuleExport.plist(for: rule)
        #expect(text.contains("<key>DialogShowBanner</key>\n\t<false/>") && text.contains("<key>DialogShowIcon</key>\n\t<false/>"))
        #expect(RuleImporter.importRule(data: Data(text.utf8), name: rule.name).rule == rule)
    }

    @Test func resizingUpdatesTheOpenWindowInsteadOfRelaunching() {
        let base = TestSupport.validRule(), settings = RuleSettings()
        var sized = base; sized.dialogWidth = 600; sized.dialogHeight = 300
        #expect(!DialogLiveUpdate.needsRelaunch(from: base, to: sized, oldSettings: settings, newSettings: settings))
        #expect(DialogLiveUpdate.commands(from: base, to: sized, oldSettings: settings, newSettings: settings)
                == ["width: 600", "height: 300"])
        // Back to the default size.
        #expect(DialogLiveUpdate.commands(from: sized, to: base, oldSettings: settings, newSettings: settings)
                == ["width: 820", "height: 500"])
    }

    @Test func brandingChangesRelaunchTheLivePreview() {
        let base = TestSupport.validRule()
        var hidden = base; hidden.dialogShowIcon = false
        #expect(DialogLiveUpdate.needsRelaunch(from: base, to: hidden, oldSettings: branded, newSettings: branded))
        var taller = branded; taller.bannerHeight = 200
        #expect(DialogLiveUpdate.needsRelaunch(from: base, to: base, oldSettings: branded, newSettings: taller))
    }

    @Test func oldSettingsDecodeWithDefaultSizes() throws {
        let s = try JSONDecoder().decode(RuleSettings.self, from: Data(#"{"bannerImagePath":"/b.png"}"#.utf8))
        #expect(s.bannerHeight == nil && s.iconSize == nil)
    }
}
