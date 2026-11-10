import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

// MARK: - Connect customer authentication (web `Authentication.tsx`, `conversation.ts`)

private let creds = ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: "tok", expiresAt: nil)
private let redirect = URL(string: "acmebank-touchpoint://auth")!
private let initiated = "application/vnd.amazonaws.connect.event.authentication.initiated"
private func event(_ suffix: String) -> String { "application/vnd.amazonaws.connect.event.authentication.\(suffix)" }

/// Records what the relay was asked to complete.
actor RecordingRelay: AuthenticationRelaying {
    private(set) var completions: [AuthenticationCompletion] = []
    var fails = false
    func completeAuthentication(_ completion: AuthenticationCompletion) async throws {
        completions.append(completion)
        if fails { throw NSError(domain: "relay", code: 500) }
    }
    func setFails(_ f: Bool) { fails = f }
}

private actor Events {
    var all: [TransportEvent] = []
    func add(_ e: TransportEvent) { all.append(e) }
    var statuses: [AuthenticationStatus] { all.compactMap { if case .authenticationChanged(_, let s) = $0 { s } else { nil } } }
    var cardIDs: [UUID] { all.compactMap { if case .authenticationChanged(let id, _) = $0 { id } else { nil } } }
    var securityRejections: [TouchpointError] { all.compactMap { if case .securityRejection(let e) = $0 { e } else { nil } } }
}

private func waitUntil(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

/// A connected transport with authentication on, and a clock the test moves.
private func connected(relay: RecordingRelay = RecordingRelay(),
                       redirectURI: URL = redirect,
                       supportsHTTPSCallback: Bool = true) async throws -> (ConnectChatTransport, FakeChatDriver, Events, Task<Void, Never>, TestClock) {
    let d = FakeChatDriver()
    let clock = TestClock()
    let t = ConnectChatTransport(driver: d, authentication: ChatAuthentication(redirectURI: redirectURI, relay: relay),
                                 now: { clock.now }, supportsHTTPSCallback: supportsHTTPSCallback)
    let events = Events()
    let stream = t.events
    let pump = Task { for await e in stream { await events.add(e) } }
    try await t.connect(credentials: creds)
    await d.fire { $0.onConnected() }
    return (t, d, events, pump, clock)
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { _now } }
    func advance(_ d: Duration) { lock.withLock { _now += d } }
}

