import Foundation
import Testing
@testable import LockdownBuilder

struct DialogWindowTests {
    private var custom: RuleModel {
        var rule = TestSupport.validRule()
        rule.dialogWidth = 640
        rule.dialogHeight = 360
        rule.dialogPosition = .topRight
        rule.dialogOnTop = false
        rule.dialogMoveable = false
        rule.dialogBlurScreen = true
        return rule
    }

    @Test func aRuleWithoutWindowOptionsExportsAndRunsExactlyAsBefore() {
        let rule = TestSupport.validRule()
        #expect(Set(RuleExport.plistDictionary(for: rule).keys) == ["KillProcess", "DialogMessage"])
        let args = DialogCommand.arguments(for: rule, settings: RuleSettings())
        #expect(args.contains("--ontop") && args.contains("--moveable"))
        #expect(!args.contains { ["--width", "--position", "--blurscreen"].contains($0) })
    }

    @Test func windowOptionsBecomeSwiftDialogFlags() {
        let args = DialogCommand.arguments(for: custom, settings: RuleSettings())
        #expect(Array(args.prefix(2)) == ["--height", "360"])
        #expect(Array(args[6..<10]) == ["--width", "640", "--position", "topright"])
        #expect(args.contains("--blurscreen"))
        #expect(!args.contains("--ontop") && !args.contains("--moveable"))
    }

    @Test func windowOptionsRoundTripThroughThePlistWithTheirTypes() throws {
        let text = RuleExport.plist(for: custom)
        #expect(try TestSupport.lint(text).status == 0)
        #expect(try TestSupport.canonicalXML(text) == text)
        #expect(text.contains("<key>DialogWidth</key>\n\t<integer>640</integer>"))
        #expect(text.contains("<key>DialogOnTop</key>\n\t<false/>"))
        let result = RuleImporter.importRule(data: Data(text.utf8), name: custom.name)
        #expect(result.rule == custom)
        #expect(result.isValid)
    }

    @Test func wrongTypesAndUnknownPositionsAreReported() throws {
        let plist: [String: Any] = [
            "KillProcess": "X", "DialogMessage": "m",
            "DialogWidth": "wide", "DialogOnTop": 1, "DialogPosition": "middle",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let result = RuleImporter.importRule(data: data, name: "x")
        #expect(Set(result.issues.map(\.id)) == ["DialogWidth/wrongType", "DialogOnTop/wrongType", "DialogPosition/dialogPositionUnknown"])
        #expect(result.rule?.dialogWidth == nil && result.rule?.dialogOnTop == nil && result.rule?.dialogPosition == nil)
    }

    @Test func tinySizesAreErrors() {
        var rule = TestSupport.validRule()
        rule.dialogWidth = 50; rule.dialogHeight = 0
        #expect(Set(rule.errors.map(\.field)) == [.dialogWidth, .dialogHeight])
        rule.dialogWidth = 200; rule.dialogHeight = 200
        #expect(rule.isValid)
    }

    @Test func changingAWindowOptionRelaunchesTheLivePreview() {
        let base = TestSupport.validRule(), settings = RuleSettings()
        var moved = base; moved.dialogPosition = .bottom
        #expect(DialogLiveUpdate.needsRelaunch(from: base, to: moved, oldSettings: settings, newSettings: settings))
        var explicitDefault = base; explicitDefault.dialogOnTop = false
        #expect(DialogLiveUpdate.needsRelaunch(from: base, to: explicitDefault, oldSettings: settings, newSettings: settings))
        var reworded = base; reworded.dialogMessage = "# Other"
        #expect(!DialogLiveUpdate.needsRelaunch(from: base, to: reworded, oldSettings: settings, newSettings: settings))
    }

    @Test func theSchemaAllowsTheSamePositionsAsTheModel() throws {
        let object = try #require(JSONSerialization.jsonObject(with: Data(RuleExport.jsonSchema(settings: RuleSettings()).utf8)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let positions = try #require((properties["DialogPosition"] as? [String: Any])?["enum"] as? [String])
        #expect(positions == RuleModel.DialogPosition.allCases.map(\.rawValue))
        #expect((properties["DialogOnTop"] as? [String: Any])?["type"] as? String == "boolean")
    }
}
