import Foundation
import Testing
@testable import LockdownBuilder

struct WatcherInstallerTests {
    private let template: String
    private var settings: RuleSettings {
        var s = RuleSettings()
        s.orgNameFriendly = "Acme & Sons"
        s.orgPlistDomain = "com.acme"
        s.preference = "lockdown"
        s.bannerImagePath = "/Library/Application Support/Acme/banner.png"
        s.bannerHeight = 90
        s.iconPath = "/Library/Application Support/Acme/icon.png"
        s.iconSize = 120
        return s
    }

    init() throws {
        template = try String(
            contentsOf: TestSupport.repoRoot.appendingPathComponent("LockdownBuilder/Resources/\(WatcherInstaller.fileName)"),
            encoding: .utf8)
    }

    private func bashSyntaxCheck(_ script: String) throws -> TestSupport.ToolResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString).sh")
        try Data(script.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try TestSupport.run("/bin/bash", ["-n", url.path])
    }

    @Test func writesTheSettingsIntoTheInstallersOwnVariables() throws {
        let script = try WatcherInstaller.build(template: template, settings: settings)
        for line in [
            #"readonly ORG_NAME_FRIENDLY="Acme & Sons""#,
            #"readonly ORG_PLIST_DOMAIN="com.acme""#,
            #"readonly PREFERENCE="lockdown""#,
            #"readonly BANNER_IMAGE="/Library/Application Support/Acme/banner.png""#,
            #"readonly BANNER_HEIGHT="90""#,
            #"readonly DIALOG_ICON="/Library/Application Support/Acme/icon.png""#,
            #"readonly DIALOG_ICON_SIZE="120""#,
        ] {
            #expect(script.components(separatedBy: "\n").filter { $0 == line }.count == 1, "\(line)")
        }
        #expect(try bashSyntaxCheck(script).status == 0)
    }

    @Test func theAuthorIsTheAppInBothHeadersAndNoPersonIsNamed() throws {
        let script = try WatcherInstaller.build(template: template, settings: settings)
        let authors = script.components(separatedBy: "\n").filter { $0.hasPrefix("# Author:") }
        #expect(authors == ["# Author: LockdownBuilder", "# Author: LockdownBuilder"])
        #expect(try bashSyntaxCheck(script).status == 0)
    }

    @Test func changesNothingInTheEmbeddedWatcherButItsAuthorLine() throws {
        let script = try WatcherInstaller.build(template: template, settings: settings)
        let marker = "<<'WATCHER_SCRIPT_EOF'"
        let before = try #require(template.range(of: marker)), after = try #require(script.range(of: marker))
        func withoutAuthor(_ text: Substring) -> [String] {
            text.components(separatedBy: "\n").filter { !$0.hasPrefix("# Author:") }
        }
        #expect(withoutAuthor(script[after.lowerBound...]) == withoutAuthor(template[before.lowerBound...]))
        // The watcher keeps its tokens; the installer fills them in on the managed Mac.
        #expect(script.contains(#"BANNER_IMAGE="__BANNER_IMAGE__""#))
    }

    @Test func emptyOptionalValuesStayEmpty() throws {
        var s = settings; s.bannerImagePath = ""; s.bannerHeight = nil; s.iconPath = ""; s.iconSize = nil
        let script = try WatcherInstaller.build(template: template, settings: s)
        for name in ["BANNER_IMAGE", "BANNER_HEIGHT", "DIALOG_ICON", "DIALOG_ICON_SIZE"] {
            #expect(script.contains("\nreadonly \(name)=\"\"\n"))
        }
    }

    @Test func refusesTheSampleValuesTheInstallerWouldRefuseToRunWith() {
        #expect(WatcherInstaller.issues(for: RuleSettings()).count == 2)
        #expect(throws: WatcherInstaller.BuildError.self) {
            try WatcherInstaller.build(template: template, settings: RuleSettings())
        }
    }

    @Test(arguments: [#"Acme "Best""#, "Acme $HOME", "Acme `id`", #"Acme \ Co"#, "Acme\nCo", "Acme/Co"])
    func refusesValuesTheShellWouldInterpret(name: String) {
        var s = settings; s.orgNameFriendly = name
        #expect(!WatcherInstaller.issues(for: s).isEmpty)
        #expect(throws: WatcherInstaller.BuildError.self) {
            try WatcherInstaller.build(template: template, settings: s)
        }
    }

    @Test func aTemplateWithoutTheExpectedLinesIsAnErrorNotASilentNoOp() {
        let broken = template.replacingOccurrences(of: "readonly PREFERENCE=", with: "readonly PREF=")
        #expect(throws: WatcherInstaller.BuildError.templateChanged("PREFERENCE")) {
            try WatcherInstaller.build(template: broken, settings: settings)
        }
    }

    /// The bundled template is published with the app, so it carries no personal name either.
    @Test func theBundledTemplateNamesTheAppAsAuthor() {
        let authors = template.components(separatedBy: "\n").filter { $0.hasPrefix("# Author:") }
        #expect(authors == ["# Author: LockdownBuilder", "# Author: LockdownBuilder"])
    }

    @Test func readsTheInstallerVersion() {
        #expect(WatcherInstaller.version(of: template) == "1.7")
    }

    /// The embedded watcher and the app must agree on the rule keys.
    @Test func theEmbeddedWatcherReadsEveryDialogKeyTheAppWrites() {
        for key in RuleImporter.knownKeys where key.hasPrefix("Dialog") && key != "DialogMessage" {
            #expect(template.contains("\"\(key)\""), "watcher doesn't read \(key)")
        }
        #expect(template.contains("appSizeSmall=\(DialogCommand.defaultHeight)"))
        #expect(template.contains("APP_ICON=\"\(DialogCommand.defaultIcon)\""))
    }
}

