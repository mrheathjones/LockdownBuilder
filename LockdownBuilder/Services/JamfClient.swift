import Foundation

/// Everything needed to talk to one Jamf Pro server. Built per request from Settings + the Keychain;
/// never persisted as a whole.
struct JamfConnection: Equatable, Sendable {
    var baseURL: URL
    var clientID: String
    var clientSecret: String

    /// Turns what an admin types into a base URL: https only, trailing slashes removed
    /// (`jss_url` style `https://x.jamfcloud.com/` would otherwise double-slash every path).
    static func normalizedURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil
        else { return nil }
        return components.url
    }

    /// The Jamf Pro URL this Mac is enrolled with, if any (`jss_url` in the management plist).
    static func enrolledServerURL() -> String? {
        guard let plist = NSDictionary(contentsOfFile: "/Library/Preferences/com.jamfsoftware.jamf.plist"),
              let raw = plist["jss_url"] as? String
        else { return nil }
        return normalizedURL(raw)?.absoluteString
    }
}

enum JamfError: LocalizedError, Equatable {
    case invalidURL
    case missingCredentials
    case badCredentials
    case notJamf(Int)
    case forbidden(String)
    case http(status: Int, detail: String)
    case unexpectedResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter the Jamf Pro URL as https://server, e.g. https://company.jamfcloud.com."
        case .missingCredentials:
            "Enter the API client ID and client secret in Settings → Jamf Pro."
        case .badCredentials:
            "Jamf Pro rejected the client ID or client secret. Check both, and that the API client is enabled."
        case .notJamf(let status):
            "That server didn't answer like Jamf Pro (HTTP \(status) from the token endpoint). Check the URL."
        case .forbidden(let what):
            "The API client isn't allowed to \(what). Its API role needs Create, Read and Update for macOS Configuration Profiles (rules) and for Scripts (the watcher installer)."
        case .http(let status, let detail):
            detail.isEmpty ? "Jamf Pro returned HTTP \(status)." : "Jamf Pro returned HTTP \(status): \(detail)"
        case .unexpectedResponse(let what):
            "Jamf Pro sent an unexpected response (\(what))."
        case .network(let message):
            message
        }
    }
}

/// The one seam to the network, so tests can script Jamf's answers and inspect every request.
protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Ephemeral session (no cookies, cache or credential storage) that refuses redirects, so the client
/// secret and tokens only ever go to the host the admin typed.
final class URLSessionTransport: NSObject, HTTPTransport, URLSessionTaskDelegate {
    private let configuration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30
        c.httpCookieStorage = nil
        c.urlCache = nil
        return c
    }()

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JamfError.unexpectedResponse("not HTTP") }
        return (data, http)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct JamfTestResult: Equatable, Sendable {
    /// The credentials are valid (a token was issued). False here is never returned; failures throw.
    var tokenLifetimeSeconds: Int
    /// Whether the API role can read macOS configuration profiles (needed to publish).
    var canReadProfiles: Bool
}