private func prompt(_ d: FakeChatDriver, session: String = "s-1", time: String? = nil) async {
    await d.fire { $0.onAuthenticationEvent(initiated, #"{"SessionId":"\#(session)"}"#, time) }
}

@Suite("Authentication: transport state machine", .serialized)
struct AuthenticationTransportTests {
    @Test("Without authentication configured nothing listens and begin is refused")
    func offByDefault() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        #expect(await d.authEventsEnabled == false)
        await #expect(throws: TouchpointError.self) { _ = try await t.beginAuthentication() }
    }

    @Test("Configured: the listener is enabled; initiated shows a prompt card")
    func promptCard() async throws {
        let (t, d, events, pump, _) = try await connected(); defer { pump.cancel(); _ = t }
        #expect(await d.authEventsEnabled)
        await prompt(d)
        #expect(await waitUntil { await events.statuses == [.prompt] })
    }

    @Test("Web's mapping: succeeded and success → success, timeout and expired → expired, failed, cancelled")
    func mapping() {
        #expect(ConnectChatTransport.authenticationStatus(for: event("succeeded")) == .success)
        #expect(ConnectChatTransport.authenticationStatus(for: event("success")) == .success)
        #expect(ConnectChatTransport.authenticationStatus(for: event("failed")) == .failed)
        #expect(ConnectChatTransport.authenticationStatus(for: event("timeout")) == .expired)
        #expect(ConnectChatTransport.authenticationStatus(for: event("expired")) == .expired)
        #expect(ConnectChatTransport.authenticationStatus(for: event("cancelled")) == .cancelled)
        #expect(ConnectChatTransport.authenticationStatus(for: initiated) == .prompt)
        #expect(ConnectChatTransport.authenticationStatus(for: "application/vnd.amazonaws.connect.event.typing") == nil)
    }

    @Test("Begin: asks for the URL with the session and redirect, moves to in progress, returns the URL and callback scheme")
    func begin() async throws {
        let (t, d, events, pump, _) = try await connected(); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        let request = try await t.beginAuthentication()
        #expect(request.callbackScheme == "acmebank-touchpoint")
        #expect(request.url.host == "login.example")
        let asked = await d.authURLRequests
        #expect(asked.map(\.sessionID) == ["s-1"])
        #expect(asked.map(\.redirectURI) == [redirect])
        #expect(await waitUntil { await events.statuses == [.prompt, .inProgress] })
        #expect(!String(describing: request).contains("st-1"), "the URL's state is redacted from logs")
    }

    @Test("Begin past Connect's 60 s window expires the card instead")
    func expiresAfterSixtySeconds() async throws {
        let (t, d, events, pump, clock) = try await connected(); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        clock.advance(.seconds(61))
        await #expect(throws: TouchpointError.self) { _ = try await t.beginAuthentication() }
        #expect(await waitUntil { await events.statuses == [.prompt, .expired] })
        #expect(await d.authURLRequests.isEmpty)
    }

    @Test("Begin refuses a non-https URL and one without state: the card fails")
    func refusesUnsafeURL() async throws {
        for bad in ["http://login.example/x?state=s", "https://login.example/x"] {
            let (t, d, events, pump, _) = try await connected(); defer { pump.cancel() }
            await d.setNextAuthURL(URL(string: bad))
            await prompt(d)
            _ = await waitUntil { await events.statuses == [.prompt] }
            await #expect(throws: TouchpointError.self) { _ = try await t.beginAuthentication() }
            #expect(await waitUntil { await events.statuses.last == .failed }, "\(bad)")
        }
    }

    @Test("Complete: relays code and state from the callback; the card waits for Connect's event")
    func complete() async throws {
        let relay = RecordingRelay()
        let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        try await t.completeAuthentication(callbackURL: URL(string: "acmebank-touchpoint://auth?code=abc&state=st-1")!)
        #expect(await relay.completions == [AuthenticationCompletion(code: "abc", state: "st-1")])
        #expect(await events.statuses == [.prompt, .inProgress], "success is Connect's to say")
        await d.fire { $0.onAuthenticationEvent(event("succeeded"), nil, nil) }
        #expect(await waitUntil { await events.statuses == [.prompt, .inProgress, .success] })
        #expect(Set(await events.cardIDs).count == 1, "one card, updated in place")
    }

    @Test("Complete: an IdP error is relayed as error and description")
    func completeWithError() async throws {
        let relay = RecordingRelay()
        let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        try await t.completeAuthentication(callbackURL: URL(string: "acmebank-touchpoint://auth?error=access_denied&error_description=No&state=st-1")!)
        #expect(await relay.completions == [AuthenticationCompletion(code: nil, state: "st-1", error: "access_denied", errorDescription: "No")])
    }

    @Test("Complete refuses a mismatched state or callback, without relaying: the card fails")
    func completeRefuses() async throws {
        for bad in ["acmebank-touchpoint://auth?code=abc&state=other", "acmebank-touchpoint://auth?code=abc",
                    "evil://auth?code=abc&state=st-1", "acmebank-touchpoint://elsewhere?code=abc&state=st-1"] {
            let relay = RecordingRelay()
            let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
            await prompt(d)
            _ = await waitUntil { await events.statuses == [.prompt] }
            _ = try await t.beginAuthentication()
            await #expect(throws: TouchpointError.self) { try await t.completeAuthentication(callbackURL: URL(string: bad)!) }
            #expect(await relay.completions.isEmpty, "\(bad)")
            #expect(await waitUntil { await events.statuses.last == .failed }, "\(bad)")
        }
    }

    @Test("Complete: a relay failure fails the card")
    func relayFailure() async throws {
        let relay = RecordingRelay()
        await relay.setFails(true)
        let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        await #expect(throws: TouchpointError.self) {
            try await t.completeAuthentication(callbackURL: URL(string: "acmebank-touchpoint://auth?code=abc&state=st-1")!)
        }
        #expect(await waitUntil { await events.statuses.last == .failed })
    }

    @Test("Cancel: tells Connect and shows cancelled, even when the call fails; ignored once terminal")
    func cancel() async throws {
        let (t, d, events, pump, _) = try await connected(); defer { pump.cancel() }
        await d.setFailCancel(true)
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        await t.cancelAuthentication()
        #expect(await d.cancelRequests == ["s-1"])
        #expect(await waitUntil { await events.statuses == [.prompt, .cancelled] })
        await t.cancelAuthentication()
        #expect(await d.cancelRequests == ["s-1"], "nothing to cancel once terminal")
    }

    @Test("A later server event updates the card even after a local terminal state, as web does")
    func serverEventAfterLocalFailure() async throws {
        let relay = RecordingRelay()
        await relay.setFails(true)
        let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        _ = try? await t.completeAuthentication(callbackURL: URL(string: "acmebank-touchpoint://auth?code=abc&state=st-1")!)
        await d.fire { $0.onAuthenticationEvent(event("timeout"), nil, nil) }
        #expect(await waitUntil { await events.statuses.last == .expired })
    }

    @Test("A fresh initiated is a fresh card; a repeated one for the same session is not")
    func freshCardPerInitiated() async throws {
        let (t, d, events, pump, _) = try await connected(); defer { pump.cancel(); _ = t }
        await prompt(d, session: "s-1")
        await prompt(d, session: "s-1")   // the catch-up's copy of the same event
        await d.fire { $0.onAuthenticationEvent(event("cancelled"), nil, nil) }
        await prompt(d, session: "s-2")
        #expect(await waitUntil { await events.statuses == [.prompt, .cancelled, .prompt] })
        let ids = await events.cardIDs
        #expect(ids[0] == ids[1] && ids[1] != ids[2])
    }

    @Test("Catch-up: an initiated read back with its time counts the 60 s from Connect's clock")
    func catchUpTime() async throws {
        let (t, d, events, pump, _) = try await connected(); defer { pump.cancel() }
        let old = Date().addingTimeInterval(-90).formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        await prompt(d, time: old)
        _ = await waitUntil { await events.statuses == [.prompt] }
        await #expect(throws: TouchpointError.self) { _ = try await t.beginAuthentication() }
        #expect(await waitUntil { await events.statuses.last == .expired })
    }
}

