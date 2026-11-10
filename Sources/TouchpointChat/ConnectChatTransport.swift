import Foundation
import TouchpointCore

/// The production chat transport: translates the upstream SDK's callback API into
/// the coordinator's `TransportEvent` stream and closes the upstream gaps the design lists —
/// no `resendFailedMessage`, automatic `delivered` receipts for human-agent messages, typed errors
/// at the boundary.
///
/// **Ordering contract** (see `ContactTransport`): events are buffered until the first subscriber
/// attaches, so a consumer that connects before iterating `events` loses nothing.
///
/// **Our own echoes are dropped.** The server id of a sent message comes back in the send
/// acknowledgement, so the websocket echo of the same message carries nothing new; emitting it
/// would race the acknowledgement and risk two rows for one message.
public actor ConnectChatTransport: ContactTransport {
    let driver: any ChatSessionDriving
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var buffered: [TransportEvent] = []
    private var handlersInstalled = false
    /// `false` between `disconnect()` and the next `connect()`: frames the SDK raises in that window
    /// belong to a dead connection and are dropped, not buffered for a later subscriber.
    private var connected = false
    /// Bumped on every `connect`, `disconnect` and `release`. A `send` captures it and drops its
    /// acknowledgement if the epoch has moved on by the time the ack returns: an ack that
    /// lands after the connection went must not be yielded — buffered for the next contact, it would
    /// name a row that is not there.
    private var epoch = 0

    /// SDK callbacks arrive on the SDK's threads. Each one is enqueued **synchronously** onto this
    /// stream and consumed by a single task on the actor, so the order the SDK raised them in is
    /// the order the coordinator sees. (One detached `Task` per callback would not guarantee that.)
    private enum Inbound: Sendable {
        case connected, reestablished, broken, ended, item(RawTranscriptItem), receipt(ReceiptKind, String), typing(role: String)
        case authentication(contentType: String, content: String?, absoluteTime: String?)
    }
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var pump: Task<Void, Never>?

    /// Wire receipts go out on their own serial lane so a slow round trip never delays the frames
    /// behind it: `messageReceived` has already been yielded by the time a receipt is queued, and
    /// receipts have no ordering requirement relative to inbound frames — only among themselves.
    /// Receipts are **per connection**: the lane is rotated on `connect()` and closed on
    /// `disconnect()`, so a receipt queued before a drop can never go out on a later connection with
    /// a server id from the previous one.
    private var receiptContinuation: AsyncStream<String>.Continuation?
    private var receiptPump: Task<Void, Never>?

    /// Sign-in, when the host configured it; `nil` leaves Connect's sign-in events unheard.
    let authentication: ChatAuthentication?
    let now: @Sendable () -> ContinuousClock.Instant
    /// Whether the OS can match an https universal-link sign-in callback (iOS 17.4+). Injected so
    /// the availability gate is deterministic in tests; production uses the real runtime value.
    let supportsHTTPSCallback: Bool
    /// The host routes Participant Service calls through its own client (web's `customChatClient`),
    /// so a chat with no participant token is expected rather than a misconfiguration.
    let usesCustomChatClient: Bool
    private var authenticationEventsEnabled = false
    var auth = AuthenticationState()

    init(driver: any ChatSessionDriving, authentication: ChatAuthentication? = nil,
         usesCustomChatClient: Bool = false,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
         supportsHTTPSCallback: Bool = ChatAuthentication.runtimeSupportsHTTPSCallback) {
        self.driver = driver
        self.authentication = authentication
        self.usesCustomChatClient = usesCustomChatClient
        self.now = now
        self.supportsHTTPSCallback = supportsHTTPSCallback
        (inbox, inboxContinuation) = AsyncStream.makeStream(of: Inbound.self, bufferingPolicy: .unbounded)
    }

    deinit {
        inboxContinuation.finish()
        receiptContinuation?.finish()
        pump?.cancel()
        receiptPump?.cancel()
    }

    private func openReceiptLane() {
        receiptContinuation?.finish()
        receiptPump?.cancel()
        let (stream, cont) = AsyncStream.makeStream(of: String.self, bufferingPolicy: .unbounded)
        receiptContinuation = cont
        let driver = self.driver
        receiptPump = Task {
            for await sid in stream {
                // A cancelled `for await` still hands over the element it already buffered, so the
                // check is explicit: a receipt queued for a dead connection must not go out on the
                // next one (and the test for that was flaky under load for exactly this reason).
                if Task.isCancelled { return }
                try? await driver.sendReceipt(.delivered, messageID: sid)
            }
        }
    }

    private func closeReceiptLane() {
        receiptContinuation?.finish()
        receiptContinuation = nil
        receiptPump?.cancel()        // in-flight or queued receipts for the dead connection are abandoned
        receiptPump = nil
    }

    public nonisolated var events: AsyncStream<TransportEvent> {
        AsyncStream { cont in Task { await self.attach(cont) } }
    }

    private func attach(_ cont: AsyncStream<TransportEvent>.Continuation) {
        continuation?.finish()
        continuation = cont
        subscriberGeneration &+= 1
        let generation = subscriberGeneration
        for e in buffered { cont.yield(e) }
        buffered.removeAll()
        cont.onTermination = { [weak self] _ in
            Task { await self?.subscriberWentAway(generation) }
        }
    }

    /// Clears the continuation only if the subscriber that terminated is still the current one —
    /// a newer one may already have replaced it.
    private func subscriberWentAway(_ generation: Int) {
        if generation == subscriberGeneration { continuation = nil }
    }
    private var subscriberGeneration = 0

    func yield(_ e: TransportEvent) {
        // A subscriber that went away (the coordinator cancels its pump on teardown) leaves a
        // finished continuation behind, and `yield` into it reports `.terminated` rather than
        // failing. Buffer for the next subscriber instead: the next contact's `.connected` was
        // otherwise lost in the window before its pump attached, and the session sat in
        // `.connecting` for ever.
        if let continuation {
            if case .terminated = continuation.yield(e) {
                self.continuation = nil
                buffered.append(e)
            }
        } else {
            buffered.append(e)
        }
    }

    // MARK: ContactTransport

    public func connect(credentials: any ExpiringCredentials) async throws {
        guard let c = credentials as? ChatContactCredentials else {
            throw TouchpointError.invalidConfiguration("ConnectChatTransport needs ChatContactCredentials, got \(type(of: credentials))")
        }
        // **Deviation:** web only warns when there is neither a token nor a custom client
        // (`conversation.ts:816-821`) and the session then fails to authenticate; failing here
        // names the cause instead of a later transport error.
        guard c.participantToken != nil || usesCustomChatClient else {
            throw TouchpointError.invalidConfiguration("no participant token and no custom chat client")
        }
        if !handlersInstalled {
            let inbox = inboxContinuation
            await driver.setHandlers(ChatDriverHandlers(
                onConnected: { inbox.yield(.connected) },
                onReestablished: { inbox.yield(.reestablished) },
                onConnectionBroken: { inbox.yield(.broken) },
                onChatEnded: { inbox.yield(.ended) },
                onItem: { inbox.yield(.item($0)) },
                onReceipt: { inbox.yield(.receipt($0, $1)) },
                onTyping: { inbox.yield(.typing(role: $0)) },
                onAuthenticationEvent: { inbox.yield(.authentication(contentType: $0, content: $1, absoluteTime: $2)) }
            ))
            handlersInstalled = true
            let stream = self.inbox
            pump = Task { [weak self] in
                for await inbound in stream {
                    guard let self else { return }
                    await self.process(inbound)
                }
            }
        }
        if authentication != nil, !authenticationEventsEnabled {
            authenticationEventsEnabled = true
            await driver.enableAuthenticationEvents()
        }
        auth = AuthenticationState()   // a card belongs to one contact
        openReceiptLane()
        connected = true
        epoch &+= 1
        do { try await driver.connect(contactID: c.contactID, participantID: c.participantID, participantToken: c.participantToken) }
        catch {
            connected = false
            closeReceiptLane()
            buffered.removeAll()   // frames from a handshake that never came up must not reach a later subscriber
            throw Self.map(error)
        }
    }

    public func send(_ message: OutboundMessage) async throws {
        let ack: SentMessageAck
        let mine = epoch
        // A choice goes out as the interactive response web sends; everything else as plain text.
        let (body, contentType) = message.interactiveResponse.map { (String(decoding: $0.rawJSON, as: UTF8.self), ConnectContentType.interactiveResponse) }
            ?? (message.body, ConnectContentType.plainText)
        do { ack = try await driver.sendMessage(body, contentType: contentType) } catch { throw Self.map(error) }
        // Drop the ack if the connection it was sent on is gone: yielding it would either
        // buffer it for the next contact or name a row that contact does not have.
        guard connected, epoch == mine else { return }
        yield(.messageDelivered(clientMessageID: message.clientMessageID, serverMessageID: ack.serverMessageID, sequence: Self.sequence(ack.absoluteTime)))
    }

    public func disconnect() async {
        try? await driver.disconnect()
        connected = false
        epoch &+= 1
        closeReceiptLane()
        continuation?.finish()
        continuation = nil
        buffered.removeAll()      // nothing from this connection may leak into the next subscriber
    }

    /// Drop the socket but keep the server-side participant, so the contact can be resumed.
    /// Everything local is torn down exactly as in `disconnect()`; only the upstream call differs —
    /// `driver.release()` closes the websocket without `DisconnectParticipant`.
    public func release() async {
        try? await driver.release()
        connected = false
        epoch &+= 1
        closeReceiptLane()
        continuation?.finish()
        continuation = nil
        buffered.removeAll()
    }

    public func sendTyping() async {
        guard connected else { return }
        try? await driver.sendTyping()   // best effort, as web's is
    }

    public func sendAttachment(fileURL: URL) async throws {
        guard connected else { throw TouchpointError.invalidConfiguration("not connected") }
        do { try await driver.sendAttachment(file: fileURL) } catch { throw Self.map(error) }
    }

    public func attachmentURL(id: String) async throws -> URL {
        do { return try await driver.attachmentDownloadURL(id: id) } catch { throw Self.map(error) }
    }

    public func describeView(viewToken: String) async throws -> ConnectViewDefinition {
        do { return try await driver.describeView(viewToken: viewToken) } catch { throw Self.map(error) }
    }

    public func markRead(upTo serverMessageID: String) async throws {
        do { try await driver.sendReceipt(.read, messageID: serverMessageID) } catch { throw Self.map(error) }
    }

    public func fetchTranscript(before: String?, limit: Int) async throws -> TranscriptPage {
        let raw: RawTranscriptPage
        do { raw = try await driver.fetchTranscript(nextToken: before, maxResults: limit) } catch { throw Self.map(error) }
        var messages: [StoredMessage] = []
        var participantEvents: [TransportEvent] = []
        for item in raw.items {
            switch Self.normalise(item) {
            case .message(let m): messages.append(m)
            case .participant(let e): participantEvents.append(e)
            case .activity, .ignore: break   // a past interim message is not history
            }
        }
        let token = (raw.nextToken?.isEmpty ?? true) ? nil : raw.nextToken
        return TranscriptPage(messages: messages, participantEvents: participantEvents, nextToken: token)
    }

    /// The server's newest page as transcript lines (CV-1): a message's words as the transcript
    /// shows them — an interactive message by its title, a JSON message by its text, never raw
    /// JSON — and no files, interim lines, events or receipts. Web's file shows raw `Content`.
    public func fetchTranscriptEntries(limit: Int) async throws -> [TranscriptEntry] {
        let raw: RawTranscriptPage
        do { raw = try await driver.fetchTranscript(nextToken: nil, maxResults: limit) } catch { throw Self.map(error) }
        return raw.items.compactMap { item in
            guard item.kind == .message, item.attachment == nil, let text = item.text, !text.isEmpty else { return nil }
            if item.contentType == ConnectContentType.interactive, Self.interimText(Data(text.utf8)) != nil { return nil }
            let words = Self.content(contentType: item.contentType, text: text).body
            guard !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return TranscriptEntry(absoluteTime: item.absoluteTime, name: item.displayName.isEmpty ? item.participantRole : item.displayName,
                                   role: ParticipantRole(connectRole: item.participantRole), text: words)
        }
    }

    // MARK: Live frames

    private func process(_ inbound: Inbound) async {
        guard connected else { return }
        switch inbound {
        case .connected: yield(.connected)
        case .reestablished: yield(.reestablished)
        case .authentication(let contentType, let content, let time): handleAuthenticationEvent(contentType, content: content, absoluteTime: time)
        case .broken: yield(.disconnected(error: nil))
        case .ended: yield(.contactEnded(.agentEnded))
        case .item(let item): await handle(item)
        case .receipt(let kind, let id): yield(.receipt(serverMessageID: id, kind: kind))
        // Web ignores the customer's own typing echoed back (`conversation.ts:956-958`).
        case .typing(let role): if ParticipantRole(connectRole: role) != .customer { yield(.remoteActivity(.typing)) }
        }
    }

    private func handle(_ item: RawTranscriptItem) async {
        if item.kind == .message, item.isOutgoing { return }   // our echo — see the type comment
        switch Self.normalise(item) {
        case .message(let m):
            yield(.messageReceived(m))
            // `delivered` goes on the wire for messages a *person* sent; system and bot
            // announcements get none, and `read` stays host-driven. Queued, not awaited.
            if m.participantRole.isHuman, let sid = m.serverMessageID {
                receiptContinuation?.yield(sid)
            }
        case .participant(let e):
            yield(e)
        case .activity(let a):
            yield(.remoteActivity(a))
        case .ignore:
            break
        }
    }

    // MARK: Normalisation

    enum Normalised: Equatable {
        case message(StoredMessage)
        case participant(TransportEvent)
        /// Not a row: the flow's interim status line (`modalityPayload.type == "interim"`).
        case activity(RemoteActivity)
        case ignore
    }

    static func normalise(_ item: RawTranscriptItem) -> Normalised {
        let role = ParticipantRole(connectRole: item.participantRole)
        switch item.kind {
        case .event:
            switch item.contentType {
            case ConnectContentType.joined:
                guard let pid = item.participantID else { return .ignore }
                return .participant(.participantJoined(Participant(id: pid, role: role, displayName: item.displayName)))
            case ConnectContentType.left:
                guard let pid = item.participantID else { return .ignore }
                return .participant(.participantLeft(id: pid))
            default:
                return .ignore   // typing, receipts-as-items, transfer, authentication: not transcript content
            }
        case .message:
            if item.contentType == ConnectContentType.interactive, let text = interimText(Data((item.text ?? "").utf8)) {
                return .activity(.interim(text))
            }
            // An attachment's text is its file name; the pill draws it, so the body stays empty.
            let (body, interactive) = item.attachment.map { ("", InteractiveContent.attachment($0)) }
                ?? Self.content(contentType: item.contentType, text: item.text ?? "")
            let outgoing = item.isOutgoing || role == .customer
            return .message(StoredMessage(
                clientMessageID: UUID(),
                serverMessageID: item.id,
                body: body,
                direction: outgoing ? .outbound : .inbound,
                participantRole: role,
                participantID: item.participantID,
                sequence: sequence(item.absoluteTime),
                createdAt: Self.date(item.absoluteTime) ?? Date(),
                deliveryState: outgoing ? .sent : .delivered,
                interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) }
            ))
        }
    }

    /// The displayable body and the structured payload of a message, by content type. Raw JSON
    /// never reaches a transcript: the payload is kept in `interactive`, and the body is the words
    /// a person should read.
    ///
    /// - `interactive`: a template's title (or subtitle, as web falls back), or a modality's own
    ///   message text — see ``interactiveSummary(_:)``.
    /// - `interactive.response`: our own answer to a choice, as the transcript returns it. The body
    ///   is its `action` — the choice's text — so a reloaded conversation reads the same as the live
    ///   one did. Web drops every customer frame (`conversation.ts:814`) and has no reload to get
    ///   this wrong; this SDK reads history back from Connect, so it has to.
    /// - `application/json`, and plain text that is really a JSON envelope (web's own test:
    ///   starts with `{` and names `"modalities"`, `:913-916`): the texts of `messages`, each a
    ///   paragraph, or `text`. **Deviation:** web draws each entry of `messages` as its own
    ///   bubble; one Connect frame is one row here, so they share one.
    /// - Anything else is its text, verbatim.
    static func content(contentType: String, text: String) -> (body: String, interactive: InteractiveContent?) {
        let data = Data(text.utf8)
        switch contentType {
        case ConnectContentType.interactive:
            let (template, summary) = interactiveSummary(data)
            return (summary ?? "", InteractiveContent(templateType: template, rawJSON: data))
        case ConnectContentType.interactiveResponse:
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let template = obj?["templateType"] as? String ?? InteractiveContent.touchpointModalityTemplateType
            let title = ((obj?["data"] as? [String: Any])?["content"] as? [String: Any])?["title"] as? String
            let content = InteractiveContent(templateType: template, rawJSON: data)
            // A slot pick has no bubble (web draws none); read back from history it stays hidden,
            // and matches the hidden row the session stored when it was sent.
            if content.isSlotResponse { return ("", content) }
            // A Connect View submit (A7) is the same: the guide modal was the surface, the live send
            // stored an empty body, so a reload must read back the same. Web drops every customer
            // frame so it never shows this; this SDK reads history, so it hides it explicitly.
            if template == InteractiveContent.viewResourceResponseTemplateType { return ("", content) }
            return ((obj?["action"] as? String) ?? title ?? "", content)
        case ConnectContentType.json:
            return jsonContent(data, fallback: text)
        case ConnectContentType.plainText, ConnectContentType.markdown:
            if text.hasPrefix("{"), text.contains("\"modalities\"") { return jsonContent(data, fallback: text) }
            return (text, nil)
        default:
            return (text, nil)
        }
    }

    /// Web's `handleJsonMessage` (`conversation.ts:1012-1060`). Unparseable JSON is shown as its
    /// text, as web shows it, rather than dropped.
    private static func jsonContent(_ data: Data, fallback: String) -> (body: String, interactive: InteractiveContent?) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (fallback, nil) }
        let texts: [String]
        if let messages = obj["messages"] as? [Any], !messages.isEmpty {
            texts = messages.compactMap { ($0 as? [String: Any])?["text"] as? String }
        } else if let text = obj["text"] as? String {
            texts = [text]
        } else {
            texts = []
        }
        let body = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: "\n\n")
        return (body, InteractiveContent(templateType: InteractiveContent.jsonTemplateType, rawJSON: data))
    }

    /// Template type and the displayable text from an interactive payload, leniently.
    ///
    /// Two shapes matter. Connect's own templates (ListPicker and friends) put a human-readable
    /// string at `data.content.title`. A **TouchpointModality** — which is how cards, choices and
    /// the assistant's own prose arrive — instead carries
    /// `data.content.modalityPayload.{type, message, choices, modalities}`
    /// (`connect/conversation.ts:1091-1109`), and has no title at all.
    ///
    /// Reading only the title therefore threw away the assistant's words for every modality
    /// message, leaving an empty body, which the transcript then drew as a blank row. The message
    /// text is now taken from the payload when there is no title.
    ///
    /// `type: "interim"` is web's interim status line rather than transcript content
    /// (`:1108-1109`), so its text is deliberately *not* returned as a body — `normalise` turns the
    /// frame into ``RemoteActivity/interim(_:)`` instead (see ``interimText(_:)``).
    static func interactiveSummary(_ data: Data) -> (template: String, text: String?) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return ("unknown", nil) }
        let template = obj["templateType"] as? String ?? "unknown"
        let content = (obj["data"] as? [String: Any])?["content"] as? [String: Any]
        // Web reads `title ?? subtitle` for Connect's templates (`conversation.ts:1141-1144`).
        if let title = content?["title"] as? String, !title.isEmpty { return (template, title) }
        if let subtitle = content?["subtitle"] as? String, !subtitle.isEmpty { return (template, subtitle) }
        guard let payload = content?["modalityPayload"] as? [String: Any] else { return (template, nil) }
        guard (payload["type"] as? String) != "interim" else { return (template, nil) }
        let message = payload["message"] as? String
        return (template, (message?.isEmpty ?? true) ? nil : message)
    }

    /// The words of a TouchpointModality `interim` frame, which web shows as its interim message
    /// (`conversation.ts:1108-1109`); `nil` for anything else, or an interim with nothing to say.
    static func interimText(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = (obj["data"] as? [String: Any])?["content"] as? [String: Any],
              let payload = content["modalityPayload"] as? [String: Any],
              (payload["type"] as? String) == "interim",
              let message = payload["message"] as? String,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return message
    }

    /// Server `AbsoluteTime` → milliseconds since 1970. Connect has no ordinal, so this is the
    /// ordering authority (`Message.sequence`). `nil` if the string does not parse.
    static func sequence(_ absoluteTime: String) -> Int? {
        date(absoluteTime).map { Int(($0.timeIntervalSince1970 * 1000).rounded()) }
    }

    // `Date.ISO8601FormatStyle` is a Sendable value; `ISO8601DateFormatter` is not.
    static func date(_ s: String) -> Date? {
        (try? Date(s, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true)))
            ?? (try? Date(s, strategy: .iso8601))
    }

    // MARK: Errors

    /// Upstream has no typed errors; keep the domain and code, drop the description —
    /// it can carry a URL with a token in it.
    static func map(_ error: Error) -> TouchpointError {
        if let e = error as? TouchpointError { return e }
        let ns = error as NSError
        return .transportFailure("\(ns.domain)(\(ns.code))")
    }
}
