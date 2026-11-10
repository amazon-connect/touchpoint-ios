import Foundation
import TouchpointCore

// Connect customer authentication on chat — web's state machine (`conversation.ts`
// `AUTH_EVENT_STATUS`, `setAuthState`, `startAuthentication`, `completeAuthentication`,
// `cancelAuthentication`) on the transport, where the fake driver can test it.

/// Sign-in for a chat: where Connect sends the customer back, and who relays what came back to
/// the host's backend (`UpdateParticipantAuthentication` is an IAM API the device cannot call).
public struct ChatAuthentication: Sendable {
    /// Where Connect sends the customer back after sign-in. Two forms are accepted:
    ///
    /// - A **custom scheme** the app owns (e.g. `acmebank-touchpoint://auth`), registered as the
    ///   Cognito app client's callback. Works on every supported OS version.
    /// - An **https universal link** (e.g. `https://app.example.com/auth`) on **iOS 17.4+**, using
    ///   `ASWebAuthenticationSession.Callback.https`. The host **must own the associated domain** —
    ///   serve an `apple-app-site-association` file with a `webcredentials` entry for the app — or
    ///   the system will not route the redirect back. An https redirect must include a path.
    ///
    /// Because the floor is iOS 17.0, an https redirect **fails closed** on iOS 17.0–17.3 (a clear
    /// ``TouchpointError/invalidConfiguration(_:)``) rather than silently degrading to a custom
    /// scheme — the sign-in simply cannot proceed on those versions with an https redirect.
    public let redirectURI: URL
    public let relay: any AuthenticationRelaying

    public init(redirectURI: URL, relay: any AuthenticationRelaying) {
        self.redirectURI = redirectURI
        self.relay = relay
    }
}

extension ChatAuthentication {
    /// Whether the running OS can match an https universal-link callback
    /// (`ASWebAuthenticationSession.Callback.https`, iOS 17.4 / macOS 14.4).
    static var runtimeSupportsHTTPSCallback: Bool {
        if #available(iOS 17.4, macOS 14.4, *) { true } else { false }
    }

    /// Chooses how the sign-in sheet should recognise the redirect, from the redirect URI's scheme.
    /// Pure so the availability decision is testable without an OS version: `supportsHTTPSCallback`
    /// is the only thing the real ``runtimeSupportsHTTPSCallback`` injects.
    ///
    /// - An `https` redirect becomes a ``AuthenticationCallback/https(host:path:)`` callback, but
    ///   only when `supportsHTTPSCallback` is `true`; otherwise it **fails closed** rather than
    ///   degrading to a custom scheme (iOS 17.0–17.3 cannot route an https callback). It must carry
    ///   a host and a path (the associated-domain entry is path-specific).
    /// - Any other scheme is treated as a custom scheme the app owns.
    static func callback(for redirectURI: URL, supportsHTTPSCallback: Bool) throws -> AuthenticationCallback {
        guard let scheme = redirectURI.scheme, !scheme.isEmpty else {
            throw TouchpointError.invalidConfiguration("the sign-in redirect URI has no scheme")
        }
        guard scheme.lowercased() == "https" else {
            return .scheme(scheme)
        }
        guard supportsHTTPSCallback else {
            throw TouchpointError.invalidConfiguration(
                "an https sign-in redirect needs iOS 17.4 or newer; use a custom URL scheme on earlier versions")
        }
        guard let host = redirectURI.host, !host.isEmpty else {
            throw TouchpointError.invalidConfiguration("an https sign-in redirect needs a host")
        }
        guard !redirectURI.path.isEmpty else {
            throw TouchpointError.invalidConfiguration("an https sign-in redirect needs a path")
        }
        return .https(host: host, path: redirectURI.path)
    }
}

/// The transport's view of the sign-in on this contact.
struct AuthenticationState {
    var cardID: UUID?
    var status: AuthenticationStatus?
    var sessionID: String?
    var initiatedAt: ContinuousClock.Instant?
    var expectedState: String?
    /// Sessions already carded, so the catch-up read's copy of an event is not a second card.
    var seenSessions: Set<String> = []
}

extension ConnectChatTransport {
    /// Connect's window to ask for the sign-in URL (web: `Date.now() - authInitiatedAt > 60_000`).
    static let authenticationStartWindow: Duration = .seconds(60)

    private static let authenticationPrefix = "application/vnd.amazonaws.connect.event.authentication."