protocol JamfAPI: Sendable {
    /// Requests a token, checks profile access, and invalidates the token.
    func testConnection(_ connection: JamfConnection) async throws -> JamfTestResult
    /// The ID of the macOS configuration profile with exactly this name, or nil.
    func findProfile(named name: String, _ connection: JamfConnection) async throws -> Int?
    /// Creates the profile (unscoped) or, with `existingID`, replaces that profile's name and payload,
    /// leaving its scope, category and site alone. Returns the profile ID.
    func uploadProfile(name: String, mobileconfig: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int
    /// The ID of the script with exactly this name, or nil.
    func findScript(named name: String, _ connection: JamfConnection) async throws -> Int?
    /// Creates the script or, with `existingID`, replaces that script's contents (its category, notes and
    /// parameter labels are kept). Returns the script ID.
    func uploadScript(name: String, contents: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int
}

/// Jamf Pro over OAuth client credentials. Every operation is one short session: get a token, do the work,
/// invalidate the token (always: abandoned tokens hold a database connection on the server until they expire).
/// macOS configuration profiles only exist in the Classic API (`/JSSResource/osxconfigurationprofiles`).
struct JamfProClient: JamfAPI {
    var transport: any HTTPTransport = URLSessionTransport()

    func testConnection(_ connection: JamfConnection) async throws -> JamfTestResult {
        try await withToken(connection) { token in
            var request = request(connection, "JSSResource/osxconfigurationprofiles", token: token.value)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (_, response) = try await send(request)
            return JamfTestResult(tokenLifetimeSeconds: token.expiresIn, canReadProfiles: response.statusCode == 200)
        }
    }

    func findProfile(named name: String, _ connection: JamfConnection) async throws -> Int? {
        try await withToken(connection) { token in
            try await findProfile(named: name, connection, token: token.value)
        }
    }

    func uploadProfile(name: String, mobileconfig: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int {
        try await withToken(connection) { token in
            var request = request(connection, "JSSResource/osxconfigurationprofiles/id/\(existingID ?? 0)", token: token.value)
            request.httpMethod = existingID == nil ? "POST" : "PUT"
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.setValue("application/xml", forHTTPHeaderField: "Accept")
            request.httpBody = Data(Self.profileXML(name: name, mobileconfig: mobileconfig, isNew: existingID == nil).utf8)
            let (data, response) = try await send(request)
            try Self.check(response, data, doing: existingID == nil ? "create configuration profiles" : "update configuration profiles")
            guard let id = Self.firstID(in: data) ?? existingID else {
                throw JamfError.unexpectedResponse("no profile ID")
            }
            return id
        }
    }

    // Scripts live in the Jamf Pro API (`/api/v1/scripts`), unlike configuration profiles.

    func findScript(named name: String, _ connection: JamfConnection) async throws -> Int? {
        try await withToken(connection) { token in
            let filter = #"name==""# + name.replacingOccurrences(of: #"\"#, with: #"\\"#)
                .replacingOccurrences(of: "\"", with: #"\""#) + "\""
            guard let url = URL(string: connection.baseURL.absoluteString
                                + "/api/v1/scripts?page=0&page-size=100&filter=" + Self.formEncode(filter))
            else { throw JamfError.invalidURL }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token.value)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await send(request)
            try Self.check(response, data, doing: "read scripts")
            struct Page: Decodable {
                struct Script: Decodable { var id: String; var name: String }
                var results: [Script]
            }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else {
                throw JamfError.unexpectedResponse("script list")
            }
            // The filter is a server-side match; the exact comparison here is the one that counts.
            return page.results.first { $0.name == name }.flatMap { Int($0.id) }
        }
    }

    func uploadScript(name: String, contents: String, existingID: Int?, _ connection: JamfConnection) async throws -> Int {
        try await withToken(connection) { token in
            var body: [String: Any] = [
                "name": name,
                "info": "Installs or removes the Restricted Item Watcher. Generated by LockdownBuilder.",
                "priority": "AFTER",
                "parameter4": "Mode: install (default) or uninstall",
            ]
            if let existingID {
                // PUT replaces the whole object, so start from what Jamf has and change only the contents.
                var get = request(connection, "api/v1/scripts/\(existingID)", token: token.value)
                get.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await send(get)
                try Self.check(response, data, doing: "read scripts")
                guard let current = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw JamfError.unexpectedResponse("script \(existingID)")
                }
                body = current
                body["name"] = name
            }
            body["scriptContents"] = contents

            var request = request(connection, existingID.map { "api/v1/scripts/\($0)" } ?? "api/v1/scripts", token: token.value)
            request.httpMethod = existingID == nil ? "POST" : "PUT"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await send(request)
            try Self.check(response, data, doing: existingID == nil ? "create scripts" : "update scripts")
            struct Created: Decodable { var id: String }
            guard let id = existingID ?? (try? JSONDecoder().decode(Created.self, from: data)).flatMap({ Int($0.id) }) else {
                throw JamfError.unexpectedResponse("no script ID")
            }
            return id
        }
    }

    // MARK: Requests

    private struct Token { var value: String; var expiresIn: Int }

    private func withToken<T: Sendable>(
        _ connection: JamfConnection, _ body: (Token) async throws -> T
    ) async throws -> T {
        let token = try await requestToken(connection)
        do {
            let result = try await body(token)
            await invalidate(token.value, connection)
            return result
        } catch {
            await invalidate(token.value, connection)
            throw error
        }
    }

    private func requestToken(_ connection: JamfConnection) async throws -> Token {
        guard !connection.clientID.isEmpty, !connection.clientSecret.isEmpty else { throw JamfError.missingCredentials }
        var request = URLRequest(url: connection.baseURL.appending(path: "api/oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data([
            "grant_type=client_credentials",
            "client_id=\(Self.formEncode(connection.clientID))",
            "client_secret=\(Self.formEncode(connection.clientSecret))",
        ].joined(separator: "&").utf8)
        let (data, response) = try await send(request)
        switch response.statusCode {
        case 200:
            struct Body: Decodable { var access_token: String; var expires_in: Int? }
            guard let body = try? JSONDecoder().decode(Body.self, from: data), !body.access_token.isEmpty else {
                throw JamfError.notJamf(200)
            }
            return Token(value: body.access_token, expiresIn: body.expires_in ?? 0)
        case 400, 401:
            throw JamfError.badCredentials
        default:
            throw JamfError.notJamf(response.statusCode)
        }
    }

    /// Best effort, and deliberately unstructured: it must still run when the caller was cancelled.
    private func invalidate(_ token: String, _ connection: JamfConnection) async {
        var request = request(connection, "api/v1/auth/invalidate-token", token: token)
        request.httpMethod = "POST"
        let transport = transport
        await Task.detached { _ = try? await transport.send(request) }.value
    }

    private func findProfile(named name: String, _ connection: JamfConnection, token: String) async throws -> Int? {
        // Built as a string: URL.appending(path:) would split a name containing "/" into two segments.
        guard let url = URL(string: connection.baseURL.absoluteString
                            + "/JSSResource/osxconfigurationprofiles/name/" + Self.pathEncode(name))
        else { throw JamfError.invalidURL }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await send(request)
        if response.statusCode == 404 { return nil }
        try Self.check(response, data, doing: "read configuration profiles")
        guard let id = Self.firstID(in: data) else { throw JamfError.unexpectedResponse("no profile ID") }
        return id
    }

    private func request(_ connection: JamfConnection, _ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: connection.baseURL.appending(path: path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch let error as JamfError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw JamfError.network(error.localizedDescription)
        }
    }

    // MARK: Pure helpers

    static func check(_ response: HTTPURLResponse, _ data: Data, doing what: String) throws {
        switch response.statusCode {
        case 200...299: return
        // The token was just issued, so a 401 here is the Classic API's way of saying "no privilege".
        case 401, 403: throw JamfError.forbidden(what)
        default: throw JamfError.http(status: response.statusCode, detail: errorDetail(in: data))
        }
    }

    /// The Classic API answers errors with a small HTML page; pull the useful sentence out of it.
    static func errorDetail(in data: Data) -> String {
        let text = String(decoding: data.prefix(4000), as: UTF8.self)
        let paragraphs = text.matches(of: #/<p>(.*?)</p>/#.dotMatchesNewlines()).map { String($0.1) }
        let detail = paragraphs.first { !$0.contains("<") && !$0.hasPrefix("You can get technical details") }
            ?? (text.contains("<") ? "" : text)
        return String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
    }

    /// The first `<id>` in a Classic API response: the profile's own ID in both the create/update reply
    /// (`<os_x_configuration_profile><id>`) and a lookup (`<general><id>` comes first).
    static func firstID(in data: Data) -> Int? {
        String(decoding: data, as: UTF8.self).firstMatch(of: #/<id>(\d+)</id>/#).flatMap { Int($0.1) }
    }

    /// The Classic API body. An update sends only the name and payload so scope, category, site and
    /// Self Service settings made in Jamf Pro are kept; a new profile is created with no scope.
    static func profileXML(name: String, mobileconfig: String, isNew: Bool) -> String {
        var general = "<name>\(xmlEscape(name))</name>"
        if isNew {
            general += "<description>Published by LockdownBuilder.</description>"
            general += "<distribution_method>Install Automatically</distribution_method>"
            general += "<user_removable>false</user_removable>"
            general += "<level>computer</level>"
        }
        general += "<payloads>\(xmlEscape(mobileconfig))</payloads>"
        return #"<?xml version="1.0" encoding="UTF-8"?>"#
            + "<os_x_configuration_profile><general>\(general)</general></os_x_configuration_profile>"
    }

    static func xmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// One path segment: everything but unreserved characters is escaped, including `/`.
    static func pathEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }
}