@Suite("Authentication: wire helpers")
struct AuthenticationWireTests {
    @Test("The listener forwards only authentication frames, with their content and time")
    func frameParser() {
        let inner = #"{"Type":"EVENT","ContentType":"\#(initiated)","Content":"{\"SessionId\":\"s\"}","AbsoluteTime":"2026-10-20T19:48:02.737Z"}"#
        let frame = #"{"topic":"aws/chat","content":\#(String(data: try! JSONEncoder().encode(inner), encoding: .utf8)!)}"#
        let parsed = AuthenticationFrames.event(fromFrame: frame)
        #expect(parsed?.contentType == initiated)
        #expect(parsed?.content == #"{"SessionId":"s"}"#)
        #expect(parsed?.absoluteTime == "2026-10-20T19:48:02.737Z")
        let typing = #"{"topic":"aws/chat","content":"{\"Type\":\"EVENT\",\"ContentType\":\"application/vnd.amazonaws.connect.event.typing\"}"}"#
        #expect(AuthenticationFrames.event(fromFrame: typing) == nil)
        #expect(AuthenticationFrames.event(fromFrame: #"{"topic":"aws/subscribe","content":{"status":"success"}}"#) == nil)
        #expect(AuthenticationFrames.event(fromFrame: "not json") == nil)
    }

