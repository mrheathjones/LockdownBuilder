import Foundation
import Testing
@testable import LockdownBuilder

/// Scripts Jamf Pro's answers and records every request, so no test touches the network.
actor FakeJamfServer: HTTPTransport {
    private(set) var requests: [URLRequest] = []
    private let respond: @Sendable (URLRequest) throws -> (Int, String)

    init(respond: @escaping @Sendable (URLRequest) throws -> (Int, String)) {
        self.respond = respond
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = try respond(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }

    var summary: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path(percentEncoded: true))" } }

    static let tokenJSON = #"{"access_token":"tok-123","scope":"x","token_type":"Bearer","expires_in":1200}"#

    /// Answers the token and invalidate calls; everything else goes to `api`.
    static func withAuth(_ api: @escaping @Sendable (URLRequest) -> (Int, String)) -> FakeJamfServer {
        FakeJamfServer { request in
            switch request.url!.path {
            case "/api/oauth/token": (200, tokenJSON)
            case "/api/v1/auth/invalidate-token": (204, "")
            default: api(request)
            }
        }
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    init(_ value: String? = nil) { self.value = value }

    func read() throws -> String? { lock.withLock { value } }
    func save(_ secret: String) throws { lock.withLock { value = secret.isEmpty ? nil : secret } }
}

struct JamfConnectionTests {
    @Test func normalizesWhatAnAdminTypes() {
        #expect(JamfConnection.normalizedURL("https://company.jamfcloud.com/")?.absoluteString == "https://company.jamfcloud.com")
        #expect(JamfConnection.normalizedURL("  https://jamf.company.com:8443//  ")?.absoluteString == "https://jamf.company.com:8443")
        #expect(JamfConnection.normalizedURL("https://jamf.company.com/jss")?.absoluteString == "https://jamf.company.com/jss")
    }

    @Test(arguments: ["", "company.jamfcloud.com", "http://company.jamfcloud.com", "https://", "https://x.com?a=b",
                      "https://user:pw@x.com", "ftp://x.com"])
    func refusesAnythingThatIsNotAPlainHTTPSServer(text: String) {
        #expect(JamfConnection.normalizedURL(text) == nil)
    }
}

struct JamfClientTests {
    private let connection = JamfConnection(
        baseURL: URL(string: "https://jamf.example.com")!, clientID: "client id", clientSecret: "a&b=c d+é")

    @Test func testConnectionGetsATokenChecksProfilesAndInvalidates() async throws {
        let server = FakeJamfServer.withAuth { _ in (200, #"{"os_x_configuration_profiles":[]}"#) }
        let result = try await JamfProClient(transport: server).testConnection(connection)
        #expect(result == JamfTestResult(tokenLifetimeSeconds: 1200, canReadProfiles: true))
        #expect(await server.summary == [
            "POST /api/oauth/token",
            "GET /JSSResource/osxconfigurationprofiles",
            "POST /api/v1/auth/invalidate-token",
        ])
        let requests = await server.requests
        // OAuth client credentials, form-encoded so no character of the secret can break out of its field.
        #expect(requests[0].value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(String(decoding: requests[0].httpBody ?? Data(), as: UTF8.self)
                == "grant_type=client_credentials&client_id=client%20id&client_secret=a%26b%3Dc%20d%2B%C3%A9")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
        #expect(requests[2].value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
    }

    @Test func wrongCredentialsAreReportedAndNothingElseIsSent() async {
        let server = FakeJamfServer { _ in (401, #"{"error":"invalid_client"}"#) }
        await #expect(throws: JamfError.badCredentials) {
            try await JamfProClient(transport: server).testConnection(connection)
        }
        #expect(await server.summary == ["POST /api/oauth/token"])
    }

    @Test func aServerThatIsNotJamfIsReported() async {
        let server = FakeJamfServer { _ in (404, "<html>nope</html>") }
        await #expect(throws: JamfError.notJamf(404)) {
            try await JamfProClient(transport: server).testConnection(connection)
        }
    }

    @Test func emptyCredentialsNeverReachTheNetwork() async {
        let server = FakeJamfServer { _ in (200, "") }
        var empty = connection; empty.clientSecret = ""
        await #expect(throws: JamfError.missingCredentials) {
            try await JamfProClient(transport: server).testConnection(empty)
        }
        #expect(await server.requests.isEmpty)
    }

    @Test func validCredentialsWithoutProfileAccessAreALimitedResult() async throws {
        let server = FakeJamfServer.withAuth { _ in (403, "") }
        let result = try await JamfProClient(transport: server).testConnection(connection)
        #expect(!result.canReadProfiles)
        #expect(await server.summary.last == "POST /api/v1/auth/invalidate-token")
    }

    @Test func networkFailuresBecomeReadableErrors() async {
        let server = FakeJamfServer { _ in throw URLError(.cannotFindHost) }
        await #expect(throws: JamfError.self) {
            try await JamfProClient(transport: server).testConnection(connection)
        }
    }

    @Test func findsAProfileByExactNameWithThePathEscaped() async throws {
        let server = FakeJamfServer.withAuth { _ in
            (200, "<os_x_configuration_profile><general><id>17</id><name>x</name><category><id>3</id></category></general></os_x_configuration_profile>")
        }
        let id = try await JamfProClient(transport: server).findProfile(named: "Restrict - a/b & c?", connection)
        #expect(id == 17)
        #expect(await server.requests[1].url?.absoluteString
                == "https://jamf.example.com/JSSResource/osxconfigurationprofiles/name/Restrict%20-%20a%2Fb%20%26%20c%3F")
    }

    @Test func aMissingProfileIsNilNotAnError() async throws {
        let server = FakeJamfServer.withAuth { _ in (404, "<html><body><p>Not Found</p></body></html>") }
        #expect(try await JamfProClient(transport: server).findProfile(named: "Restrict - fm", connection) == nil)
        #expect(await server.summary.last == "POST /api/v1/auth/invalidate-token")
    }

    @Test func createPostsAnUnscopedProfileToIDZero() async throws {
        let server = FakeJamfServer.withAuth { _ in
            (201, #"<?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profile><id>42</id></os_x_configuration_profile>"#)
        }
        let config = RuleExport.mobileconfig(for: BuiltInTemplates.appStore.rule(settings: RuleSettings()), settings: RuleSettings())
        let id = try await JamfProClient(transport: server)
            .uploadProfile(name: "Restrict - app-store", mobileconfig: config, existingID: nil, connection)
        #expect(id == 42)
        #expect(await server.summary == [
            "POST /api/oauth/token",
            "POST /JSSResource/osxconfigurationprofiles/id/0",
            "POST /api/v1/auth/invalidate-token",
        ])
        let request = await server.requests[1]
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/xml")
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        #expect(body.contains("<level>computer</level>"))
        #expect(!body.contains("<scope>"))
    }

    @Test func updatePutsOnlyTheNameAndPayloadSoScopeIsKept() async throws {
        let server = FakeJamfServer.withAuth { _ in (201, "<os_x_configuration_profile><id>7</id></os_x_configuration_profile>") }
        let id = try await JamfProClient(transport: server)
            .uploadProfile(name: "Restrict - fm", mobileconfig: "<plist/>", existingID: 7, connection)
        #expect(id == 7)
        #expect(await server.summary[1] == "PUT /JSSResource/osxconfigurationprofiles/id/7")
        let body = String(decoding: await server.requests[1].httpBody ?? Data(), as: UTF8.self)
        #expect(body == #"<?xml version="1.0" encoding="UTF-8"?><os_x_configuration_profile><general><name>Restrict - fm</name><payloads>&lt;plist/&gt;</payloads></general></os_x_configuration_profile>"#)
    }

    @Test func aRefusedUploadReportsJamfsReasonAndStillInvalidatesTheToken() async {
        let server = FakeJamfServer.withAuth { _ in
            (409, "<html><head><title>Status page</title></head><body><h3>Conflict</h3><p>Error: Duplicate name</p><p>You can get technical details <a href=\"x\">here</a>.</p></body></html>")
        }
        await #expect(throws: JamfError.http(status: 409, detail: "Error: Duplicate name")) {
            try await JamfProClient(transport: server).uploadProfile(name: "x", mobileconfig: "<plist/>", existingID: nil, connection)
        }
        #expect(await server.summary.last == "POST /api/v1/auth/invalidate-token")
    }

    @Test func missingPrivilegesAreNamed() async {
        let server = FakeJamfServer.withAuth { _ in (401, "") }
        await #expect(throws: JamfError.forbidden("create configuration profiles")) {
            try await JamfProClient(transport: server).uploadProfile(name: "x", mobileconfig: "<plist/>", existingID: nil, connection)
        }
    }

    @Test func theProfileSurvivesBeingEmbeddedInTheClassicAPIBody() throws {
        var rule = BuiltInTemplates.appleAccount.rule(settings: RuleSettings())
        rule.dialogMessage = "# A & B <blocked>\n\n\"Quotes\" and ]]> too."
        let config = RuleExport.mobileconfig(for: rule, settings: RuleSettings())
        let body = JamfProClient.profileXML(name: "Restrict - R&D <1>", mobileconfig: config, isNew: true)
        let document = try XMLDocument(xmlString: body)
        #expect(try document.nodes(forXPath: "/os_x_configuration_profile/general/name").first?.stringValue == "Restrict - R&D <1>")
        #expect(try document.nodes(forXPath: "/os_x_configuration_profile/general/payloads").first?.stringValue == config)
    }
}