    /// Web's `AUTH_EVENT_STATUS`, aliases included.
    static func authenticationStatus(for contentType: String) -> AuthenticationStatus? {
        guard contentType.hasPrefix(authenticationPrefix) else { return nil }
        switch contentType.dropFirst(authenticationPrefix.count) {
        case "initiated": return .prompt
        case "succeeded", "success": return .success
        case "failed": return .failed
        case "timeout", "expired": return .expired
        case "cancelled": return .cancelled
        default: return nil
        }
    }

    func handleAuthenticationEvent(_ contentType: String, content: String?, absoluteTime: String?) {
        guard authentication != nil, let status = Self.authenticationStatus(for: contentType) else { return }
        if status == .prompt {
            let session = content.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }?["SessionId"] as? String
            guard let session, !auth.seenSessions.contains(session) else { return }   // the catch-up's copy
            auth.seenSessions.insert(session)
            auth.cardID = UUID()
            auth.sessionID = session
            auth.expectedState = nil
            // From Connect's clock when the event was read back late, so the window is not reset.
            if let time = absoluteTime, let sent = Self.date(time) {
                auth.initiatedAt = now() - .milliseconds(Int(max(0, Date().timeIntervalSince(sent)) * 1000))
            } else {
                auth.initiatedAt = now()
            }
            setAuthentication(.prompt)
            return
        }
        // Any other event ends this session; it updates the card even after a local terminal state,
        // as web's does, so Connect's own outcome has the last word.
        guard auth.cardID != nil else { return }
        auth.sessionID = nil
        setAuthentication(status)
    }

    private func setAuthentication(_ status: AuthenticationStatus) {
        guard let id = auth.cardID, auth.status != status else { return }
        auth.status = status
        yield(.authenticationChanged(id: id, status: status))
    }

    public func beginAuthentication() async throws -> AuthenticationRequest {
        guard let authentication, auth.status == .prompt, let session = auth.sessionID, let started = auth.initiatedAt else {
            throw TouchpointError.invalidConfiguration("no sign-in waiting")
        }
        guard now() - started <= Self.authenticationStartWindow else {
            setAuthentication(.expired)
            throw TouchpointError.invalidConfiguration("the sign-in window has passed")
        }
        setAuthentication(.inProgress)
        let url: URL
        do { url = try await driver.authenticationURL(sessionID: session, redirectURI: authentication.redirectURI) }
        catch { setAuthentication(.failed); throw Self.map(error) }
        // The state Connect put in the URL is what the redirect must echo (web's CSRF check). A URL
        // without one, or not over https, is not sent to the sheet at all.
        guard url.scheme?.lowercased() == "https",
              let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value,
              !state.isEmpty else {
            setAuthentication(.failed)
            throw TouchpointError.invalidConfiguration("sign-in URL is not usable")
        }
        // Choose how the redirect is recognised from the host's redirect URI. An https universal
        // link needs iOS 17.4+ and fails closed below it rather than degrading to a custom scheme.
        let callback: AuthenticationCallback
        do { callback = try ChatAuthentication.callback(for: authentication.redirectURI, supportsHTTPSCallback: supportsHTTPSCallback) }
        catch { setAuthentication(.failed); throw error }
        auth.expectedState = state
        return AuthenticationRequest(url: url, callback: callback)
    }

    public func completeAuthentication(callbackURL: URL) async throws {
        guard let authentication, auth.status == .inProgress else {
            throw TouchpointError.invalidConfiguration("no sign-in in progress")
        }
        let expected = auth.expectedState
        auth.expectedState = nil
        let redirect = authentication.redirectURI
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first(where: { $0.name == name })?.value }
        // The whole redirect must be ours, and the state Connect's. **Stricter than web**, which
        // skips the check when it has no expected state.
        guard callbackURL.scheme?.lowercased() == redirect.scheme?.lowercased(),
              callbackURL.host == redirect.host, callbackURL.path == redirect.path,
              let expected, let state = value("state"), state == expected else {
            setAuthentication(.failed)
            // Also surface it to the host's error stream: the SDK's sign-in card swallows this throw
            // (it only shows the card as failed), so without this a redirect or `state` mismatch —
            // the scheme-squat / CSRF rejection — would never reach a host security log (I6, BSC40).
            yield(.securityRejection(.invalidConfiguration("sign-in redirect did not match")))
            throw TouchpointError.invalidConfiguration("sign-in redirect did not match")
        }
        let completion = AuthenticationCompletion(code: value("code"), state: state,
                                                  error: value("error"), errorDescription: value("error_description"))
        do { try await authentication.relay.completeAuthentication(completion) }
        catch { setAuthentication(.failed); throw Self.map(error) }
        // Success is Connect's to say: the card stays in progress until its event.
    }

    public func cancelAuthentication() async {
        guard let status = auth.status, status.isPending, let session = auth.sessionID else { return }
        try? await driver.cancelAuthentication(sessionID: session)   // cancelled either way, as web
        auth.sessionID = nil
        setAuthentication(.cancelled)
    }
}