    @Test("Participant requests: POST over https to the path, the bearer token as X-Amz-Bearer, JSON body")
    func requestBuilder() throws {
        let request = try ParticipantRequest.make(endpoint: URL(string: "https://participant.connect.ca-central-1.amazonaws.com")!,
                                                  path: "/participant/authentication-url", bearerToken: "ct",
                                                  body: ["SessionId": "s", "RedirectUri": "acmebank-touchpoint://auth"])
        #expect(request.url?.absoluteString == "https://participant.connect.ca-central-1.amazonaws.com/participant/authentication-url")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Bearer") == "ct")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: String]
        #expect(body == ["SessionId": "s", "RedirectUri": "acmebank-touchpoint://auth"])
        #expect(throws: TouchpointError.self) {
            _ = try ParticipantRequest.make(endpoint: URL(string: "http://x")!, path: "/p", bearerToken: "ct", body: [String: String]())
        }
    }

    @Test("The listen-only connection asks for the websocket alone, so the connection token is not rotated")
    func websocketOnlyConnection() throws {
        let request = try ParticipantRequest.make(endpoint: URL(string: "https://participant.connect.us-west-2.amazonaws.com")!,
                                                  path: "/participant/connection", bearerToken: "pt",
                                                  body: ParticipantRequest.websocketOnlyConnection)
        #expect(request.url?.path == "/participant/connection")
        #expect(request.value(forHTTPHeaderField: "X-Amz-Bearer") == "pt")
        let body = try JSONSerialization.jsonObject(with: try #require(request.httpBody)) as? [String: [String]]
        #expect(body == ["Type": ["WEBSOCKET"]])
    }

    @Test("The connection reply yields its wss URL; anything else is a malformed payload")
    func connectionReply() throws {
        let reply = #"{"Websocket":{"Url":"wss://ws.example.com/connect?x=1","ConnectionExpiry":"2026-10-31T00:00:00Z"}}"#
        #expect(try ParticipantRequest.websocketURL(fromConnectionReply: Data(reply.utf8)).absoluteString == "wss://ws.example.com/connect?x=1")
        for bad in [#"{"Websocket":{"Url":"https://ws.example.com"}}"#, #"{"ConnectionCredentials":{}}"#, "not json"] {
            #expect(throws: TouchpointError.self) { _ = try ParticipantRequest.websocketURL(fromConnectionReply: Data(bad.utf8)) }
        }
    }

    @Test("The endpoint is built only from a region name, per partition")
    func endpoint() {
        #expect(ParticipantRequest.endpoint(region: "ca-central-1")?.absoluteString == "https://participant.connect.ca-central-1.amazonaws.com")
        #expect(ParticipantRequest.endpoint(region: "us-gov-west-1")?.absoluteString == "https://participant.connect.us-gov-west-1.amazonaws.com")
        #expect(ParticipantRequest.endpoint(region: "cn-north-1")?.absoluteString == "https://participant.connect.cn-north-1.amazonaws.com.cn")
        // The bearer token goes to this host, and the chat SDK's `Region` takes any string.
        for bad in ["", "uswest2", "US-WEST-2", "x.evil.com/", "us-west-2.evil.com", "us-west-2/", "eusc-de-east-1",
                    "us-iso-east-1", "us-isob-east-1", "eu-isoe-west-1"] {
            #expect(ParticipantRequest.endpoint(region: bad) == nil, "\(bad)")
        }
    }

    @Test("Participant requests never follow a redirect, so the bearer token cannot leave the endpoint")
    func refusesRedirects() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingStub.self]
        let session = ParticipantRequest.makeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        RedirectingStub.hosts.reset()
        let request = try ParticipantRequest.make(endpoint: try #require(URL(string: "https://participant.connect.us-west-2.amazonaws.com")),
                                                  path: "/participant/connection", bearerToken: "pt",
                                                  body: ParticipantRequest.websocketOnlyConnection)
        let (_, response) = try await session.data(for: request)
        // The 307 comes back as the response instead of being followed, and nothing reached the other host.
        #expect((response as? HTTPURLResponse)?.statusCode == 307)
        #expect(RedirectingStub.hosts.value == ["participant.connect.us-west-2.amazonaws.com"])
        #expect(ParticipantRequest.session.delegate is ParticipantRequest.RefuseRedirects)
    }
}

@Suite("Authentication: card in the transcript")
@MainActor
struct AuthenticationModelTests {
    private func message(_ seq: Int) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(seq)", body: "m\(seq)", direction: .inbound,
                              participantRole: .assistant, sequence: seq, deliveryState: .delivered))
    }

    @Test("The card is placed after its message, updated in place, clears the interim line, and locks the composer while pending")
    func card() {
        let model = ChatTranscriptModel()
        let first = message(1)
        model.setInitial([first], hasMore: false)
        model.ingest(.stateChanged(.connected))
        model.ingest(.remoteActivity(.interim("One moment.")))
        let id = UUID()
        model.ingest(.authenticationChanged(AuthenticationCard(id: id, status: .prompt, after: first.clientMessageID)))
        #expect(model.interim == nil)
        #expect(model.composerLocked)
        #expect(model.items.map(\.id) == [first.clientMessageID, id])
        model.ingest(.authenticationChanged(AuthenticationCard(id: id, status: .inProgress, after: first.clientMessageID)))
        #expect(model.composerLocked)
        model.ingest(.authenticationChanged(AuthenticationCard(id: id, status: .success, after: first.clientMessageID)))
        #expect(!model.composerLocked)
        #expect(model.items.count == 2, "updated in place, not appended")
        #expect(model.pendingAnnouncements.contains(TouchpointStrings.authenticationStatus(.success)))
    }
}

