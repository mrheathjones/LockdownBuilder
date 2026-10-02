import Foundation
import Testing
@testable import LockdownBuilder

struct PlistWriterTests {
    private let settings = RuleSettings()

    @Test func exactOutputForMinimalRule() {
        let rule = RuleModel(name: "freeform", killProcess: "Freeform", dialogMessage: "# Hi\n\nBye")
        let expected = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>DialogMessage</key>
        \t<string># Hi

        Bye</string>
        \t<key>KillProcess</key>
        \t<string>Freeform</string>
        </dict>
        </plist>

        """
        #expect(RuleExport.plist(for: rule) == expected)
    }

    @Test func cooldownIsAnIntegerAndOptionalKeysAreOmittedWhenNil() throws {
        var rule = TestSupport.validRule(); rule.cooldownSeconds = 0
        let xml = RuleExport.plist(for: rule)
        #expect(xml.contains("<key>CooldownSeconds</key>\n\t<integer>0</integer>"))
        for key in ["Predicate", "WatchProcess", "ButtonText", "ButtonAction", "DismissButtonText"] {
            #expect(!xml.contains(key))
        }
    }

    @Test func escapesXMLMetacharacters() throws {
        var rule = TestSupport.validRule()
        rule.dialogMessage = "# A & B <c>"
        rule.predicate = #"eventMessage CONTAINS "x" AND a < b"#
        let xml = RuleExport.plist(for: rule)
        #expect(xml.contains("# A &amp; B &lt;c&gt;"))
        let parsed = try #require(PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
        #expect(parsed["DialogMessage"] as? String == "# A & B <c>")
        #expect(parsed["Predicate"] as? String == rule.predicate)
    }

    @Test func roundTripsThroughTheImporter() throws {
        let rule = RuleModel(
            name: "app-store", killProcess: "App Store", dialogMessage: "# T\n\nBody & more",
            predicate: nil, watchProcess: "Other", cooldownSeconds: 12,
            buttonText: "Self Service", buttonAction: "/Applications/Self Service.app", dismissButtonText: "Done")
        let result = RuleImporter.importRule(data: Data(RuleExport.plist(for: rule).utf8), name: "app-store")
        #expect(result.rule == rule)
        #expect(result.issues.isEmpty)
    }

    @Test(arguments: BuiltInTemplates.all.map(\.id))
    func templatePlistPassesPlutilLintAndIsCanonical(id: String) throws {
        let rule = try #require(BuiltInTemplates.template(id: id)).rule(settings: settings)
        let xml = RuleExport.plist(for: rule)
        let lint = try TestSupport.lint(xml)
        #expect(lint.status == 0, "\(lint.output)")
        // Re-serialising with plutil must be a no-op, so Jamf/admin tools never introduce diffs.
        #expect(try TestSupport.canonicalXML(xml) == xml)
    }

    @Test func builtInTemplatesAreValidAndMatchTheirIds() {
        #expect(BuiltInTemplates.all.map(\.id) == ["apple-account", "internet-accounts", "freeform", "facetime", "phone", "app-store", "fm"])
        for template in BuiltInTemplates.all {
            let rule = template.rule(settings: settings)
            #expect(rule.name == template.id)
            #expect(rule.validate().isEmpty, "\(template.id): \(rule.validate())")
            #expect(!template.notes.isEmpty)
        }
    }

    @Test func templatesCarryTheDocumentedPredicatesAndButtons() throws {
        let account = BuiltInTemplates.appleAccount.rule(settings: settings)
        #expect(account.killProcess == "System Settings")
        #expect(account.predicate == #"process == "AppleIDSettings" AND subsystem == "com.apple.inputmethodkitClient" AND eventMessage CONTAINS "IMKClient subclass""#)
        let internet = BuiltInTemplates.internetAccounts.rule(settings: settings)
        #expect(internet.predicate == #"process == "System Settings" AND subsystem == "com.apple.extensionkit" AND eventMessage CONTAINS "InternetAccountsSettingsExtension""#)
        let store = BuiltInTemplates.appStore.rule(settings: settings)
        #expect(store.buttonText == "Self Service")
        #expect(store.buttonAction == "/Applications/Self Service.app")
        #expect(store.dismissButtonText == "Done")
        #expect(BuiltInTemplates.fm.rule(settings: settings).killProcess == "fm")
    }

    @Test func templatesUseTheConfiguredOrganisationName() {
        var custom = settings; custom.orgNameFriendly = "Acme Corp"
        let rule = BuiltInTemplates.freeform.rule(settings: custom)
        #expect(rule.dialogMessage.contains("Acme Corp"))
    }
}

/// The checked-in `Samples/` folder is the golden output: templates must regenerate it byte-for-byte.
/// Run with `UPDATE_SAMPLES=1` to rewrite it after an intentional change.
struct GoldenSamplesTests {
    private let settings = RuleSettings()
    private var updating: Bool { ProcessInfo.processInfo.environment["UPDATE_SAMPLES"] == "1" }

    private func check(_ expected: String, fileName: String) throws {
        let url = TestSupport.samplesDirectory.appendingPathComponent(fileName)
        if updating {
            try FileManager.default.createDirectory(at: TestSupport.samplesDirectory, withIntermediateDirectories: true)
            try Data(expected.utf8).write(to: url)
            return
        }
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        #expect(onDisk == expected, "\(fileName) differs from generated output; rerun with UPDATE_SAMPLES=1 if intended")
    }

    @Test(arguments: BuiltInTemplates.all.map(\.id))
    func templateMatchesGoldenFile(id: String) throws {
        let rule = try #require(BuiltInTemplates.template(id: id)).rule(settings: settings)
        try check(RuleExport.plist(for: rule), fileName: settings.fileName(for: id))
    }

    @Test func schemaMatchesGoldenFile() throws {
        try check(RuleExport.jsonSchema(settings: settings), fileName: TestSupport.schemaFileName)
    }
}

struct SchemaTests {
    @Test func schemaIsDraft04WithTheRuleKeys() throws {
        let json = RuleExport.jsonSchema(settings: RuleSettings())
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["$schema"] as? String == "http://json-schema.org/draft-04/schema#")
        #expect(object["required"] as? [String] == ["KillProcess", "DialogMessage"])
        let properties = try #require(object["properties"] as? [String: Any])
        #expect(Set(properties.keys) == RuleImporter.knownKeys)
        let cooldown = try #require(properties["CooldownSeconds"] as? [String: Any])
        #expect(cooldown["type"] as? String == "integer")
        #expect(cooldown["minimum"] as? Int == 0)
    }

    @Test func buttonActionPatternAgreesWithTheValidator() throws {
        let json = RuleExport.jsonSchema(settings: RuleSettings())
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let properties = try #require(object["properties"] as? [String: Any])
        let pattern = try #require((properties["ButtonAction"] as? [String: Any])?["pattern"] as? String)
        let regex = try NSRegularExpression(pattern: pattern)
        func matches(_ s: String) -> Bool { regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        for ok in ["/Applications/Self Service.app", "jamfselfservice://content", "https://example.com"] { #expect(matches(ok), "\(ok)") }
        for bad in ["file:///etc/hosts", "FILE://x", "relative/path", "https://"] { #expect(!matches(bad), "\(bad)") }
    }
}

struct MobileconfigTests {
    private let settings = RuleSettings()

    private func profile(_ rule: RuleModel) throws -> [String: Any] {
        let xml = RuleExport.mobileconfig(for: rule, settings: settings)
        return try #require(PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any])
    }

    @Test func structureIsOneProfileOnePayloadOneDomain() throws {
        let rule = BuiltInTemplates.appStore.rule(settings: settings)
        let p = try profile(rule)
        let domain = "com.company.restrict.app-store"
        #expect(p["PayloadType"] as? String == "Configuration")
        #expect(p["PayloadScope"] as? String == "System")
        #expect(p["PayloadIdentifier"] as? String == domain)
        #expect(p["PayloadDisplayName"] as? String == "Restrict - app-store")
        #expect(p["PayloadOrganization"] as? String == "Company Name")

        let payloads = try #require(p["PayloadContent"] as? [[String: Any]])
        #expect(payloads.count == 1)
        let payload = payloads[0]
        #expect(payload["PayloadType"] as? String == "com.apple.ManagedClient.preferences")
        let domains = try #require(payload["PayloadContent"] as? [String: Any])
        #expect(Set(domains.keys) == [domain])
        let forced = try #require((domains[domain] as? [String: Any])?["Forced"] as? [[String: Any]])
        #expect(forced.count == 1)
        let settingsDict = try #require(forced[0]["mcx_preference_settings"] as? [String: Any])
        #expect(settingsDict["KillProcess"] as? String == "App Store")
        #expect(settingsDict["DismissButtonText"] as? String == "Done")
    }

    @Test func profilePassesPlutilLintAndIsCanonical() throws {
        for template in BuiltInTemplates.all {
            let xml = RuleExport.mobileconfig(for: template.rule(settings: settings), settings: settings)
            #expect(try TestSupport.lint(xml).status == 0, "\(template.id)")
            #expect(try TestSupport.canonicalXML(xml) == xml, "\(template.id)")
        }
    }

    @Test func uuidsAreStableDistinctAndWellFormed() throws {
        let rule = TestSupport.validRule()
        let a = try profile(rule), b = try profile(rule)
        let uuid = try #require(a["PayloadUUID"] as? String)
        #expect(uuid == b["PayloadUUID"] as? String)
        #expect(UUID(uuidString: uuid) != nil)
        let inner = try #require((a["PayloadContent"] as? [[String: Any]])?.first?["PayloadUUID"] as? String)
        #expect(inner != uuid)
        var other = rule; other.name = "other-rule"
        #expect(try profile(other)["PayloadUUID"] as? String != uuid)
    }
}

struct ImporterTests {
    private func plist(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>\(body)</dict></plist>
        """.utf8)
    }

    @Test func wrongTypesAreReported() {
        let r = RuleImporter.importRule(data: plist("""
        <key>KillProcess</key><integer>5</integer>
        <key>DialogMessage</key><string>x</string>
        <key>CooldownSeconds</key><string>5</string>
        """), name: "x")
        let codes = r.issues.map(\.code)
        #expect(codes.filter { $0 == .wrongType }.count == 2)
        #expect(!r.isValid)
    }

    @Test(arguments: ["<real>2.5</real>", "<true/>", "<string>3</string>"])
    func nonIntegerCooldownIsRejected(value: String) {
        let r = RuleImporter.importRule(data: plist("""
        <key>KillProcess</key><string>A</string><key>DialogMessage</key><string>m</string>
        <key>CooldownSeconds</key>\(value)
        """), name: "x")
        #expect(r.issues.contains { $0.code == .wrongType && $0.field == .cooldownSeconds })
    }

    @Test func negativeIntegerCooldownGoesThroughValidation() {
        let r = RuleImporter.importRule(data: plist("""
        <key>KillProcess</key><string>A</string><key>DialogMessage</key><string>m</string>
        <key>CooldownSeconds</key><integer>-1</integer>
        """), name: "x")
        #expect(r.issues.map(\.code) == [.cooldownNegative])
    }

    @Test func emptyStringsAndMissingRequiredKeysAreInvalid() {
        let r = RuleImporter.importRule(data: plist("<key>ButtonText</key><string></string>"), name: "x")
        #expect(r.issues.filter { $0.code == .emptyString }.count == 3)  // Kill, Message, ButtonText
        #expect(!r.isValid)
    }

    @Test func unknownKeysWarnButStayValid() {
        let r = RuleImporter.importRule(data: plist("""
        <key>KillProcess</key><string>A</string><key>DialogMessage</key><string>m</string>
        <key>Colour</key><string>blue</string>
        """), name: "x")
        #expect(r.issues.map(\.code) == [.unknownKey])
        #expect(r.isValid)
    }

    @Test func garbageIsUnreadable() {
        let r = RuleImporter.importRule(data: Data("not a plist".utf8), name: "x")
        #expect(r.rule == nil)
        #expect(r.issues.map(\.code) == [.plistUnreadable])
    }

    @Test func importsTheCheckedInSamples() throws {
        let settings = RuleSettings()
        for template in BuiltInTemplates.all {
            let url = TestSupport.samplesDirectory.appendingPathComponent(settings.fileName(for: template.id))
            let result = RuleImporter.importRule(data: try Data(contentsOf: url), name: template.id)
            #expect(result.rule == template.rule(settings: settings))
            #expect(result.isValid)
        }
    }
}