struct FakeJamfAPI: JamfAPI {
    var existingID: Int?
    var uploads = Uploads()

    func findScript(named name: String, _ connection: JamfConnection) async throws -> Int? { existingID }

    func uploadScript(name: String, contents: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int {
        uploads.add((name, contents, existingID, connection))
        return existingID ?? 77
    }

    final class Uploads: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(name: String, mobileconfig: String, existingID: Int?, connection: JamfConnection)] = []
        func add(_ item: (String, String, Int?, JamfConnection)) { lock.withLock { items.append(item) } }
        var all: [(name: String, mobileconfig: String, existingID: Int?, connection: JamfConnection)] { lock.withLock { items } }
    }

    func testConnection(_ connection: JamfConnection) async throws -> JamfTestResult {
        guard connection.clientSecret == "right" else { throw JamfError.badCredentials }
        return JamfTestResult(tokenLifetimeSeconds: 60, canReadProfiles: connection.clientID != "limited")
    }

    func findProfile(named name: String, _ connection: JamfConnection) async throws -> Int? { existingID }

    func uploadProfile(name: String, mobileconfig: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int {
        uploads.add((name, mobileconfig, existingID, connection))
        return existingID ?? 99
    }
}

@MainActor
struct JamfPublishModelTests {
    private let rule = BuiltInTemplates.freeform.rule(settings: RuleSettings())
    private var settings: RuleSettings {
        var s = RuleSettings(); s.jamfURL = "https://jamf.example.com/"; s.jamfClientID = "abc"
        return s
    }