@Suite("Authentication: session", .serialized)
@MainActor
struct AuthenticationSessionTests {
    private struct Backend: TouchpointBackend {
        func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { creds }
        func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw TouchpointError.invalidConfiguration("chat only") }
        func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
    }

    @Test("The card is placed after the newest message, kept for a late subscriber, and gone with the contact")
    func sessionCard() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-auth-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let d = FakeChatDriver()
        let transport = ConnectChatTransport(driver: d, authentication: ChatAuthentication(redirectURI: redirect, relay: RecordingRelay()))
        let session = TouchpointSession(broker: CredentialBroker(backend: Backend(), keychain: keychain), store: store, transports: [.chat: transport])
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await d.fire { $0.onConnected() }
        #expect(await waitUntil { await MainActor.run { session.state == .connected } })
        await d.fire {
            $0.onItem(RawTranscriptItem(kind: .message, id: "m1", absoluteTime: "2026-10-20T19:48:00.000Z", contentType: "text/plain",
                                        participantRole: "SYSTEM", participantID: nil, displayName: "SYSTEM_MESSAGE",
                                        text: "Let's get you signed in.", isOutgoing: false))
        }
        #expect(await waitUntil { @MainActor in (try? await session.transcript().count) == 1 })
        await prompt(d)
        #expect(await waitUntil { await MainActor.run { session.authenticationCard?.status == .prompt } })
        let newest = try await session.transcript().last?.clientMessageID
        #expect(session.authenticationCard?.after == newest)

        // A view that subscribes now sees the card.
        var seen: AuthenticationCard?
        for await event in session.events {
            if case .authenticationChanged(let card) = event { seen = card; break }
        }
        #expect(seen?.status == .prompt)

        await session.end()
        #expect(session.authenticationCard == nil)
    }
}

// MARK: - I11: https sign-in redirects (universal links behind iOS 17.4 `Callback.https`)

@Suite("Authentication: redirect callback choice (I11)")
struct AuthenticationCallbackChoiceTests {
    @Test("A custom scheme is used as-is, whether or not the OS supports https callbacks")
    func customScheme() throws {
        for supports in [true, false] {
            let cb = try ChatAuthentication.callback(for: URL(string: "acmebank-touchpoint://auth")!, supportsHTTPSCallback: supports)
            #expect(cb == .scheme("acmebank-touchpoint"))
        }
    }

    @Test("An https redirect becomes an https host/path callback when the OS supports it")
    func httpsSupported() throws {
        let cb = try ChatAuthentication.callback(for: URL(string: "https://app.example.com/auth/cb")!, supportsHTTPSCallback: true)
        #expect(cb == .https(host: "app.example.com", path: "/auth/cb"))
    }

    @Test("An https redirect fails closed below iOS 17.4 rather than degrading to a custom scheme")
    func httpsUnsupportedFailsClosed() {
        #expect(throws: TouchpointError.self) {
            _ = try ChatAuthentication.callback(for: URL(string: "https://app.example.com/auth")!, supportsHTTPSCallback: false)
        }
    }

    @Test("An https redirect needs a path (the associated-domain entry is path-specific)")
    func httpsNeedsPath() {
        #expect(throws: TouchpointError.self) {
            _ = try ChatAuthentication.callback(for: URL(string: "https://app.example.com")!, supportsHTTPSCallback: true)
        }
    }
}

@Suite("Authentication: https redirect flow (I11)", .serialized)
struct AuthenticationHTTPSFlowTests {
    private let httpsRedirect = URL(string: "https://app.acmebank.com/auth")!

    @Test("Begin with an https redirect returns an https callback when supported")
    func beginHTTPS() async throws {
        let (t, d, events, pump, _) = try await connected(redirectURI: httpsRedirect, supportsHTTPSCallback: true); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        let request = try await t.beginAuthentication()
        #expect(request.callback == .https(host: "app.acmebank.com", path: "/auth"))
        #expect(request.callbackScheme == nil, "an https callback has no custom scheme")
    }