struct SettingsTests {
    @Test func derivesDomainsFileNamesAndLabels() {
        let s = RuleSettings()
        #expect(s.ruleDomain(for: "apple-account") == "com.company.restrict.apple-account")
        #expect(s.fileName(for: "apple-account") == "com.company.restrict.apple-account.plist")
        #expect(s.watcherLabel == "com.company.restrict.watcher")
        #expect(s.profileName(for: "fm") == "Restrict - fm")
    }

    @Test func recoversRuleNameFromFileName() {
        let s = RuleSettings()
        #expect(s.ruleName(fromFileName: "com.company.restrict.fm.plist") == "fm")
        #expect(s.ruleName(fromFileName: "com.other.restrict.fm.plist") == nil)
        #expect(s.ruleName(fromFileName: "com.company.restrict..plist") == nil)
        #expect(s.ruleName(fromFileName: "com.company.restrict.fm.txt") == nil)
    }

    @Test func flagsBadSettings() {
        #expect(RuleSettings().issues.isEmpty)
        var s = RuleSettings(); s.orgPlistDomain = "company"
        #expect(s.issues.count == 1)
        s = RuleSettings(); s.preference = "Restrict Now"
        #expect(s.issues.count == 1)
        s = RuleSettings(); s.orgNameFriendly = "  "
        #expect(s.issues.count == 1)
    }
}
