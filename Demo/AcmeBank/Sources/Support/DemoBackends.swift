import CryptoKit
import Foundation
import TouchpointCore

/// Offline mode: the credentials are placeholders because `ScriptedChatTransport` never uses them.
struct OfflineBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        ChatContactCredentials(contactID: "offline-\(UUID().uuidString.lowercased())", participantID: "customer",
                               participantToken: "offline", expiresAt: nil)
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        throw TouchpointError.invalidConfiguration("the offline demo has no voice; switch to live mode")
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        throw TouchpointError.invalidConfiguration("the offline demo has no Live Sync; switch to live mode")
    }
}

#if DEBUG
/// Live mode: a `TouchpointBackend` over the demo backend in Demo/backend (chat and voice)
/// (`Scripts/env/demo-backend.yaml`), which requires AWS IAM. The credentials come from the signed-in
/// demo user (`DemoSignIn`, the backend's identity pool) or, without one, from temporary credentials
/// seeded into the scheme or entered on the debug Settings screen. Either way they are held in memory
/// for the run; they are never in the bundle, the repo, or any store.
///
/// Mirrors the e2e harness's `DemoHTTPBackend`. A real host backend authenticates its own users
/// rather than handing IAM credentials to the device — this exists so an internal demo can reach a
/// real Connect agent, nothing more.
struct LiveDemoBackend: TouchpointBackend, AuthenticationRelaying {
    /// Deliberately **not** `Codable`: nothing may persist these, and a synthesized encoding would
    /// be the first step to doing so. Redacted descriptions so an interpolation cannot leak them.
    struct Settings: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        var endpoint: String = ""
        var region: String = "ca-central-1"
        var accessKeyID: String = ""
        var secretAccessKey: String = ""
        var sessionToken: String = ""
        /// "Call us" rings this phone instead of placing an in-app call (Android's "voice by phone"):
        /// the backend's `POST /voice/call`, to numbers on its own allow-list only. E.164.
        var voiceByPhone = false
        var callbackNumber: String = ""
        var callsPhone: Bool { voiceByPhone && callbackNumber.wholeMatch(of: /\+[1-9][0-9]{7,14}/) != nil }

        /// Temporary credentials only: a session token is required, so a long-term key pair pasted
        /// in by habit is refused rather than quietly used.
        var isComplete: Bool {
            hasEndpoint && !accessKeyID.isEmpty && !secretAccessKey.isEmpty && !sessionToken.isEmpty
        }
        var hasEndpoint: Bool { URL(string: endpoint)?.host != nil && !region.isEmpty }