    @Test func nothingIsUploadedBeforeTheCheck() async {
        let api = FakeJamfAPI()
        let model = JamfPublishModel(rule: rule, name: "Restrict - freeform", api: api, secrets: MemorySecretStore("s"))
        await model.publish(settings: settings)
        #expect(model.state == .idle)
        #expect(api.uploads.all.isEmpty)
    }

    @Test func createsWhenNoProfileHasTheName() async throws {
        let api = FakeJamfAPI()
        let model = JamfPublishModel(rule: rule, name: " Block Freeform ", api: api, secrets: MemorySecretStore("s"))
        await model.check(settings: settings)
        #expect(model.state == .ready(existingID: nil))
        var named = settings; named.profileNames[rule.name] = model.trimmedName
        await model.publish(settings: named)
        #expect(model.state == .done(id: 99, created: true))
        let upload = try #require(api.uploads.all.first)
        #expect(upload.name == "Block Freeform")
        #expect(upload.existingID == nil)
        #expect(upload.connection == JamfConnection(baseURL: URL(string: "https://jamf.example.com")!, clientID: "abc", clientSecret: "s"))
        // The payload carries the same name Jamf shows.
        #expect(upload.mobileconfig.contains("<string>Block Freeform</string>"))
        #expect(try TestSupport.lint(upload.mobileconfig).status == 0)
    }

