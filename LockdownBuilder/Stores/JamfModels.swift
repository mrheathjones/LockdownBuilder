import Foundation
import Observation

/// Settings → Jamf Pro: owns the client secret field (Keychain-backed) and the Test button.
@MainActor
@Observable
final class JamfSettingsModel {
    enum TestState: Equatable {
        case idle
        case testing
        case ok(String)
        case limited(String)
        case failed(String)
    }

    var clientSecret = ""
    private(set) var testState: TestState = .idle
    private(set) var keychainError: String?

    private let api: any JamfAPI
    private let secrets: any SecretStore
    private var storedSecret = ""
    private var testTask: Task<Void, Never>?

    init(api: any JamfAPI = JamfProClient(), secrets: any SecretStore = KeychainSecretStore()) {
        self.api = api
        self.secrets = secrets
    }

    func loadSecret() {
        do {
            storedSecret = try secrets.read() ?? ""
            clientSecret = storedSecret
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// Writes the field to the Keychain if it changed. Called when the field is committed and before a test.
    func saveSecret() {
        guard clientSecret != storedSecret else { return }
        do {
            try secrets.save(clientSecret)
            storedSecret = clientSecret
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// A result only describes the values it was run with.
    func credentialsChanged() {
        testTask?.cancel()
        testState = .idle
    }

    func test(urlText: String, clientID: String) {
        saveSecret()
        testTask?.cancel()
        guard let url = JamfConnection.normalizedURL(urlText) else {
            testState = .failed(JamfError.invalidURL.localizedDescription)
            return
        }
        let connection = JamfConnection(baseURL: url, clientID: clientID.trimmingCharacters(in: .whitespaces), clientSecret: clientSecret)
        testState = .testing
        testTask = Task {
            do {
                let result = try await api.testConnection(connection)
                guard !Task.isCancelled else { return }
                testState = result.canReadProfiles
                    ? .ok("Connected to \(url.host ?? "Jamf Pro"). The credentials are valid and can read configuration profiles.")
                    : .limited("The credentials are valid, but the API role can't read macOS configuration profiles. Publishing needs Create, Read and Update macOS Configuration Profiles.")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

/// The "Publish to Jamf Pro" sheet: check whether the profile exists, then create or update it.
/// Nothing is written to Jamf until `publish()` is called after a successful `check()`.
@MainActor
@Observable
final class JamfPublishModel {
    enum State: Equatable {
        case idle
        case checking
        /// Checked: the profile exists with this ID, or doesn't (nil).
        case ready(existingID: Int?)
        case publishing
        case done(id: Int, created: Bool)
        case failed(String)
    }

    let rule: RuleModel
    var name: String {
        didSet { if name != oldValue, !isBusy { state = .idle } }
    }
    private(set) var state: State = .idle

    private let api: any JamfAPI
    private let secrets: any SecretStore

    init(rule: RuleModel, name: String, api: any JamfAPI = JamfProClient(), secrets: any SecretStore = KeychainSecretStore()) {
        self.rule = rule
        self.name = name
        self.api = api
        self.secrets = secrets
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isBusy: Bool { state == .checking || state == .publishing }
    var canCheck: Bool { !trimmedName.isEmpty && !isBusy }

    private func connection(_ settings: RuleSettings) throws -> JamfConnection {
        guard let url = JamfConnection.normalizedURL(settings.jamfURL) else { throw JamfError.invalidURL }
        let secret = try secrets.read() ?? ""
        let clientID = settings.jamfClientID.trimmingCharacters(in: .whitespaces)
        guard !clientID.isEmpty, !secret.isEmpty else { throw JamfError.missingCredentials }
        return JamfConnection(baseURL: url, clientID: clientID, clientSecret: secret)
    }

    /// Read-only: looks the name up so the sheet can say "create" or "update" before anything is sent.
    func check(settings: RuleSettings) async {
        guard canCheck else { return }
        let name = trimmedName
        state = .checking
        do {
            let id = try await api.findProfile(named: name, connection(settings))
            guard name == trimmedName else { state = .idle; return }
            state = .ready(existingID: id)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Creates or updates the profile. `settings` must already carry the chosen name
    /// (see `RuleSettings.profileNames`) so the payload's display name matches the Jamf name.
    func publish(settings: RuleSettings) async {
        guard case .ready(let existingID) = state, rule.isValid else { return }
        let name = trimmedName
        state = .publishing
        do {
            let id = try await api.uploadProfile(
                name: name, mobileconfig: RuleExport.mobileconfig(for: rule, settings: settings),
                existingID: existingID, connection(settings))
            state = .done(id: id, created: existingID == nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