struct JamfScriptTests {
    private let connection = JamfConnection(
        baseURL: URL(string: "https://jamf.example.com")!, clientID: "id", clientSecret: "secret")

    @Test func findsAScriptByExactName() async throws {
        let server = FakeJamfServer.withAuth { _ in
            (200, #"{"totalCount":2,"results":[{"id":"4","name":"Watcher Installer old"},{"id":"9","name":"Watcher Installer"}]}"#)
        }
        #expect(try await JamfProClient(transport: server).findScript(named: "Watcher Installer", connection) == 9)
        #expect(await server.requests[1].url?.absoluteString
                == "https://jamf.example.com/api/v1/scripts?page=0&page-size=100&filter=name%3D%3D%22Watcher%20Installer%22")
        #expect(await server.summary.last == "POST /api/v1/auth/invalidate-token")
    }

    @Test func noMatchIsNil() async throws {
        let server = FakeJamfServer.withAuth { _ in (200, #"{"totalCount":0,"results":[]}"#) }
        #expect(try await JamfProClient(transport: server).findScript(named: "X", connection) == nil)
    }

    @Test func createPostsTheScript() async throws {
        let server = FakeJamfServer.withAuth { _ in (201, #"{"id":"31","href":"https://jamf.example.com/api/v1/scripts/31"}"#) }
        let id = try await JamfProClient(transport: server)
            .uploadScript(name: "Watcher", contents: "#! /bin/bash\necho \"hi\"\n", existingID: nil, connection)
        #expect(id == 31)
        #expect(await server.summary == ["POST /api/oauth/token", "POST /api/v1/scripts", "POST /api/v1/auth/invalidate-token"])
        let body = try #require(JSONSerialization.jsonObject(with: await server.requests[1].httpBody ?? Data()) as? [String: Any])
        #expect(body["name"] as? String == "Watcher")
        #expect(body["scriptContents"] as? String == "#! /bin/bash\necho \"hi\"\n")
        #expect(body["priority"] as? String == "AFTER")
    }

    @Test func updateKeepsEverythingButTheContents() async throws {
        let server = FakeJamfServer.withAuth { request in
            request.httpMethod == "PUT"
                ? (200, #"{"id":"31"}"#)
                : (200, #"{"id":"31","name":"Watcher","categoryId":"5","notes":"keep me","priority":"BEFORE","parameter4":"Mode","scriptContents":"old"}"#)
        }
        let id = try await JamfProClient(transport: server)
            .uploadScript(name: "Watcher", contents: "new", existingID: 31, connection)
        #expect(id == 31)
        #expect(await server.summary == [
            "POST /api/oauth/token", "GET /api/v1/scripts/31", "PUT /api/v1/scripts/31", "POST /api/v1/auth/invalidate-token",
        ])
        let body = try #require(JSONSerialization.jsonObject(with: await server.requests[2].httpBody ?? Data()) as? [String: Any])
        #expect(body["scriptContents"] as? String == "new")
        #expect(body["categoryId"] as? String == "5")
        #expect(body["notes"] as? String == "keep me")
        #expect(body["priority"] as? String == "BEFORE")
    }

    @Test func missingScriptPrivilegeIsNamed() async {
        let server = FakeJamfServer.withAuth { _ in (403, "") }
        await #expect(throws: JamfError.forbidden("create scripts")) {
            try await JamfProClient(transport: server).uploadScript(name: "W", contents: "x", existingID: nil, connection)
        }
    }
}

@MainActor
struct WatcherUploadModelTests {
    private var settings: RuleSettings {
        var s = RuleSettings(); s.jamfURL = "https://jamf.example.com"; s.jamfClientID = "abc"
        return s
    }

    @Test func checksThenCreatesWithTheDefaultName() async throws {
        let api = FakeJamfAPI()
        let model = WatcherUploadModel(api: api, secrets: MemorySecretStore("s"))
        await model.upload(script: "x", settings: settings)
        #expect(api.uploads.all.isEmpty)   // nothing is sent before the check
        await model.check(settings: settings)
        #expect(model.state == .ready(existingID: nil))
        await model.upload(script: "the script", settings: settings)
        #expect(model.state == .done(id: 77, created: true))
        let upload = try #require(api.uploads.all.first)
        #expect(upload.name == WatcherInstaller.defaultScriptName)
        #expect(upload.mobileconfig == "the script")
    }

    @Test func updatesAnExistingScriptUnderACustomName() async {
        let api = FakeJamfAPI(existingID: 5)
        let model = WatcherUploadModel(api: api, secrets: MemorySecretStore("s"))
        var named = settings; named.watcherScriptName = " My Watcher "
        await model.check(settings: named)
        await model.upload(script: "x", settings: named)
        #expect(model.state == .done(id: 5, created: false))
        #expect(api.uploads.all.first?.name == "My Watcher")
        model.reset()
        #expect(model.state == .idle)
    }

    @Test func missingCredentialsFailBeforeAnyRequest() async {
        let model = WatcherUploadModel(api: FakeJamfAPI(), secrets: MemorySecretStore())
        await model.check(settings: settings)
        #expect(model.state == .failed(JamfError.missingCredentials.localizedDescription))
    }
}

struct MessageAlignmentTests {
    @Test func alignmentAndPositionBecomeFlagsAndRoundTrip() {
        var rule = TestSupport.validRule()
        #expect(!DialogCommand.arguments(for: rule, settings: RuleSettings()).contains { $0.hasPrefix("--message") && $0 != "--message" })
        rule.dialogMessageAlignment = .center
        rule.dialogMessagePosition = .bottom
        let args = DialogCommand.arguments(for: rule, settings: RuleSettings())
        #expect(args.contains("--messagealignment") && args[args.firstIndex(of: "--messagealignment")! + 1] == "center")
        #expect(args.contains("--messageposition") && args[args.firstIndex(of: "--messageposition")! + 1] == "bottom")
        let text = RuleExport.plist(for: rule)
        #expect(RuleImporter.importRule(data: Data(text.utf8), name: rule.name).rule == rule)
        #expect(DialogLiveUpdate.needsRelaunch(from: TestSupport.validRule(), to: rule, oldSettings: RuleSettings(), newSettings: RuleSettings()))
    }

    @Test func anUnknownAlignmentIsReported() throws {
        let plist: [String: Any] = ["KillProcess": "X", "DialogMessage": "m", "DialogMessageAlignment": "justified"]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        let result = RuleImporter.importRule(data: data, name: "x")
        #expect(result.issues.map(\.id) == ["DialogMessageAlignment/dialogChoiceUnknown"])
    }

    /// The exact command the watcher runs for a plain rule and for a fully branded one.
    @Test func theCommandMatchesTheWatcherFlagForFlag() {
        var rule = BuiltInTemplates.appStore.rule(settings: RuleSettings())
        #expect(DialogCommand.arguments(for: rule, settings: RuleSettings()) == [
            "--height", "500", "--message", rule.dialogMessage, "--button1text", "Self Service",
            "--icon", "SF=exclamationmark.shield.fill,colour=red", "--ontop", "--moveable",
            "--button2text", "Done", "--title", "Company Name",
        ])
        var s = RuleSettings(); s.bannerImagePath = "/b.png"; s.bannerHeight = 100; s.iconPath = "/i.png"; s.iconSize = 90
        rule.dialogWidth = 640; rule.dialogHeight = 300; rule.dialogMessageAlignment = .center; rule.dialogMessagePosition = .top
        // Same input as the watcher harness run on 2026-10-02; this is its output.
        #expect(DialogCommand.arguments(for: rule, settings: s) == [
            "--height", "300", "--message", rule.dialogMessage, "--button1text", "Self Service", "--width", "640",
            "--messagealignment", "center", "--messageposition", "top", "--icon", "/i.png", "--iconsize", "90",
            "--ontop", "--moveable", "--button2text", "Done", "--bannerimage", "/b.png", "--title", "none", "--bannerheight", "100",
        ])
    }
}
