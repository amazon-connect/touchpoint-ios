import Foundation
import TouchpointCore

#if canImport(AmazonConnectChatIOS)
import AmazonConnectChatIOS
// The AWS SDK for Swift's ConnectParticipant models, which the chat SDK's `AWSClient` API speaks.
import AWSConnectParticipant

/// The one real `ChatSessionDriving`: wraps `ChatSession.shared` from `amazon-connect-chat-ios`
/// (3.x, on the AWS SDK for Swift), consumed as SPM source. Compiled only where the SDK
/// is linked, which is iOS; everything that can be unit-tested lives in `ConnectChatTransport` and
/// `ParticipantRequest` instead.
///
/// Upstream constraints this driver works around:
/// - `ChatSession.sendMessage` does not return the server id. We call the SDK's own `AWSClient`
///   directly with the connection token it already holds, so the id and server time come back in
///   the response and our `clientMessageID` ↔ server id correlation is exact.
/// - The typed `TranscriptItem` drops `ParticipantId`; it is recovered from the raw frame the SDK
///   keeps in `serializedContent["content"]`.
/// - The SDK is a process-wide singleton: one chat per process, which the coordinator also assumes.
final class ConnectChatSessionDriver: ChatSessionDriving, @unchecked Sendable {
    private var session: any ChatSessionProtocol
    private let client: AWSClient
    private let lock = NSLock()
    private var handlers: ChatDriverHandlers?
    private let region: Region
    // Sign-in: off until the host configures it.
    private var authenticationEnabled = false
    private var participantToken: String?
    private let listener = AuthenticationEventListener()

    /// - Parameters:
    ///   - region: The Connect instance's region, e.g. `.caCentral1`.
    ///   - customChatClient: The host's own Participant Service client (web's `customChatClient`).
    ///     Handed to the vendor SDK as `GlobalConfig.customAWSClient`, and used for every call this
    ///     driver makes directly, so nothing of ours goes round it.
    init(region: Region, session: any ChatSessionProtocol = ChatSession.shared, client: AWSClient = .shared,
         customChatClient: AWSClient? = nil) {
        self.session = session
        self.client = customChatClient ?? client
        self.region = region
        // Receipts are ours to send; the SDK's own throttled receipt sender stays off so
        // there is exactly one source of truth for what went on the wire.
        let features = Features(messageReceipts: MessageReceipts(shouldSendMessageReceipts: false, throttleTime: 0))
        session.configure(config: GlobalConfig(region: region, features: features, disableCsm: true,
                                               customAWSClient: customChatClient))
    }

    func setHandlers(_ handlers: ChatDriverHandlers) async {
        lock.withLock { self.handlers = handlers }
        // The sign-in listener follows the vendor's connection: (re)opened with it, stopped with it.
        session.onConnectionEstablished = { [weak self] in self?.startListening(); self?.current?.onConnected() }
        session.onConnectionReEstablished = { [weak self] in self?.startListening(); self?.current?.onReestablished() }
        session.onConnectionBroken = { [weak self] in self?.current?.onConnectionBroken() }
        session.onDeepHeartbeatFailure = { [weak self] in self?.current?.onConnectionBroken() }
        session.onChatEnded = { [weak self] in self?.listener.stop(); self?.current?.onChatEnded() }
        session.onMessageReceived = { [weak self] item in
            guard let self, let raw = Self.raw(item) else { return }
            self.current?.onItem(raw)
        }
        session.onDeliveredReceipt = { [weak self] event in
            guard let self, let id = event?.id else { return }
            self.current?.onReceipt(.delivered, id)
        }
        session.onReadReceipt = { [weak self] event in
            guard let self, let id = event?.id else { return }
            self.current?.onReceipt(.read, id)
        }
        // Typing arrives on its own callback, not as a transcript item.
        session.onTyping = { [weak self] event in
            self?.current?.onTyping(event?.participant ?? "")
        }
    }

    private var current: ChatDriverHandlers? { lock.withLock { handlers } }

