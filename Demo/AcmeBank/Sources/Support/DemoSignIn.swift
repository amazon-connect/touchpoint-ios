#if DEBUG
import Foundation

/// Temporary AWS credentials for the demo backend. Never `Codable`, and redacted when printed.
struct DemoAWSCredentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String
    let expiresAt: Date?

    var description: String { "DemoAWSCredentials(<redacted>)" }
    var debugDescription: String { description }
}

/// The demo's sign-in, so nobody vends AWS credentials for the app by hand.
///
/// A demo user's username and password go to the Cognito user pool (`USER_PASSWORD_AUTH` on the
/// pool's app sign-in client, `Scripts/env/customer-auth.sh`). The backend's identity pool
/// (`Scripts/env/demo-backend.yaml`) then trades the ID token for temporary credentials whose role
/// may only call the demo backend. Accounts exist only because an administrator created them: the
/// pool has no self sign-up.
///
/// Tokens and credentials live in memory for the run, never on disk. The three Cognito calls are
/// unsigned JSON APIs, so this needs no AWS SDK. A real bank's app signs its customers in to its
/// own backend and holds no AWS credentials at all; this exists so an internal demo can.
actor DemoSignIn {
    struct Configuration: Sendable, Equatable {
        let region: String
        let userPoolID: String
        let clientID: String
        let identityPoolID: String

        /// From the launch environment `make demo-project` seeds; nil unless all three ids are set.
        init?(env: [String: String], region: String) {
            guard !region.isEmpty,
                  let pool = env["ACME_COGNITO_USER_POOL_ID"], !pool.isEmpty,
                  let client = env["ACME_COGNITO_CLIENT_ID"], !client.isEmpty,
                  let identities = env["ACME_COGNITO_IDENTITY_POOL_ID"], !identities.isEmpty else { return nil }
            self.region = region
            userPoolID = pool
            clientID = client
            identityPoolID = identities
        }

        /// The identity pool's name for the user pool, as the `Logins` map keys it.
        var provider: String { "cognito-idp.\(region).amazonaws.com/\(userPoolID)" }
    }

    enum Failure: Error, LocalizedError {
        /// No signed-in user, or the session can no longer be refreshed.
        case signedOut
        /// Cognito refused: wrong password, disabled account, a pending password change.
        case rejected(String)
        /// Anything else: the network, an unexpected reply.
        case unavailable(String)

        var errorDescription: String? {
            switch self {
            case .signedOut: "Your session has ended. Sign out and sign in again."
            case .rejected(let why): why
            case .unavailable(let why): "Sign-in is unavailable right now (\(why))."
            }
        }
    }

    let configuration: Configuration
    private var idToken: String?
    private var idTokenExpiry: Date?
    private var refreshToken: String?
    private var identityID: String?
    private var cached: DemoAWSCredentials?
    /// One refresh at a time: concurrent requests at launch share it rather than each exchanging.
    private var inFlight: Task<DemoAWSCredentials, Error>?
    /// Bumped by every sign-out. Work that started under an older generation writes nothing when it
    /// resumes, so a reply that lands after a sign-out can't restore the old user's session.
    private var generation = 0
    private let http: URLSession = URLSession(configuration: .ephemeral)

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    /// Signs in and proves the whole chain (pool → identity pool → credentials) before returning, so
    /// a wrong setup fails on the sign-in screen rather than at the first chat.
    func signIn(username: String, password: String) async throws {
        signOut()
        let started = generation
        let reply = try await userPool("InitiateAuth", [
            "AuthFlow": "USER_PASSWORD_AUTH",
            "ClientId": configuration.clientID,
            "AuthParameters": ["USERNAME": username, "PASSWORD": password],
        ])
        switch reply["ChallengeName"] as? String {
        case nil: break
        case "NEW_PASSWORD_REQUIRED":
            throw Failure.rejected("This account needs a new password. Ask an administrator to set one.")
        default:
            throw Failure.rejected("This account uses multi-factor sign-in, which the demo doesn't support.")
        }
        guard generation == started else { throw Failure.signedOut }
        try keep(reply)
        guard refreshToken != nil else { throw Failure.unavailable("no refresh token") }
        do { _ = try await credentials() } catch {
            // Half a sign-in is no sign-in: drop the tokens the pool gave us.
            if generation == started { signOut() }
            throw error
        }
    }

    var isSignedIn: Bool { refreshToken != nil }

    func signOut() {
        generation += 1
        inFlight?.cancel()
        inFlight = nil
        idToken = nil; idTokenExpiry = nil; refreshToken = nil; identityID = nil; cached = nil
    }

    /// Credentials for the demo backend, refreshed five minutes before they expire.
    func credentials() async throws -> DemoAWSCredentials {
        if let cached, let expiry = cached.expiresAt, expiry.timeIntervalSinceNow > 300 { return cached }
        let started = generation
        if let inFlight {
            let joined = try await inFlight.value
            guard generation == started else { throw Failure.signedOut }
            return joined
        }
        let task = Task { try await self.exchange(generation: started) }
        inFlight = task
        let fresh: DemoAWSCredentials
        do { fresh = try await task.value } catch {
            if generation == started { inFlight = nil }
            throw error
        }
        guard generation == started else { throw Failure.signedOut }
        inFlight = nil
        cached = fresh
        return fresh
    }

    // MARK: Exchange

    private func exchange(generation started: Int) async throws -> DemoAWSCredentials {
        let token = try await currentIDToken(generation: started)
        let logins = [configuration.provider: token]
        if identityID == nil {
            let reply = try await identityPool("GetId", ["IdentityPoolId": configuration.identityPoolID, "Logins": logins])
            guard let id = reply["IdentityId"] as? String else { throw Failure.unavailable("no identity id") }
            guard generation == started else { throw Failure.signedOut }
            identityID = id
        }
        guard let identityID else { throw Failure.signedOut }
        let reply = try await identityPool("GetCredentialsForIdentity", ["IdentityId": identityID, "Logins": logins])
        guard let c = reply["Credentials"] as? [String: Any],
              let key = c["AccessKeyId"] as? String, let secret = c["SecretKey"] as? String,
              let session = c["SessionToken"] as? String else { throw Failure.unavailable("no credentials") }
        let expiry = (c["Expiration"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return DemoAWSCredentials(accessKeyID: key, secretAccessKey: secret, sessionToken: session, expiresAt: expiry)
    }

    /// The ID token, refreshed with the refresh token when it has two minutes or less left.
    private func currentIDToken(generation started: Int) async throws -> String {
        if let idToken, let idTokenExpiry, idTokenExpiry.timeIntervalSinceNow > 120 { return idToken }
        guard let refreshToken else { throw Failure.signedOut }
        let reply: [String: Any]
        do {
            reply = try await userPool("InitiateAuth", [
                "AuthFlow": "REFRESH_TOKEN_AUTH",
                "ClientId": configuration.clientID,
                "AuthParameters": ["REFRESH_TOKEN": refreshToken],
            ])
        } catch Failure.rejected {
            if generation == started { signOut() }
            throw Failure.signedOut
        }
        guard generation == started else { throw Failure.signedOut }
        try keep(reply)
        guard let idToken else { throw Failure.signedOut }
        return idToken
    }

    private func keep(_ reply: [String: Any]) throws {
        guard let result = reply["AuthenticationResult"] as? [String: Any],
              let token = result["IdToken"] as? String else { throw Failure.unavailable("no ID token") }
        idToken = token
        idTokenExpiry = Date().addingTimeInterval((result["ExpiresIn"] as? Double) ?? 3600)
        // A refresh reply carries no new refresh token; keep the one from sign-in.
        if let refresh = result["RefreshToken"] as? String { refreshToken = refresh }
    }

    // MARK: Wire

    private func userPool(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await call(host: "cognito-idp", target: "AWSCognitoIdentityProviderService.\(action)", body: body)
    }

    private func identityPool(_ action: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await call(host: "cognito-identity", target: "AWSCognitoIdentityService.\(action)", body: body)
    }

    private func call(host: String, target: String, body: [String: Any]) async throws -> [String: Any] {
        guard let url = URL(string: "https://\(host).\(configuration.region).amazonaws.com/") else {
            throw Failure.unavailable("bad region")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "Content-Type")
        request.setValue(target, forHTTPHeaderField: "X-Amz-Target")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await http.data(for: request)
        } catch is CancellationError {
            throw Failure.signedOut
        } catch let error as URLError where error.code == .cancelled {
            throw Failure.signedOut
        } catch {
            throw Failure.unavailable("network")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw Failure.unavailable("no response") }
        guard status == 200 else {
            // `__type` is the exception name, sometimes prefixed with a namespace and `#`.
            let type = (object["__type"] as? String)?.split(separator: "#").last.map(String.init) ?? "HTTP \(status)"
            // The identity pool's refusals (a token it won't take, a role it can't assume) are setup
            // faults, not a wrong password: name them.
            guard host == "cognito-idp" else { throw Failure.unavailable(type) }
            switch type {
            case "NotAuthorizedException", "UserNotFoundException":
                // The same exception carries "Password attempts exceeded" and "User is disabled".
                let message = object["message"] as? String ?? ""
                if message.localizedCaseInsensitiveContains("attempts exceeded") {
                    throw Failure.rejected("Too many attempts. Wait a few minutes, then try again.")
                }
                if message.localizedCaseInsensitiveContains("disabled") {
                    throw Failure.rejected("This account is disabled. Ask an administrator.")
                }
                throw Failure.rejected("Incorrect username or password.")
            case "PasswordResetRequiredException":
                throw Failure.rejected("This account needs a new password. Ask an administrator to set one.")
            case "UserNotConfirmedException":
                throw Failure.rejected("This account isn't confirmed yet.")
            default:
                throw Failure.unavailable(type)
            }
        }
        return object
    }
}
#endif