    @Test func updatesTheProfileTheCheckFound() async {
        let api = FakeJamfAPI(existingID: 12)
        let model = JamfPublishModel(rule: rule, name: "Restrict - freeform", api: api, secrets: MemorySecretStore("s"))
        await model.check(settings: settings)
        #expect(model.state == .ready(existingID: 12))
        await model.publish(settings: settings)
        #expect(model.state == .done(id: 12, created: false))
        #expect(api.uploads.all.first?.existingID == 12)
    }

    @Test func renamingAfterTheCheckRequiresANewCheck() async {
        let model = JamfPublishModel(rule: rule, name: "A", api: FakeJamfAPI(existingID: 12), secrets: MemorySecretStore("s"))
        await model.check(settings: settings)
        model.name = "B"
        #expect(model.state == .idle)
    }

    @Test func missingSecretOrURLFailsBeforeAnyRequest() async {
        var model = JamfPublishModel(rule: rule, name: "A", api: FakeJamfAPI(), secrets: MemorySecretStore())
        await model.check(settings: settings)
        #expect(model.state == .failed(JamfError.missingCredentials.localizedDescription))
        model = JamfPublishModel(rule: rule, name: "A", api: FakeJamfAPI(), secrets: MemorySecretStore("s"))
        await model.check(settings: RuleSettings())
        #expect(model.state == .failed(JamfError.invalidURL.localizedDescription))
    }

    @Test func anInvalidRuleIsNeverUploaded() async {
        var bad = rule; bad.killProcess = "launchd"
        let api = FakeJamfAPI()
        let model = JamfPublishModel(rule: bad, name: "A", api: api, secrets: MemorySecretStore("s"))
        await model.check(settings: settings)
        await model.publish(settings: settings)
        #expect(api.uploads.all.isEmpty)
    }
}

@MainActor
struct JamfSettingsModelTests {
    private func settle(_ model: JamfSettingsModel) async {
        for _ in 0..<200 where model.testState == .testing { await Task.yield(); try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func theSecretIsLoadedFromAndSavedToTheSecretStore() throws {
        let secrets = MemorySecretStore("stored")
        let model = JamfSettingsModel(api: FakeJamfAPI(), secrets: secrets)
        model.loadSecret()
        #expect(model.clientSecret == "stored")
        model.clientSecret = "new"
        model.saveSecret()
        #expect(try secrets.read() == "new")
        model.clientSecret = ""
        model.saveSecret()
        #expect(try secrets.read() == nil)
    }

    @Test func testReportsValidLimitedAndWrongCredentials() async {
        let model = JamfSettingsModel(api: FakeJamfAPI(), secrets: MemorySecretStore())
        model.clientSecret = "right"
        model.test(urlText: "https://jamf.example.com/", clientID: "abc")
        await settle(model)
        guard case .ok = model.testState else { Issue.record("expected ok, got \(model.testState)"); return }

        model.test(urlText: "https://jamf.example.com", clientID: "limited")
        await settle(model)
        guard case .limited = model.testState else { Issue.record("expected limited, got \(model.testState)"); return }

        model.clientSecret = "wrong"
        model.test(urlText: "https://jamf.example.com", clientID: "abc")
        await settle(model)
        #expect(model.testState == .failed(JamfError.badCredentials.localizedDescription))

        model.test(urlText: "jamf.example.com", clientID: "abc")
        #expect(model.testState == .failed(JamfError.invalidURL.localizedDescription))

        model.credentialsChanged()
        #expect(model.testState == .idle)
    }
}

struct BrandingSettingsTests {
    @Test func settingsSavedByVersionOneStillDecode() throws {
        let old = #"{"orgPlistDomain":"com.acme","preference":"restrict","orgNameFriendly":"Acme","defaultOutputFolder":"","bannerImagePath":"/b.png","aiEnabled":false}"#
        let s = try JSONDecoder().decode(RuleSettings.self, from: Data(old.utf8))
        #expect(s.orgNameFriendly == "Acme" && s.bannerImagePath == "/b.png" && !s.aiEnabled)
        #expect(s.iconPath.isEmpty && s.jamfURL.isEmpty && s.jamfClientID.isEmpty && s.profileNames.isEmpty)
    }

    @Test func settingsNeverContainTheClientSecret() throws {
        var s = RuleSettings(); s.jamfURL = "https://jamf.example.com"; s.jamfClientID = "abc"
        let keys = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]).keys
        #expect(!keys.contains { $0.lowercased().contains("secret") })
    }