        var description: String { "LiveDemoBackend.Settings(endpoint: \(endpoint), region: \(region), credentials: <redacted>)" }
        var debugDescription: String { description }
    }

    let settings: Settings
    /// The signed-in demo user's credentials, preferred over `settings`' when present.
    var signIn: DemoSignIn?
    /// Which backend-allowlisted contact flow to start on. `livesync` hands the chat to the agentic
    /// ACXD app so the assistant can drive the screens; `default` is the plain agent queue.
    var flow: String = "default"

    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        let endpoint = try endpointURL()
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any] ?? [:]
        fields["flow"] = flow
        let body = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await signedPOST(endpoint: endpoint, path: "/chat/start", body: body)
        guard let http = response as? HTTPURLResponse else { throw TouchpointError.transportFailure("no HTTP response") }
        guard http.statusCode == 200 else {
            throw TouchpointError.httpFailure(statusCode: http.statusCode, responseBody: String(data: data, encoding: .utf8))
        }
        struct Reply: Decodable { let contactId: String; let participantId: String; let participantToken: String; let expiresAt: Date? }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return ChatContactCredentials(contactID: r.contactId, participantID: r.participantId,
                                      participantToken: r.participantToken, expiresAt: r.expiresAt)
    }

    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        let endpoint = try endpointURL()
        let body = try JSONEncoder().encode(request)
        let (data, response) = try await signedPOST(endpoint: endpoint, path: "/voice/start", body: body)
        guard let http = response as? HTTPURLResponse else { throw TouchpointError.transportFailure("no HTTP response") }
        guard http.statusCode == 200 else {
            throw TouchpointError.httpFailure(statusCode: http.statusCode, responseBody: String(data: data, encoding: .utf8))
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TouchpointError.malformedPayload("startVoiceContact reply")
        }
        return try VoiceContactCredentials(fromBackendReply: object)
    }

    /// `POST /voice/call`: Connect rings `to` into the voice flow — the assistant that drives the
    /// screens answers. Returns the contact id, which Live Sync binds to. The backend refuses any
    /// number not on its allow-list (403).
    func startOutboundCall(to number: String, attributes: [String: String]) async throws -> String {
        let endpoint = try endpointURL()
        let body = try JSONSerialization.data(withJSONObject: ["to": number, "attributes": attributes,
                                                               "clientToken": UUID().uuidString])
        let (data, response) = try await signedPOST(endpoint: endpoint, path: "/voice/call", body: body)
        guard let http = response as? HTTPURLResponse else { throw TouchpointError.transportFailure("no HTTP response") }
        guard http.statusCode == 200 else {
            throw TouchpointError.httpFailure(statusCode: http.statusCode, responseBody: String(data: data, encoding: .utf8))
        }
        struct Reply: Decodable { let contactId: String }
        return try JSONDecoder().decode(Reply.self, from: data).contactId
    }

    /// `POST /livesync/credentials`: the deployment key and application API key, from the backend,
    /// so nobody types them on a phone. A 503 means the backend has no Live Sync key configured.
    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        let endpoint = try endpointURL()
        let (data, response) = try await signedPOST(endpoint: endpoint, path: "/livesync/credentials", body: Data("{}".utf8))
        guard let http = response as? HTTPURLResponse else { throw TouchpointError.transportFailure("no HTTP response") }
        guard http.statusCode == 200 else {
            throw TouchpointError.httpFailure(statusCode: http.statusCode, responseBody: String(data: data, encoding: .utf8))
        }
        struct Reply: Decodable { let deploymentKey: String; let apiKey: String; let expiresAt: Date? }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        return LiveSyncCredentials(deploymentKey: r.deploymentKey, apiKey: r.apiKey, expiresAt: r.expiresAt)
    }

    /// `POST /auth/complete`: the backend calls `UpdateParticipantAuthentication` with what the
    /// sign-in redirect carried. Connect then tells the chat whether it worked.
    func completeAuthentication(_ completion: AuthenticationCompletion) async throws {
        let endpoint = try endpointURL()
        let body = try JSONEncoder().encode(completion)
        let (_, response) = try await signedPOST(endpoint: endpoint, path: "/auth/complete", body: body)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw TouchpointError.httpFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, responseBody: nil)
        }
    }

    private func endpointURL() throws -> URL {
        guard settings.hasEndpoint, let url = URL(string: settings.endpoint) else {
            throw TouchpointError.invalidConfiguration("live mode needs the demo backend's endpoint (Settings → Live mode)")
        }
        return url
    }

    /// The signed-in user's credentials, or the seeded or typed ones when nobody signs in.
    private func credentials() async throws -> DemoAWSCredentials {
        if let signIn {
            do { return try await signIn.credentials() } catch let failure as DemoSignIn.Failure {
                throw TouchpointError.invalidConfiguration(failure.errorDescription ?? "sign-in failed")
            }
        }
        guard settings.isComplete else {
            throw TouchpointError.invalidConfiguration("live mode needs a signed-in demo user or temporary credentials including a session token (Settings → Live mode)")
        }
        return DemoAWSCredentials(accessKeyID: settings.accessKeyID, secretAccessKey: settings.secretAccessKey,
                                  sessionToken: settings.sessionToken, expiresAt: nil)
    }

    // MARK: SigV4 (execute-api)

    private func signedPOST(endpoint: URL, path: String, body: Data) async throws -> (Data, URLResponse) {
        let creds = try await credentials()
        let url = endpoint.appending(path: path)
        // Canonical URI is the full request path (the endpoint may carry a stage prefix), and the
        // host header carries a non-default port.
        let canonicalPath = url.path().isEmpty ? "/" : url.path()
        let hostHeader = url.port.map { "\(url.host() ?? ""):\($0)" } ?? (url.host() ?? "")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.httpBody = body
        let now = Date()
        let amz = Self.stamp(now, "yyyyMMdd'T'HHmmss'Z'"), day = Self.stamp(now, "yyyyMMdd")
        var headers: [String: String] = ["content-type": "application/json", "host": hostHeader, "x-amz-date": amz]
        if !creds.sessionToken.isEmpty { headers["x-amz-security-token"] = creds.sessionToken }
        let names = headers.keys.sorted()
        let signedNames = names.joined(separator: ";")
        let canonicalHeaders = names.map { "\($0):\(headers[$0] ?? "")\n" }.joined()
        let canonical = ["POST", canonicalPath, "", canonicalHeaders, signedNames, Self.hex(SHA256.hash(data: body))].joined(separator: "\n")
        let scope = "\(day)/\(settings.region)/execute-api/aws4_request"
        let toSign = ["AWS4-HMAC-SHA256", amz, scope, Self.hex(SHA256.hash(data: Data(canonical.utf8)))].joined(separator: "\n")
        var key = Self.hmac(Data("AWS4\(creds.secretAccessKey)".utf8), day)
        for part in [settings.region, "execute-api", "aws4_request"] { key = Self.hmac(key, part) }
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: key)))
        headers["authorization"] = "AWS4-HMAC-SHA256 Credential=\(creds.accessKeyID)/\(scope), SignedHeaders=\(signedNames), Signature=\(signature)"
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        return try await URLSession.shared.data(for: req)
    }

    private static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }
    private static func hex<D: Sequence>(_ d: D) -> String where D.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }
    private static func stamp(_ d: Date, _ format: String) -> String {
        let f = DateFormatter(); f.dateFormat = format; f.timeZone = TimeZone(identifier: "UTC"); f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
#endif