    func connect(contactID: String, participantID: String, participantToken: String?) async throws {
        lock.withLock { self.participantToken = participantToken }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            // With a custom chat client there is no token; the vendor passes this one, empty, to the
            // host's `createParticipantConnection`, which knows the contact from its own session.
            session.connect(chatDetails: ChatDetails(contactId: contactID, participantId: participantID, participantToken: participantToken ?? "")) { c.resume(with: $0) }
        }
    }

    func disconnect() async throws {
        listener.stop()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            session.disconnect { c.resume(with: $0) }
        }
    }

    func release() async throws {
        // `reset()` closes only the websocket (the vendor's `ChatService.reset()` →
        // `websocketManager.disconnect`), leaving the participant on the contact so `resume()` can
        // reconnect with the stored token. Unlike `disconnect`, it issues no
        // `DisconnectParticipant`.
        listener.stop()
        session.reset()
    }

    func sendMessage(_ body: String, contentType: String) async throws -> SentMessageAck {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else {
            throw TouchpointError.transportFailure("not connected")
        }
        let type = ContentType(rawValue: contentType) ?? .plainText
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<SentMessageAck, Error>) in
            client.sendMessage(connectionToken: token, contentType: type, message: body) { result in
                switch result {
                case .success(let r):
                    guard let id = r.id else { c.resume(throwing: TouchpointError.transportFailure("send accepted without an id")); return }
                    c.resume(returning: SentMessageAck(serverMessageID: id, absoluteTime: r.absoluteTime ?? ""))
                case .failure(let e):
                    c.resume(throwing: e)
                }
            }
        }
    }

    func sendReceipt(_ kind: ReceiptKind, messageID: String) async throws {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else {
            throw TouchpointError.transportFailure("not connected")
        }
        let type: ContentType = kind == .read ? .messageRead : .messageDelivered
        let content = "{\"messageId\":\"\(messageID)\"}"
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            client.sendEvent(connectionToken: token, contentType: type, content: content) { c.resume(with: $0.map { _ in () }) }
        }
    }

    /// Straight to `AWSClient`, as receipts are: `ChatService.sendEvent` adds its own 10 s typing
    /// throttle, which would sit under the session's 2.5 s one and make the agent's indicator lapse.
    func sendTyping() async throws {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else {
            throw TouchpointError.transportFailure("not connected")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            client.sendEvent(connectionToken: token, contentType: .typing, content: "") { c.resume(with: $0.map { _ in () }) }
        }
    }

    func fetchTranscript(nextToken: String?, maxResults: Int) async throws -> RawTranscriptPage {
        // `TranscriptResponse` is a non-Sendable upstream class: convert on the SDK's thread, send values.
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<RawTranscriptPage, Error>) in
            session.getTranscript(scanDirection: .backward, sortOrder: .ascending, maxResults: NSNumber(value: maxResults), nextToken: nextToken, startPosition: nil) { result in
                c.resume(with: result.map { RawTranscriptPage(items: $0.transcript.compactMap(Self.raw), nextToken: $0.nextToken) })
            }
        }
    }

    /// The vendor's own upload: start, upload, complete. It reads `file` after returning, so the
    /// caller keeps the file until this completes.
    func sendAttachment(file: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            session.sendAttachment(file: file) { c.resume(with: $0) }
        }
    }

    func attachmentDownloadURL(id: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<URL, Error>) in
            session.getAttachmentDownloadUrl(attachmentId: id) { c.resume(with: $0) }
        }
    }

    /// `DescribeView` straight through the SDK's `AWSClient` with the connection token it already
    /// holds — the same path `sendMessage` and receipts take, and the vendor's own `ChatService`
    /// does the same `View.Content` → dictionary mapping. The AWS response is read and converted
    /// to a ``ConnectViewDefinition`` inside the completion, before resume.
    func describeView(viewToken: String) async throws -> ConnectViewDefinition {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else {
            throw TouchpointError.transportFailure("not connected")
        }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<ConnectViewDefinition, Error>) in
            client.describeView(connectionToken: token, viewToken: viewToken) { result in
                switch result {
                case .success(let response):
                    var content: [String: Any] = [:]
                    if let view = response.view?.content {
                        if let actions = view.actions { content["Actions"] = actions }
                        if let inputSchema = view.inputSchema { content["InputSchema"] = inputSchema }
                        if let template = view.template { content["Template"] = template }
                    }
                    let view = response.view
                    c.resume(returning: ConnectViewDefinition.resolve(
                        id: view?.id, name: view?.name, version: view?.version,
                        content: content.isEmpty ? nil : content))
                case .failure(let error):
                    c.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Sign-in

    func enableAuthenticationEvents() async {
        lock.withLock { authenticationEnabled = true }
    }

    private func startListening() {
        let (enabled, token) = lock.withLock { (authenticationEnabled, participantToken) }
        guard enabled else { return }
        let websocketURL: @Sendable () async throws -> URL
        if client is TouchpointSignInSocketProviding {
            // A custom chat client: its backend mints the listen-only connection, so the
            // participant token stays off the device here too.
            websocketURL = { [weak self] in
                guard let provider = self?.client as? TouchpointSignInSocketProviding else {
                    throw TouchpointError.transportFailure("chat ended")
                }
                return try await provider.signInEventsWebSocketURL()
            }
        } else if let token {
            let region = region
            websocketURL = { try await Self.websocketURL(participantToken: token, region: region) }
        } else {
            return   // a custom client without the socket hook: `live` refuses that with sign-in on
        }
        listener.start(
            websocketURL: websocketURL,
            onOpen: { [weak self] in self?.catchUpAuthentication() },
            onEvent: { [weak self] event in self?.current?.onAuthenticationEvent(event.contentType, event.content, nil) })
    }

    /// Our own `CreateParticipantConnection`, not the vendor's: its `createParticipantConnection`
    /// asks for a connection token too, which would rotate the one the chat session holds.
    private static func websocketURL(participantToken: String, region: Region) async throws -> URL {
        let data = try await post("/participant/connection", ParticipantRequest.websocketOnlyConnection,
                                  bearerToken: participantToken, region: region)
        return try ParticipantRequest.websocketURL(fromConnectionReply: data)
    }

    /// Anything the listener missed while it was down (the app backgrounded, a reconnect): the
    /// newest sign-in item in the transcript, read through the vendor's own `AWSClient`, with its
    /// time so Connect's 60 s window is not reset.
    private func catchUpAuthentication() {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else { return }
        let request = GetTranscriptInput(connectionToken: token, maxResults: 15, scanDirection: .backward, sortOrder: .descending)
        client.getTranscript(getTranscriptArgs: request) { [weak self] result in
            guard case .success(let response) = result,
                  let item = response.transcript?.first(where: { ConnectChatTransport.authenticationStatus(for: $0.contentType ?? "") != nil }),
                  let type = item.contentType else { return }
            self?.current?.onAuthenticationEvent(type, item.content, item.absoluteTime)
        }
    }

    func authenticationURL(sessionID: String, redirectURI: URL) async throws -> URL {
        let data = try await participantPost("/participant/authentication-url", ["SessionId": sessionID, "RedirectUri": redirectURI.absoluteString])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let url = (object["AuthenticationUrl"] as? String).flatMap(URL.init(string:)) else {
            throw TouchpointError.malformedPayload("authentication-url reply")
        }
        return url
    }

    func cancelAuthentication(sessionID: String) async throws {
        _ = try await participantPost("/participant/cancel-authentication", ["SessionId": sessionID])
    }

    /// With the vendor's current connection token, read per call: it rotates on every reconnect.
    private func participantPost(_ path: String, _ body: [String: String]) async throws -> Data {
        guard let token = session.getConnectionDetailsProvider().getConnectionDetails()?.getConnectionToken() else {
            throw TouchpointError.transportFailure("not connected")
        }
        return try await Self.post(path, body, bearerToken: token, region: region)
    }

    /// The endpoint is the one the AWS SDK uses for this region (`participant.connect.<region>
    /// .amazonaws.com`); web uses the dual-stack `api.aws` host — a named deviation.
    private static func post(_ path: String, _ body: some Encodable, bearerToken: String, region: Region) async throws -> Data {
        guard let endpoint = ParticipantRequest.endpoint(region: region.rawValue) else {
            throw TouchpointError.invalidConfiguration("no participant endpoint for this region")
        }
        let request = try ParticipantRequest.make(endpoint: endpoint, path: path, bearerToken: bearerToken, body: body)
        let (data, response) = try await ParticipantRequest.session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else {
            // Status only: a reply body can echo request details.
            throw TouchpointError.httpFailure(statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0, responseBody: nil)
        }
        return data
    }

    // MARK: Upstream → raw

    /// The typed item plus the raw frame the SDK retains. `ParticipantId` only exists in the latter.
    static func raw(_ item: TranscriptItem) -> RawTranscriptItem? {
        var inner: [String: Any] = [:]
        if let s = item.serializedContent?["content"] as? String, let d = s.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            inner = obj
        }
        let pid = inner["ParticipantId"] as? String
        if let m = item as? AmazonConnectChatIOS.Message {
            var attachment: MessageAttachment?
            if let attachmentID = m.attachmentId {
                // `sendAttachment` posts a local placeholder (Sending, then Failed) under a made-up
                // id before Connect has the file; the server's echo comes back as the same object,
                // re-identified and Sent. Only the echo is a row — the composer shows the upload.
                if Self.isUploadPlaceholder(m.metadata?.status) { return nil }
                attachment = MessageAttachment(id: attachmentID, name: m.text, contentType: m.contentType)
            }
            return RawTranscriptItem(kind: .message, id: m.id, absoluteTime: m.timeStamp, contentType: m.contentType,
                                     participantRole: m.participant, participantID: pid, displayName: m.displayName ?? "",
                                     text: m.text, isOutgoing: m.messageDirection == .Outgoing, attachment: attachment)
        }
        if let e = item as? AmazonConnectChatIOS.Event {
            return RawTranscriptItem(kind: .event, id: e.id, absoluteTime: e.timeStamp, contentType: e.contentType,
                                     participantRole: e.participant ?? (inner["ParticipantRole"] as? String ?? ""),
                                     participantID: pid, displayName: e.displayName ?? "", text: e.text, isOutgoing: false)
        }
        return nil   // Metadata items are receipt state the SDK tracks for its own UI; we use the callbacks
    }

    static func isUploadPlaceholder(_ status: MessageStatus?) -> Bool {
        status == .Sending || status == .Failed
    }
}