    @Test func aChosenProfileNameReplacesTheDefaultInTheExport() {
        var s = RuleSettings()
        #expect(s.profileName(for: "fm") == "Restrict - fm")
        s.profileNames["fm"] = "  "
        #expect(s.profileName(for: "fm") == "Restrict - fm")
        s.profileNames["fm"] = "Block fm CLI"
        #expect(s.profileName(for: "fm") == "Block fm CLI")
        #expect(s.profileName(for: "phone") == "Restrict - phone")
        let rule = BuiltInTemplates.fm.rule(settings: s)
        #expect(RuleExport.mobileconfig(for: rule, settings: s).contains("<string>Block fm CLI</string>"))
    }

    @Test func aDisplayNameIsStoredOnlyWhenItDiffersAndFollowsARename() {
        var s = RuleSettings()
        s.setProfileName("Block the App Store", for: "app-store")
        #expect(s.profileName(for: "app-store") == "Block the App Store")
        let rule = BuiltInTemplates.appStore.rule(settings: s)
        #expect(RuleExport.mobileconfig(for: rule, settings: s).contains("<key>PayloadDisplayName</key>\n\t<string>Block the App Store</string>"))
        // The rule plist itself never carries it.
        #expect(!RuleExport.plist(for: rule).contains("Block the App Store"))

        s.moveProfileName(from: "app-store", to: "mac-app-store")
        #expect(s.profileNames == ["mac-app-store": "Block the App Store"])
        #expect(s.profileName(for: "app-store") == "Restrict - app-store")

        s.setProfileName("  ", for: "mac-app-store")
        #expect(s.profileNames.isEmpty)
        s.setProfileName("Restrict - fm", for: "fm")
        #expect(s.profileNames.isEmpty)
    }

    @Test func iconComesFromSettingsOrIsTheWatchersShield() {
        let rule = TestSupport.validRule()
        func icon(_ settings: RuleSettings) -> String {
            let args = DialogCommand.arguments(for: rule, settings: settings)
            return args[args.firstIndex(of: "--icon")! + 1]
        }
        // Without an icon in Settings the watcher shows its standard shield.
        #expect(icon(RuleSettings()) == DialogCommand.defaultIcon)
        var s = RuleSettings(); s.iconPath = "/Library/Org/icon.png"
        #expect(icon(s) == "/Library/Org/icon.png")
        #expect(DialogLiveUpdate.needsRelaunch(from: rule, to: rule, oldSettings: RuleSettings(), newSettings: s))
    }

    @Test func everyTemplateHasAnIcon() {
        #expect(BuiltInTemplates.all.allSatisfy { !$0.symbol.isEmpty })
    }
}