// MARK: - Wire helpers (pure; used by the iOS driver)

/// The sign-in frames on a participant websocket, which the vendor SDK drops.
enum AuthenticationFrames {
    struct Event: Equatable {
        let contentType: String
        let content: String?
        let absoluteTime: String?
    }

    /// `{"topic":"aws/chat","content":"<frame JSON>"}` → the event, when it is a sign-in one.
    static func event(fromFrame text: String) -> Event? {
        guard let outer = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              outer["topic"] as? String == "aws/chat", let content = outer["content"] as? String,
              let inner = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              let type = inner["ContentType"] as? String,
              ConnectChatTransport.authenticationStatus(for: type) != nil else { return nil }
        return Event(contentType: type, content: inner["Content"] as? String, absoluteTime: inner["AbsoluteTime"] as? String)
    }
}

/// The Participant Service calls sign-in makes itself: `POST /participant/authentication-url` and
/// `/participant/cancel-authentication` (web calls them the same way, `conversation.ts`
/// `participantAuthRequest`), and the listen-only `/participant/connection`. The AWS SDK for Swift
/// binds all three, but the chat SDK's `AWSClient` exposes none of them, and a client of our own
/// would need the chat SDK's internal no-auth resolver. Each is one unsigned POST authorised by the
/// `X-Amz-Bearer` token, as the SDKs send it.
enum ParticipantRequest {
    static func make(endpoint: URL, path: String, bearerToken: String, body: some Encodable) throws -> URLRequest {
        guard endpoint.scheme?.lowercased() == "https", let url = URL(string: path, relativeTo: endpoint)?.absoluteURL else {
            throw TouchpointError.invalidConfiguration("participant endpoint must be https")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(bearerToken, forHTTPHeaderField: "X-Amz-Bearer")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        request.httpBody = try encoder.encode(body)
        return request
    }

    /// Whether `name` has the shape of an AWS region name (`ca-central-1`, `us-gov-west-1`).
    static func isRegionName(_ name: String) -> Bool {
        name.wholeMatch(of: /[a-z]{2}(-[a-z]+)+-[0-9]+/) != nil
    }

    /// The Participant Service endpoint for `region`, the host the AWS SDK for Swift resolves to
    /// (`participant.connect.<region>.<partition DNS suffix>`). `nil` for anything that is not a
    /// region name, because the chat SDK's `Region` takes any string and the bearer token goes to
    /// this host. China regions (`cn-`) take `amazonaws.com.cn` and the commercial and GovCloud
    /// regions `amazonaws.com`. Partitions with another DNS suffix get `nil` rather than a guessed
    /// host: the isolated ones (`us-iso-…`, `us-isob-…`, `eu-isoe-…`) and `eusc-…`, which is not
    /// region-shaped here.
    static func endpoint(region: String) -> URL? {
        guard isRegionName(region), !region.contains("-iso") else { return nil }
        let suffix = region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
        return URL(string: "https://participant.connect.\(region).\(suffix)")
    }

    /// `CreateParticipantConnection` with `Type: ["WEBSOCKET"]` only: no connection credentials, so
    /// the chat SDK's connection token is not rotated.
    static let websocketOnlyConnection = ["Type": ["WEBSOCKET"]]

    /// The socket URL from a `CreateParticipantConnection` reply (`Websocket.Url`). Must be `wss`.
    static func websocketURL(fromConnectionReply data: Data) throws -> URL {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = ((object["Websocket"] as? [String: Any])?["Url"] as? String).flatMap(URL.init(string:)),
              url.scheme?.lowercased() == "wss" else {
            throw TouchpointError.malformedPayload("participant connection reply")
        }
        return url
    }

    /// One session for these calls, refusing redirects: `URLSession` carries custom headers across a
    /// redirect, and `X-Amz-Bearer` must reach only the participant endpoint.
    static let session = makeSession(configuration: .ephemeral)

    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