public extension ConnectChatTransport {
    /// The production transport for an Amazon Connect instance in `region`.
    ///
    /// Register it with the session: `TouchpointSession(..., transports: [.chat: transport])`.
    ///
    /// - Parameter authentication: Turns on Connect's "Authenticate Customer" sign-in card. `nil`:
    ///   the flow's sign-in step is not offered and Connect eventually takes its timeout branch.
    static func live(region: Region, authentication: ChatAuthentication? = nil) -> ConnectChatTransport {
        ConnectChatTransport(driver: ConnectChatSessionDriver(region: region), authentication: authentication)
    }

    /// The same, with every Participant Service call routed through the host's own backend — web's
    /// `customChatClient` (`connect/conversation.ts`). Subclass the chat SDK's `AWSClient` (the
    /// iOS counterpart of chatjs's `ChatClient`, which web re-exports; from chat SDK 3.0 its
    /// methods take and return the AWS SDK for Swift's ConnectParticipant types) and override what
    /// the session uses: `createParticipantConnection`, `disconnectParticipantConnection`,
    /// `sendMessage`, `sendEvent`, `getTranscript`, and the attachment and `describeView` calls if
    /// the flow uses them. The host's `startChatContact` may then return no participant token.
    ///
    /// What still reaches the device: `createParticipantConnection` must return a websocket URL and
    /// a connection token, because the chat SDK opens the socket itself — as chatjs does on web.
    ///
    /// Sign-in (`authentication`) also needs a second, listen-only socket for Connect's sign-in
    /// events, which the chat SDK drops. Without a participant token the SDK cannot mint it, so the
    /// client must also conform to ``TouchpointSignInSocketProviding``; this throws
    /// `invalidConfiguration` if it does not. **iOS addition:** web hears those events on its one
    /// socket and needs no such hook.
    static func live(region: Region, authentication: ChatAuthentication? = nil,
                     customChatClient: AWSClient) throws -> ConnectChatTransport {
        if authentication != nil, !(customChatClient is TouchpointSignInSocketProviding) {
            throw TouchpointError.invalidConfiguration(
                "sign-in with a custom chat client needs it to conform to TouchpointSignInSocketProviding")
        }
        return ConnectChatTransport(driver: ConnectChatSessionDriver(region: region, customChatClient: customChatClient),
                                    authentication: authentication, usesCustomChatClient: true)
    }

    /// The same, from a region name such as `"ca-central-1"`, so a host does not import the vendor
    /// SDK only to spell a region. Throws `invalidConfiguration` for a string that is not shaped like
    /// a region name; a well-formed name of a region that does not exist fails at the first request.
    static func live(regionName: String, authentication: ChatAuthentication? = nil,
                     customChatClient: AWSClient? = nil) throws -> ConnectChatTransport {
        guard ParticipantRequest.isRegionName(regionName) else {
            throw TouchpointError.invalidConfiguration("not an AWS region name: \(regionName)")
        }
        let region = Region(regionName)
        if let customChatClient {
            return try live(region: region, authentication: authentication, customChatClient: customChatClient)
        }
        return live(region: region, authentication: authentication)
    }
}

/// A custom chat client that can also mint the listen-only socket sign-in needs:
/// `CreateParticipantConnection` with `Type: ["WEBSOCKET"]` only — no connection credentials, so
/// the session's connection token is not rotated — returning the socket URL. The host's backend
/// makes the call with the participant token it holds.
public protocol TouchpointSignInSocketProviding: AnyObject {
    func signInEventsWebSocketURL() async throws -> URL
}
#endif