    @Test("Begin with an https redirect fails closed below iOS 17.4; the card fails")
    func beginHTTPSFailsClosed() async throws {
        let (t, d, events, pump, _) = try await connected(redirectURI: httpsRedirect, supportsHTTPSCallback: false); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        await #expect(throws: TouchpointError.self) { _ = try await t.beginAuthentication() }
        #expect(await waitUntil { await events.statuses.last == .failed })
        #expect(await d.authURLRequests.count == 1, "the Connect URL was fetched; only the callback form was unusable")
    }

    @Test("Complete over https: a matching host and path relays the code and state")
    func completeHTTPSMatches() async throws {
        let relay = RecordingRelay()
        let (t, d, events, pump, _) = try await connected(relay: relay, redirectURI: httpsRedirect, supportsHTTPSCallback: true); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        try await t.completeAuthentication(callbackURL: URL(string: "https://app.acmebank.com/auth?code=abc&state=st-1")!)
        #expect(await relay.completions == [AuthenticationCompletion(code: "abc", state: "st-1")])
    }

    @Test("Complete over https: a foreign host or a different path is refused, without relaying")
    func completeHTTPSMismatchRefused() async throws {
        for bad in ["https://evil.acmebank.com/auth?code=abc&state=st-1",
                    "https://app.acmebank.com/elsewhere?code=abc&state=st-1"] {
            let relay = RecordingRelay()
            let (t, d, events, pump, _) = try await connected(relay: relay, redirectURI: httpsRedirect, supportsHTTPSCallback: true); defer { pump.cancel() }
            await prompt(d)
            _ = await waitUntil { await events.statuses == [.prompt] }
            _ = try await t.beginAuthentication()
            await #expect(throws: TouchpointError.self) { try await t.completeAuthentication(callbackURL: URL(string: bad)!) }
            #expect(await relay.completions.isEmpty, "\(bad)")
            #expect(await waitUntil { await events.statuses.last == .failed }, "\(bad)")
        }
    }
}

// MARK: - I6: surface the sign-in redirect/state rejection to the host (not only the card)

@Suite("Authentication: security rejection surfaced (I6)", .serialized)
struct AuthenticationSecurityRejectionTests {
    @Test("A redirect or state mismatch is surfaced as a securityRejection, without relaying")
    func mismatchSurfacesSecurityRejection() async throws {
        for bad in ["acmebank-touchpoint://auth?code=abc&state=other",      // wrong state
                    "evil://auth?code=abc&state=st-1",                        // wrong scheme
                    "acmebank-touchpoint://elsewhere?code=abc&state=st-1"] {  // wrong path
            let relay = RecordingRelay()
            let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
            await prompt(d)
            _ = await waitUntil { await events.statuses == [.prompt] }
            _ = try await t.beginAuthentication()
            await #expect(throws: TouchpointError.self) { try await t.completeAuthentication(callbackURL: URL(string: bad)!) }
            #expect(await waitUntil {
                await events.securityRejections.contains(.invalidConfiguration("sign-in redirect did not match"))
            }, "\(bad)")
            #expect(await relay.completions.isEmpty, "\(bad)")
        }
    }

    @Test("A successful redirect surfaces no securityRejection")
    func matchSurfacesNoRejection() async throws {
        let relay = RecordingRelay()
        let (t, d, events, pump, _) = try await connected(relay: relay); defer { pump.cancel() }
        await prompt(d)
        _ = await waitUntil { await events.statuses == [.prompt] }
        _ = try await t.beginAuthentication()
        try await t.completeAuthentication(callbackURL: URL(string: "acmebank-touchpoint://auth?code=abc&state=st-1")!)
        #expect(await relay.completions.count == 1)
        #expect(await events.securityRejections.isEmpty)
    }
}

/// Answers the participant host with a 307 to another host, and records every host asked for.
private final class RedirectingStub: URLProtocol, @unchecked Sendable {
    static let hosts = Hosts()
    final class Hosts: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func append(_ host: String) { lock.withLock { seen.append(host) } }
        var value: [String] { lock.withLock { seen } }
        func reset() { lock.withLock { seen.removeAll() } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url ?? URL(fileURLWithPath: "/")
        Self.hosts.append(url.host ?? "")
        guard url.host == "participant.connect.us-west-2.amazonaws.com",
              let target = URL(string: "https://elsewhere.example/steal"),
              let redirect = HTTPURLResponse(url: url, statusCode: 307, httpVersion: "HTTP/1.1",
                                             headerFields: ["Location": target.absoluteString]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        var next = request
        next.url = target
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
