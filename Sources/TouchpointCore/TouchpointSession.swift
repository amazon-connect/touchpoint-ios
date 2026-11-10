import Foundation

/// The session coordinator. One active contact per session — an inherited limit of
/// the upstream chat SDK, documented rather than worked around.
///
/// Owns transports behind `ContactTransport`, normalises their events into one `ContactEvent`
/// stream, drives the store, and applies the two trust-boundary rules the design cares most about:
/// participants are a **set**, and Live Sync dispatch **suspends while a human agent is
/// present**. Every dependency is protocol-defined, so this is fully testable with no device.
@MainActor
public final class TouchpointSession {
    // MARK: Public surface

    public private(set) var state: ContactState = .idle {
        didSet { if state != oldValue { emit(.stateChanged(state)) } }
    }
    public private(set) var contactID: String?
    public private(set) var modality: Modality?

    /// A **new** stream per access, so the SDK's own UI and the host can both observe a contact, and
    /// a surface that goes away (a dismissed sheet) does not take the others' events with it.
    ///
    /// A subscriber that attaches mid-contact is **caught up**: the bounded replay of this contact's
    /// events, plus the current state, dispatch gate and participant set synthesised from live
    /// values. The replay is cleared when a contact ends, so a new contact never re-delivers an old
    /// one's messages.
    ///
    /// **Each access registers a subscriber, so iterate it or cancel the task that does.** The
    /// registration happens when the stream is created, not when iteration starts — that is how
    /// `AsyncStream` works — so a stream that is read and discarded holds its slot until the
    /// session is released. Buffering is bounded (`subscriberBuffer` events) so an abandoned
    /// stream cannot grow without limit, and a slot whose consumer has gone is reclaimed on the
    /// next event. Normal use — `for await event in session.events` inside a `task` — needs none of
    /// this: ending the task terminates the stream and frees the slot.
    public var events: AsyncStream<ContactEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(Self.subscriberBuffer)) { continuation in
            let id = UUID()
            // Replay, then the current state **only if the replay did not already carry it**. The
            // buffer is bounded, so the `.stateChanged` that produced the current state can have
            // been trimmed — and a subscriber that cannot tell whether the contact is connected
            // would disable its composer against a live one. Equally, a host reacting to every
            // transition must not be handed the same one twice.
            for event in replay { continuation.yield(event) }
            // Persistent conditions are *synthesised* from the live values rather than trusted to
            // survive in a bounded buffer: in a long conversation the event that set them is
            // evicted, and a surface that believed dispatch was enabled would be the failure the dispatch gate exists to prevent.
            let replayedCurrentState = replay.contains { if case .stateChanged(let s) = $0 { s == state } else { false } }
            if state != .idle, !replayedCurrentState { continuation.yield(.stateChanged(state)) }
            // Only the **suspended** state is synthesised, and only with the reason that actually
            // caused it. `.enabled` is the default, so a subscriber that hears nothing is already
            // correct; announcing it would mean inventing a transition that never happened.
            let replayedDispatch = replay.contains { if case .liveSyncDispatchChanged(let d, _) = $0 { d == dispatch } else { false } }
            if dispatch == .suspended, !replayedDispatch, let reason = dispatchReason {
                continuation.yield(.liveSyncDispatchChanged(.suspended, reason: reason))
            }
            // The participant set is as persistent as the other two, and its join events are the
            // first thing a long conversation evicts.
            let replayedParticipants = replay.contains { if case .participantsChanged(let p) = $0 { p == participants } else { false } }
            // Not once the contact is terminal: the set belonged to a conversation that is over,
            // and a host gating on `humanAgentPresent` would act on a stale fact.
            if participants.count > 0, !replayedParticipants, !isTerminal {
                continuation.yield(.participantsChanged(participants))
            }
            // The sign-in card holds the composer while pending; a late view must see it even when
            // the event that set it was evicted.
            let replayedCard = replay.contains { if case .authenticationChanged(let c) = $0 { c == authenticationCard } else { false } }
            if let authenticationCard, !replayedCard { continuation.yield(.authenticationChanged(authenticationCard)) }
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    /// `true` once a `LiveSyncControl` has been registered. Lets a host (and diagnostics)
    /// tell "chat-only, gating is a no-op by design" from "Live Sync linked but never registered".
    public var isLiveSyncRegistered: Bool { liveSync != nil }

    /// Called with each new message from the other side of the live contact, so the host can decide
    /// what to do with it — post a local notification, show an in-app banner, set a badge, or
    /// nothing. The SDK posts no notifications and needs no notification permission; it does not
    /// know whether the host's chat is on screen, which the host does.
    ///
    /// - **Live** (``IncomingMessages/Origin/live``): one call per inbound message as it arrives.
    /// - **Catch-up** (``IncomingMessages/Origin/catchUp``): the inbound messages missed while the
    ///   connection was down, reported once the transcript is reconciled after a reconnect or a
    ///   ``resume(contactID:)`` — normally in one call. Nothing when nothing was missed.
    ///
    /// Each message is reported **at most once**, and normally exactly once — but not always the
    /// same way: one that reaches the live connection before reconciliation stores it comes as
    /// `.live`, and a reconciliation interrupted by another drop reports its messages on the next
    /// one. A message stored by a reconciliation that never completes — the contact ends, or the app
    /// is terminated first — is not reported; it is in the transcript. Order across calls is not
    /// guaranteed; within a call it is oldest first.
    ///
    /// Never for the customer's own messages, typing, transcript notices, history already stored
    /// before the handler was set, or after the contact ends.
    ///
    /// **It runs only while the app runs.** The chat connection stops when iOS suspends the app,
    /// seconds after it is backgrounded, so a reply sent while suspended is not reported until the
    /// app returns and reconnects — then as catch-up. Reaching a suspended or terminated app needs
    /// remote (APNs) push, which this SDK does not provide.
    public var onIncomingMessages: (@MainActor (IncomingMessages) -> Void)?
    /// - Parameter ackTimeout: How long a send may wait for its acknowledgement on a live socket
    ///   before it is treated as lost and resent. The default suits Connect's latency.
    public init(
        broker: CredentialBroker,
        store: ConversationStore,
        transports: [Modality: any ContactTransport],
        reconnection: ReconnectionPolicy = .default,
        ackTimeout: Duration = .seconds(30)
    ) {
        self.broker = broker
        self.store = store
        self.transports = transports
        self.reconnection = reconnection
        self.ackTimeout = ackTimeout
    }

    deinit {
        for (_, c) in subscribers { c.finish() }
        pump?.cancel()
        reconnectTask?.cancel()
        reconcileRetry?.cancel()
        flushTask?.cancel()
        flushRetry?.cancel()
        ackWatchdog?.cancel()
    }

    /// `TouchpointLiveSync` registers here on creation. Nothing registered → the
    /// gating calls are no-ops. The session **retains** the control: a host that drops its own
    /// reference must not silently lose the dispatch safety gate (review M4).
    public func register(liveSync: any LiveSyncControl) { self.liveSync = liveSync }

    /// Start a chat contact. Throws if a contact is already active.
    public func startChat(_ request: ChatContactRequest) async throws {
        try await start(.chat) { try await self.broker.startChatContact(request) }
    }

    /// Start an outbound voice contact. Throws if a contact is already active.
    public func startVoice(_ request: VoiceContactRequest) async throws {
        try await start(.voice) { try await self.broker.startVoiceContact(request) }
    }

    private func start(_ modality: Modality, vend: () async throws -> any ExpiringCredentials) async throws {
        // Guard on `isStarting` as well as `isActive`: the first start is not yet `.active`
        // while it is still vending its backend contact, so a second start that checked only
        // `isActive` would slip through and vend a second contact. Nothing is torn down here — the
        // first start is untouched — so the caller simply learns a start is already under way.
        guard !isActive, !isStarting else { throw TouchpointError.invalidConfiguration("a contact is already active; call end() first") }
        guard let transport = transports[modality] else {
            throw TouchpointError.invalidConfiguration("no transport registered for \(modality.rawValue)")
        }
        // The vend is a backend round trip (1–2 s for StartWebRTCContact). An `end()` that lands in
        // that window must win locally: the credentials are discarded and nothing connects, so the
        // customer's end is honoured and no media or socket comes up. The contact the backend
        // already created is *not* ended — the SDK has no backend call for that — and is left to
        // Connect's own disconnect timeout. Closing it outright needs an `endContact` on
        // `TouchpointBackend`; tracked in the phase-7 open items.
        startGeneration &+= 1
        let generation = startGeneration
        isStarting = true
        defer { isStarting = false }
        let credentials = try await vend()
        guard generation == startGeneration else {
            throw TouchpointError.invalidConfiguration("start was cancelled by end() while credentials were being vended")
        }
        let id = Self.contactID(of: credentials)
        try await store.upsertConversation(contactID: id, modality: modality)
        // The store write is a second suspension inside the window `end()` treats as "starting".
        guard generation == startGeneration else {
            throw TouchpointError.invalidConfiguration("start was cancelled by end() while the conversation was being recorded")
        }
        contactID = id
        self.modality = modality
        self.credentials = credentials
        self.transport = transport
        participants = ParticipantSet()
        authenticationCard = nil
        attempt = 0
        reconnectStarted = nil          // a new contact gets a fresh reconnection budget
        contactGeneration &+= 1
        replay.removeAll()               // a new contact starts a new replay
        // Dispatch is per contact. A fresh contact has no participants, so inheriting the previous
        // one's suspension would leave Live Sync off with nothing left to re-enable it — the
        // previous contact's Live Sync was torn down at its end, so there is no transition to report.
        dispatch = .enabled
        dispatchReason = nil
        state = .connecting
        startPump(transport)
        // From here the contact exists and is `.connecting`, so an `end()` must tear it down like
        // any other rather than cancel a start that has nothing left to cancel.
        isStarting = false
        let contact = contactGeneration
        do {
            try await transport.connect(credentials: credentials)
        } catch {
            // An `end()` during the connect already tore the contact down; the connect failing as
            // a result is that end, not a second failure.
            guard contact == contactGeneration else {
                throw TouchpointError.invalidConfiguration("the contact ended while the transport was connecting")
            }
            // Thrown to the caller because there is one; the stream also sees the terminal
            // events so a UI bound only to `events` is not left in `.connecting`.
            await fail(with: Self.mapTransportError(error), end: .connectionLost)
            throw error
        }
        // A connect that completed after an `end()` tore the contact down must not leave it live.
        guard contact == contactGeneration else {
            await transport.disconnect()
            throw TouchpointError.invalidConfiguration("the contact ended while the transport was connecting")
        }
    }

    /// End the contact. Retains the conversation; queued messages become `failed`.
    public func end() async {
        if isStarting {
            // Nothing to tear down yet; cancel the start in flight. Its vend result is discarded.
            startGeneration &+= 1
            return
        }
        guard isActive || state == .suspended else { return }
        await teardown(reason: .customerEnded)
    }

    /// Resume after process termination or from a notification tap. Order is deliberate:
    /// rehydrate, restore the participant set, **default dispatch to suspended**, connect with the
    /// persisted credentials, reconcile the transcript with the server, and only then re-enable
    /// dispatch — and only if the reconciled set holds no human agent.
    ///
    /// Throws `.contactNotFound` when the conversation is unknown **or its credentials are gone**,
    /// which is the case for every contact that has ended: those stay readable through
    /// `transcript(contactID:)` but are not resumable on the wire.
    public func resume(contactID: String) async throws {
        guard !isActive else { throw TouchpointError.invalidConfiguration("a contact is already active") }
        guard let record = try await store.conversation(contactID: contactID) else { throw TouchpointError.contactNotFound }
        guard record.modality == .chat, let credentials = await broker.storedChatCredentials(contactID: contactID) else {
            throw TouchpointError.contactNotFound     // voice is not resumable (dead meeting); ended chats have no token
        }
        guard let transport = transports[.chat] else { throw TouchpointError.invalidConfiguration("no transport registered for chat") }
        self.contactID = contactID
        modality = .chat
        participants = record.participants
        authenticationCard = nil
        replay.removeAll()               // before the first emit, so resume's own events are replayable
        // Safe path first, before anything can dispatch.
        await setDispatch(.suspended, reason: .resumedUnreconciled)
        emit(.participantsChanged(participants))

        self.credentials = credentials
        self.transport = transport
        attempt = 0
        reconnectStarted = nil
        needsReconciliation = true
        contactGeneration &+= 1
        let contact = contactGeneration
        // Deliberately **not** resetting dispatch here: resume has just suspended it as the safe
        // default, and reconciliation is what earns the right to lift it.
        state = .connecting
        startPump(transport)
        do {
            try await transport.connect(credentials: credentials)
        } catch {
            // An `end()` during the connect already tore the contact down; the connect failing as a
            // result is that end, not a second failure, and must not run the failure path against
            // whatever contact is current now (mirroring `start`).
            guard contact == contactGeneration else {
                throw TouchpointError.invalidConfiguration("the contact ended while the transport was connecting")
            }
            await fail(with: Self.mapTransportError(error), end: .connectionLost)
            throw error
        }
        // A connect that completed after an `end()` tore the contact down must not leave it live.
        guard contact == contactGeneration else {
            await transport.disconnect()
            throw TouchpointError.invalidConfiguration("the contact ended while the transport was connecting")
        }
    }

    /// Host-driven read receipt: the host knows what is on screen. Marks every inbound
    /// message up to and including `clientMessageID` as read locally, and sends one `read` receipt
    /// on the wire for the newest of them. Idempotent.
    public func markMessagesRead(upTo clientMessageID: UUID) async throws {
        guard let contactID, let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        let rows = try await store.messages(contactID: contactID)
        guard let idx = rows.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { throw TouchpointError.contactNotFound }
        let unread = rows[...idx].filter { $0.direction == .inbound && $0.deliveryState == .delivered }
        guard !unread.isEmpty else { return }
        if let newest = unread.last(where: { $0.serverMessageID != nil }), let sid = newest.serverMessageID {
            try await transport.markRead(upTo: sid)
        }
        for m in unread { try await store.updateDeliveryState(clientMessageID: m.clientMessageID, to: .read) }
    }

    /// Queue a message: persist as `.sending` (the optimistic echo), then flush the outbox. Returns
    /// the client id — the idempotency key. Offline, the message simply waits; the next
    /// `.connected` flushes it. At-least-once with client-side deduplication.
    public func send(_ body: String) async throws -> UUID {
        guard let contactID, transport != nil else { throw TouchpointError.invalidConfiguration("no active contact") }
        let message = StoredMessage(clientMessageID: UUID(), body: body, direction: .outbound, participantRole: .customer, deliveryState: .sending)
        return try await enqueue(message, contactID: contactID)
    }

    /// Tell the agent the customer is typing — what a composer calls as the draft changes. Web's
    /// `sendTyping` (`conversation.ts:1902-1916`): at most one event per 2.5 s, since Connect
    /// expires typing after a few seconds anyway, best effort, and only on a live chat.
    public func sendTyping() async {
        guard state == .connected, modality == .chat, let transport else { return }
        let now = clock()
        if let last = lastTypingSent, now.timeIntervalSince(last) < Self.typingThrottle { return }
        lastTypingSent = now
        await transport.sendTyping()
    }
    package static let typingThrottle: TimeInterval = 2.5

    /// The current sign-in card, if the flow asked for one on this contact.
    public private(set) var authenticationCard: AuthenticationCard?

    /// The sign-in sheet's URL for the card on screen (web's `startAuthentication`). Throws when
    /// there is nothing to sign in to, or Connect's 60 s window has passed (the card then expires).
    public func beginAuthentication() async throws -> AuthenticationRequest {
        guard isActive, let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        return try await transport.beginAuthentication()
    }

    /// The redirect the sign-in sheet came back with. The card resolves on Connect's own event.
    public func completeAuthentication(callbackURL: URL) async throws {
        guard isActive, let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        try await transport.completeAuthentication(callbackURL: callbackURL)
    }

    /// Continue without signing in, or the sheet was closed: the flow takes its opted-out branch.
    public func cancelAuthentication() async {
        guard isActive, let transport else { return }
        await transport.cancelAuthentication()
    }

    /// Upload a file to the agent (web's `sendAttachment`). Only on a connected chat; Amazon
    /// Connect itself refuses one until a human agent has joined, so a surface offers it only then
    /// (see ``ParticipantSet/humanAgentPresent``). The row appears when Connect echoes it back.
    /// The file is read after this returns control to the vendor SDK, so pass one this app owns
    /// (a copy in its temporary directory), not a security-scoped picker URL.
    public func sendAttachment(fileURL: URL) async throws {
        guard state == .connected, modality == .chat, let transport else {
            throw TouchpointError.invalidConfiguration("attachments need a connected chat")
        }
        try await transport.sendAttachment(fileURL: fileURL)
    }

    /// The server's own transcript of the contact — its newest `limit` lines (at most 100), oldest
    /// first — as web's Download transcript reads it: Connect's times and display names, and the
    /// words of messages from every device, not only this one. Throws when there is no connection
    /// to ask; the local store is the fallback.
    public func serverTranscript(limit: Int = 100) async throws -> [TranscriptEntry] {
        guard let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        do { return try await transport.fetchTranscriptEntries(limit: min(max(limit, 1), 100)) }
        catch { throw Self.mapTransportError(error) }
    }

    /// A fresh download link for an attachment in this conversation. It expires; fetch one per use.
    public func attachmentURL(id: String) async throws -> URL {
        guard let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        return try await transport.attachmentURL(id: id)
    }
    private var lastTypingSent: Date?
    /// Injectable so the throttle is testable without sleeping.
    package var clock: @Sendable () -> Date = { Date() }

    /// Answer a choice a message offered. The transcript shows the choice's text as the customer's
    /// message, which is what web echoes (`Messages.tsx:777-791`); the wire carries the interactive
    /// response built by ``InteractiveContent/choiceResponse(_:)``. Same outbox, same delivery
    /// states and retry rules as ``send(_:)``: the response is persisted with the row, so a choice
    /// queued offline goes out as a choice after a relaunch rather than degrading to text.
    ///
    /// Throws `invalidConfiguration` with no active contact. A response past Connect's size limit
    /// is sent as the choice's text instead.
    @discardableResult
    public func sendChoice(_ choice: InteractiveChoice) async throws -> UUID {
        guard let contactID, transport != nil else { throw TouchpointError.invalidConfiguration("no active contact") }
        // Past Connect's limit for an interactive response, the choice goes as its words, as
        // Android sends it (CV-6): the conversation continues rather than the send failing. Web
        // drops it silently.
        let response = try? InteractiveContent.choiceResponse(choice)
        let message = StoredMessage(clientMessageID: UUID(), body: choice.text, direction: .outbound, participantRole: .customer,
                                    deliveryState: .sending, interactiveJSON: try response.map { try JSONEncoder().encode($0) })
        return try await enqueue(message, contactID: contactID)
    }

    /// Fill a slot from a modality: a carousel card tapped, a date picked. Web's `sendSlots`
    /// (`conversation.ts:1449-1460`): the wire carries a `structured.slots` request, and the
    /// transcript shows **no** customer bubble — the modality shows the pick itself. So the row is
    /// stored with an empty body, which the transcript does not draw, and it goes through the same
    /// outbox as any send, so a pick made offline goes out on reconnect.
    @discardableResult
    public func sendSlot(id: String, value: String) async throws -> UUID {
        guard let contactID, transport != nil else { throw TouchpointError.invalidConfiguration("no active contact") }
        let response = try InteractiveContent.slotResponse(id: id, value: value)
        let message = StoredMessage(clientMessageID: UUID(), body: "", direction: .outbound, participantRole: .customer,
                                    deliveryState: .sending, interactiveJSON: try JSONEncoder().encode(response))
        return try await enqueue(message, contactID: contactID)
    }

    /// Resolve a Connect View reference (its `viewToken`) into its definition, for the guide
    /// renderer — web's `describeView` (`conversation.ts:1655-1684`). Throws with no active contact,
    /// or if the transport does not carry Views.
    public func describeView(viewToken: String) async throws -> ConnectViewDefinition {
        guard let transport else { throw TouchpointError.invalidConfiguration("no active contact") }
        do { return try await transport.describeView(viewToken: viewToken) }
        catch { throw Self.mapTransportError(error) }
    }

    /// Submit a Connect View action back to the flow — web's `submitView` (`conversation.ts:1690-1703`).
    /// Goes through the same outbox as a choice, so a submit made offline goes out on reconnect.
    /// The transcript shows **no** customer bubble — the guide itself was the surface — so the row
    /// is stored with an empty body, like a slot pick. `data` is the renderer's output as a JSON
    /// object. Throws `invalidConfiguration` with no active contact, or past Connect's size limit.
    @discardableResult
    public func sendViewResponse(viewName: String?, action: String, data: Data) async throws -> UUID {
        guard let contactID, transport != nil else { throw TouchpointError.invalidConfiguration("no active contact") }
        let response = try InteractiveContent.viewResponse(viewName: viewName, action: action, dataJSON: data)
        let message = StoredMessage(clientMessageID: UUID(), body: "", direction: .outbound, participantRole: .customer,
                                    deliveryState: .sending, interactiveJSON: try JSONEncoder().encode(response))
        return try await enqueue(message, contactID: contactID)
    }

    private func enqueue(_ message: StoredMessage, contactID: String) async throws -> UUID {
        try await store.append(contactID: contactID, message: message)
        // The optimistic echo is an event like any other: a UI bound only to `events` must show the
        // bubble now, not when it next rebuilds from the store.
        emit(.messageReceived(Message(message)))
        if state == .connected { await scheduleFlush(generation: contactGeneration) }
        return message.clientMessageID
    }

    /// Start a flush for `generation` unless one is running, in which case ask the running one to
    /// go round again (it works off a snapshot; the newcomer may have been appended after it).
    private func scheduleFlush(generation: UInt) async {
        guard generation == contactGeneration, state == .connected else { return }
        // A flush in progress, a backoff retry pending, or a reconcile still running: coalesce into
        // it. A newcomer must never restart the loop ahead of the delay a failure earned, nor run
        // ahead of the reconcile that decides which of our messages the server already has.
        if flushTask != nil || flushRetry != nil || reconciling { flushRequested = true; return }
        flushToken &+= 1
        let token = flushToken
        flushTask = Task { [weak self] in
            guard let self else { return }
            await self.flushOutbox(generation: generation)
            guard token == self.flushToken else { return }   // a stale flush clears only its own reference
            self.flushTask = nil
            // A request that arrived as we were finishing must not be lost.
            if self.flushRequested { await self.scheduleFlush(generation: generation) }
        }
    }

    /// Send every unacknowledged outbound message **in composition order, one at a time**, stopping
    /// at the first failure so a later message never overtakes an earlier one. Each row is
    /// re-checked immediately before its send — an acknowledgement that landed, or an adoption by
    /// reconciliation, since the snapshot means it is no longer pending and must not go out again.
    /// A failure on a healthy connection retries with the reconnection backoff; the row stays
    /// `.sending` and the host sees `failed` each time. Generation-guarded: a result for a contact
    /// that ended while the send was in flight is discarded.
    private func flushOutbox(generation: UInt) async {
        // `Task.isCancelled`: a disconnect cancels this task; a loop suspended in `send` at that
        // moment must not resume and run alongside the reconnect's new flush.
        var live: Bool { generation == contactGeneration && state == .connected && !Task.isCancelled }
        repeat {
            flushRequested = false
            guard live, let contactID, let transport else { return }
            let pending: [StoredMessage]
            do {
                // One read for both lists. Two separate reads let a message appended between them
                // look unreadable — it was in the second list but not the first — and a send made
                // as the connection came up was failed without ever going out.
                let outbox = try await store.outbox(contactID: contactID)
                pending = outbox.readable
                // A pending row whose body cannot be read can never be sent: fail it now, visibly.
                for id in outbox.unreadable {
                    try await store.updateDeliveryState(clientMessageID: id, to: .failed)
                    emit(.deliveryStateChanged(DeliveryUpdate(clientMessageID: id, state: .failed)))
                }
            } catch { await flushFailed(.persistenceFailure("\(type(of: error))"), generation: generation); return }
            if pending.isEmpty { flushAttempt = 0; flushFirstFailure = nil; return }
            for m in pending {
                guard live else { return }
                let stillPending: Bool
                do { stillPending = try await store.isPending(clientMessageID: m.clientMessageID) }
                catch { await flushFailed(.persistenceFailure("\(type(of: error))"), generation: generation); return }   // stop, don't skip: order holds
                guard stillPending else { continue }
                if let sentAt = inFlight[m.clientMessageID] {
                    guard ContinuousClock.now - sentAt >= ackTimeout else { continue }   // ack still expected
                    inFlight[m.clientMessageID] = nil                                           // lost on a live socket: resend
                }
                inFlight[m.clientMessageID] = .now
                do {
                    try await transport.send(OutboundMessage(clientMessageID: m.clientMessageID, body: m.body,
                                                             interactiveResponse: Self.interactiveResponse(of: m)))
                } catch {
                    inFlight[m.clientMessageID] = nil
                    guard live else { return }
                    await flushFailed(Self.mapTransportError(error), generation: generation)
                    return
                }
                guard live else { return }
            }
            flushAttempt = 0; flushFirstFailure = nil
        } while flushRequested
        armAckWatchdog(generation: generation)
    }

    /// The interactive response an outbound row carries, if it answers a choice. Only an outbound
    /// row's own `TouchpointModality` envelope qualifies; anything else goes out as its text.
    static func interactiveResponse(of m: StoredMessage) -> InteractiveContent? {
        guard m.direction == .outbound, let data = m.interactiveJSON,
              let content = try? JSONDecoder().decode(InteractiveContent.self, from: data),
              content.templateType == InteractiveContent.touchpointModalityTemplateType
                || content.templateType == InteractiveContent.viewResourceResponseTemplateType else { return nil }
        return content
    }

    /// If anything is still awaiting its acknowledgement, wake a flush after `ackTimeout` so a
    /// lost ack on a socket that never drops is recovered rather than waited on forever.
    private func armAckWatchdog(generation: UInt) {
        ackWatchdog?.cancel()
        guard !inFlight.isEmpty else { ackWatchdog = nil; return }
        let timeout = ackTimeout
        ackWatchdog = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled, !self.inFlight.isEmpty else { return }
            await self.scheduleFlush(generation: generation)
        }
    }

    /// One failure path for transport and persistence errors alike: surface it, then retry with
    /// the reconnection backoff while the connection is healthy. The retry re-reads the whole
    /// outbox, so anything queued meanwhile rides with it. Budget spent → give up this burst; the
    /// next `send()` starts a fresh one.
    private func flushFailed(_ error: TouchpointError, generation: UInt) async {
        emit(.failed(error))
        flushAttempt += 1
        if flushFirstFailure == nil { flushFirstFailure = .now }
        let overBudget = flushFirstFailure.map { ContinuousClock.now - $0 > reconnection.totalBudget } ?? false
        guard flushAttempt <= reconnection.maxAttempts, !overBudget else {
            flushAttempt = 0; flushFirstFailure = nil
            armAckWatchdog(generation: generation)   // earlier sends in this burst may still be awaiting their acks
            return
        }
        let delay = reconnection.delay(forAttempt: flushAttempt)
        flushRequested = false
        flushRetry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.flushRetry = nil
            await self.scheduleFlush(generation: generation)
        }
    }

    /// The active conversation's transcript, projected.
    public func transcript() async throws -> [Message] {
        guard let contactID else { return [] }
        return try await transcript(contactID: contactID)
    }

    /// One page of the active conversation's transcript, oldest-first, walking backwards from
    /// `before`. The UI's "load earlier" path; `hasMore` tells it when to stop offering.
    public func earlierTranscript(before: Message?, limit: Int = 50) async throws -> (messages: [Message], hasMore: Bool) {
        guard let contactID else { return ([], false) }
        let slice = try await store.messages(contactID: contactID, before: before?.clientMessageID, limit: limit)
        return (slice.messages.map(Message.init), slice.hasMore)
    }

    /// Re-send a message whose delivery failed. Takes the `Message` rather than a string so the SDK
    /// can reject a message that did not fail, and so a later version can link the attempts. A failed row is terminal (`failed` is
    /// reachable only from `sending`), so this queues a **new** outbound message rather than
    /// resurrecting the old one: the failed row stays as the record of what happened, and each
    /// attempt carries its own idempotency key. Requires an active contact — a row only reaches
    /// `.failed` when a contact ends, so the host starts a new one first. Returns the new client id.
    @discardableResult
    public func resend(_ failed: Message) async throws -> UUID {
        guard failed.deliveryState == .failed else {
            throw TouchpointError.invalidConfiguration("resend is for a message whose delivery failed; this one is \(failed.deliveryState.rawValue)")
        }
        // A failed choice is retried as a choice: its row still carries the response it was sent with.
        if failed.direction == .outbound, let response = failed.interactive,
           response.templateType == InteractiveContent.touchpointModalityTemplateType {
            guard let contactID, transport != nil else { throw TouchpointError.invalidConfiguration("no active contact") }
            let message = StoredMessage(clientMessageID: UUID(), body: failed.body, direction: .outbound, participantRole: .customer,
                                        deliveryState: .sending, interactiveJSON: try JSONEncoder().encode(response))
            return try await enqueue(message, contactID: contactID)
        }
        return try await send(failed.body)
    }

    /// Any stored conversation's transcript — including ended ones, which are viewable but not
    /// resumable (retention).
    public func transcript(contactID: String) async throws -> [Message] {
        try await store.messages(contactID: contactID).map(Message.init)
    }

    public func participants() async throws -> ParticipantSet { participants }

    // MARK: Retention and erasure

    /// Removes one conversation, its messages, and its persisted credentials. Not allowed for the
    /// active contact; call `end()` first.
    public func deleteConversation(contactID: String) async throws {
        guard contactID != self.contactID || !isActive else { throw TouchpointError.invalidConfiguration("end() the active contact before deleting it") }
        try await store.deleteConversation(contactID: contactID)
        await broker.forgetContactCredentials(contactID: contactID)
    }

    /// Full wipe: every conversation, the field-encryption key, and every persisted contact credential.
    public func deleteAllConversations() async throws {
        guard !isActive else { throw TouchpointError.invalidConfiguration("end() the active contact before wiping") }
        let ids = try await store.allContactIDs()
        try await store.deleteAllConversations()
        for id in ids { await broker.forgetContactCredentials(contactID: id) }
    }

    /// Prunes conversations past the retention window, reaping their credentials with them.
    @discardableResult
    public func pruneExpiredConversations() async throws -> Int {
        let ids = try await store.pruneExpired()
        for id in ids { await broker.forgetContactCredentials(contactID: id) }
        return ids.count
    }

    // MARK: Internals

    private let broker: CredentialBroker
    private let store: ConversationStore
    private let transports: [Modality: any ContactTransport]
    private let reconnection: ReconnectionPolicy
    /// One continuation per live subscriber. A dropped subscriber removes itself via
    /// `onTermination`, so a dismissed sheet cannot silence the host.
    private var subscribers: [UUID: AsyncStream<ContactEvent>.Continuation] = [:]
    /// This contact's events, for catching a late subscriber up. Bounded: a long conversation's
    /// transcript is read from the store, not replayed through here.
    private var replay: [ContactEvent] = []
    private static let replayLimit = 200
    /// Per-subscriber buffer. Bounded so a stream nobody iterates cannot accumulate a conversation;
    /// generous enough that a briefly-busy consumer loses nothing.
    private static let subscriberBuffer = 500

    private var transport: (any ContactTransport)?
    private var credentials: (any ExpiringCredentials)?
    private var participants = ParticipantSet()
    private var dispatch: DispatchState = .enabled
    /// Why dispatch is in its current state, so a late subscriber is told the reason and not just
    /// the value. `nil` until something has actually changed it — there is no reason to invent.
    public private(set) var dispatchReason: DispatchChangeReason?
    /// The Live Sync dispatch gate as the session sees it. A `LiveSyncControl` registering
    /// mid-contact reads this to adopt the current state rather than assuming `.enabled`.
    public var dispatchState: DispatchState { dispatch }
    private var liveSync: (any LiveSyncControl)?
    private var pump: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var reconnectStarted: ContinuousClock.Instant?
    /// Set by `resume()` and `.disconnected`; consumed on the next `.connected` to pull the server transcript.
    private var needsReconciliation = false
    private var reconcileAttempt = 0
    private var reconcileRetry: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var flushRetry: Task<Void, Never>?
    private var flushRequested = false
    private var flushAttempt = 0
    private var flushFirstFailure: ContinuousClock.Instant?
    /// True from the post-connect reconcile until it succeeds (through any retries); flushes
    /// requested meanwhile run after it. Cleared on disconnect and teardown.
    private var reconciling = false
    /// Live participant joins/leaves seen *while* a reconcile is folding its pages. They are newer
    /// than anything the pages describe, so they are buffered and re-applied as a suffix once the
    /// fold is in: a page read before a live leave must not resurrect the agent who
    /// left, and dispatch must not lift until the whole history — pages then this suffix — is folded.
    private var liveParticipantEvents: [TransportEvent] = []
    /// True while the history is not yet established: a live leave must not lift dispatch in this
    /// window, because reconciliation has not yet said who else is on the contact.
    private var reconcilePending: Bool { needsReconciliation || reconciling }
    /// Identity of the current flush task (`Task` is not Equatable); a stale task that outlives a
    /// disconnect→reconnect must not clear a successor's reference.
    private var flushToken: UInt = 0
    /// Sent, acknowledgement not yet persisted, with the send time. Cleared when the ack lands, the
    /// connection drops (reconcile then adopts what the server has; the rest is resent), or the
    /// contact ends. An entry older than `ackTimeout` is treated as lost and resent.
    private var inFlight: [UUID: ContinuousClock.Instant] = [:]
    private var ackWatchdog: Task<Void, Never>?
    private let ackTimeout: Duration
    /// Bumped on every start, resume and teardown. Long-running work captures it and stops at the
    /// first await after which it no longer matches: a result for a contact that has since ended
    /// must not be emitted, persisted against the wrong row, or — above all — lift dispatch.
    private var contactGeneration: UInt = 0
    /// Inbound rows a reconcile appended but has not yet reported as catch-up, with the contact they
    /// belong to. On the session, not in `reconcile()`: a drop can abort a reconcile after it stored
    /// some rows, and the next reconcile sees those as duplicates — so they are carried to the next
    /// reconcile of the same contact that completes (a resume included), and dropped for another.
    private var pendingCatchUp: (contactID: String, messages: [Message]) = ("", [])
    /// Bumped by every `start` and by an `end()` that arrives during one's vend (see `start`).
    private var startGeneration: UInt = 0
    private var isStarting = false

    private var isTerminal: Bool { if case .ended = state { true } else { false } }

    /// Whether a contact is live on this session: connecting, connected, or reconnecting. `idle`,
    /// `suspended` and `ended` are not — note `contactID` stays set after an end so the ended
    /// conversation remains addressable, so this is the test for "something is on the wire".
    public var isActive: Bool {
        switch state {
        case .connecting, .connected, .reconnecting: true
        case .idle, .suspended, .ended: false
        }
    }

    /// Surface a security-relevant rejection the SDK's own UI detected — the guide renderer refusing
    /// to navigate the web view to a foreign origin (I6, BSC40). Routed to the host as
    /// ``ContactEvent/failed(_:)``, the same surface the transport's own rejections use. `package`
    /// so only the SDK's chat UI reaches it, not host code; the payload is non-sensitive.
    package func reportSecurityRejection(_ error: TouchpointError) {
        guard isActive else { return }
        emit(.failed(error))
    }

    private func emit(_ e: ContactEvent) {
        if Self.isReplayable(e) {
            replay.append(e)
            if replay.count > Self.replayLimit { replay.removeFirst(replay.count - Self.replayLimit) }
        }
        // Reclaim slots whose consumer has gone. `onTermination` covers the normal cases; this
        // catches a stream that was dropped without ever being iterated, whose continuation the
        // subscriber map itself was keeping alive.
        var dead: [UUID] = []
        for (id, c) in subscribers {
            if case .terminated = c.yield(e) { dead.append(id) }
        }
        for id in dead { subscribers[id] = nil }
    }

    /// What a late subscriber needs to reconstruct the contact: state, messages, delivery states,
    /// participants, and the **persistent** conditions — a suspended Live Sync dispatch and an
    /// outstanding permission request are still true when a new surface attaches, and a host that
    /// missed them would act as though the gate were open.
    ///
    /// Excluded are the genuinely momentary ones: replaying a `failed` from a blip that has since
    /// recovered would have a host raise an alert for a condition that no longer holds, and
    /// `transcriptReconciled` describes an event, not a state.
    private static func isReplayable(_ e: ContactEvent) -> Bool {
        switch e {
        case .stateChanged, .messageReceived, .deliveryStateChanged, .participantsChanged,
             .contactEnded, .liveSyncDispatchChanged, .notice, .authenticationChanged:
            true
        // `permissionRequired` is replayable in principle but nothing emits it yet: the microphone
        // prompt arrives with voice, which is where tracking an *outstanding* request
        // and synthesising it for a late subscriber belongs. Until then it would be a buffered event
        // with no live value behind it, so it is excluded rather than half-supported.
        case .permissionRequired:
            false
        case .failed, .transcriptReconciled:
            false
        // Typing a minute ago says nothing about now.
        case .remoteActivity:
            false
        }
    }

    private func startPump(_ transport: any ContactTransport) {
        pump?.cancel()
        let stream = transport.events
        // The generation this pump belongs to. A transport reused across contacts can deliver an
        // event buffered on an old connection — a late ack, a trailing receipt — after a new contact
        // has started; applying it would name a row that is not in the new contact. Dropping
        // anything whose generation no longer matches keeps one contact's wire traffic out of the
        // next. A disconnect/reconnect within a contact keeps the same generation, so a legitimate
        // post-reconnect ack is not dropped.
        let generation = contactGeneration
        pump = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                if await self.contactGeneration == generation { await self.handle(event) }
            }
        }
    }

    private func handle(_ event: TransportEvent) async {
        switch event {
        case .reestablished:
            // As a reconnect, without the reconnect: hold Live Sync, then reconcile what was missed.
            guard isActive else { return }
            if dispatch == .enabled { await setDispatch(.suspended, reason: .resumedUnreconciled) }
            needsReconciliation = true
            await handle(.connected)

        case .connected:
            attempt = 0
            reconnectStarted = nil
            state = .connected
            // Off the pump: both can take many round trips, and the pump must keep delivering
            // `.participantJoined` / `.disconnected` / `.contactEnded` meanwhile. One task, in this
            // order: **reconcile, then flush**. Reconcile adopts any send whose acknowledgement was
            // lost; a flush that ran first would send that message a second time.
            let reconcileFirst = needsReconciliation
            needsReconciliation = false
            reconcileAttempt = 0
            reconciling = reconcileFirst   // synchronously: a send() resuming before the task runs must still defer
            let generation = contactGeneration
            reconcileRetry?.cancel()
            reconcileRetry = Task { [weak self] in
                guard let self, self.contactGeneration == generation else { return }
                if reconcileFirst {
                    guard await self.reconcile() else { return }   // failed: outbox holds (reconciling stays true) until a retry succeeds
                    // A reconcile that was superseded — this task cancelled by a disconnect or
                    // teardown while it ran — must not release the outbox ahead of its successor
                    //. `reconcile` already clears `reconciling` on success; guard the flush.
                    guard !Task.isCancelled, self.contactGeneration == generation else { return }
                }
                await self.scheduleFlush(generation: generation)
            }

        case .disconnected(let error):
            guard isActive else { return }
            // Stop the flush and the reconcile **before** any await below: a flush left
            // runnable across the `postNotice`/`setDispatch` suspensions could send a message on the
            // dying connection unreconciled. Cancel first, then suspend dispatch, then reconnect.
            reconcileRetry?.cancel(); reconcileRetry = nil
            flushTask?.cancel(); flushTask = nil
            flushRetry?.cancel(); flushRetry = nil
            flushRequested = false; flushAttempt = 0; flushFirstFailure = nil; reconciling = false
            liveParticipantEvents.removeAll()
            ackWatchdog?.cancel(); ackWatchdog = nil
            inFlight.removeAll()   // nothing sent on the dead connection can be acknowledged on it; reconcile decides what the server has
            // Web appends "Connection lost" on every broken connection (`conversation.ts:944-952`).
            // Only a drop from a live connection: a failed reconnect attempt is the same outage.
            if state == .connected { await postNotice(.connectionLost) }
            // The live reconnect race. Live Sync must not replay ahead of reconciliation, so
            // dispatch goes off now and comes back only after the next `.connected` reconciles.
            if dispatch == .enabled { await setDispatch(.suspended, reason: .resumedUnreconciled) }
            needsReconciliation = true
            await scheduleReconnect(afterError: error)

        case .messageReceived(let message):
            guard let contactID else { return }
            do {
                // The wire-level `delivered` receipt is the transport's job; `read` is the host's.
                // Checked after the store's await by contact id, which is unique per start: an
                // `end()` and a new start inside it must not report the old contact's message under
                // the new one, while a resume of the same contact still reports it.
                if let new = try await appendAndEmit(contactID: contactID, message),
                   self.contactID == contactID, isActive {
                    onIncomingMessages?(IncomingMessages(contactID: contactID, messages: [new], origin: .live))
                }
            } catch {
                emit(.failed(.persistenceFailure("\(type(of: error))")))
            }

        case .messageDelivered(let clientID, let serverID, let sequence):
            do {
                if try await store.updateDeliveryState(clientMessageID: clientID, to: .sent, serverMessageID: serverID, sequence: sequence) {
                    emit(.deliveryStateChanged(DeliveryUpdate(clientMessageID: clientID, state: .sent, serverMessageID: MessageID(serverID), sequence: sequence)))
                }
                inFlight[clientID] = nil   // after the persist: until then the flush must still see it as in flight
            } catch {
                emit(.failed(.persistenceFailure("\(type(of: error))")))
            }

        case .receipt(let serverID, let kind):
            guard let contactID else { return }
            do {
                if let clientID = try await store.applyReceipt(contactID: contactID, serverMessageID: serverID, kind) {
                    emit(.deliveryStateChanged(DeliveryUpdate(clientMessageID: clientID, state: kind.deliveryState, serverMessageID: MessageID(serverID))))
                }
            } catch {
                emit(.failed(.persistenceFailure("\(type(of: error))")))
            }

        case .participantJoined(let p):
            if reconciling { liveParticipantEvents.append(event) }
            let hadAgent = participants.humanAgentPresent
            // Web: AGENT only, and once per arrival — a repeated join frame is not a second agent.
            if p.role == .agent, !participants.contains(p.id) { await postNotice(.agentJoined) }
            participants.join(p)
            await persistParticipants()
            if !hadAgent && participants.humanAgentPresent {
                await setDispatch(.suspended, reason: .humanAgentJoined)
            }

        case .participantLeft(let id):
            if reconciling { liveParticipantEvents.append(event) }
            let hadAgent = participants.humanAgentPresent
            if participants.participants.contains(where: { $0.id == id && $0.role == .agent }) { await postNotice(.agentLeft) }
            participants.leave(id)
            await persistParticipants()
            // Not before the history is in: a leave is not evidence that no one else is on the
            // contact until reconciliation has said who was. Reconciliation re-applies
            // this leave after its fold and makes the dispatch decision then.
            if hadAgent && !participants.humanAgentPresent && !reconcilePending {
                await setDispatch(.enabled, reason: .humanAgentLeft)
            }

        case .remoteActivity(let activity):
            // Live traffic only, and only while it can still mean something.
            guard state == .connected else { return }
            emit(.remoteActivity(activity))

        case .authenticationChanged(let id, let status):
            guard isActive else { return }
            // A card keeps the place it was first drawn: after the newest message when the flow asked.
            var after = authenticationCard?.id == id ? authenticationCard?.after : nil
            if authenticationCard?.id != id, let contactID {
                after = try? await store.messages(contactID: contactID, before: nil, limit: 1).messages.last?.clientMessageID
            }
            let card = AuthenticationCard(id: id, status: status, after: after)
            authenticationCard = card
            emit(.authenticationChanged(card))

        case .securityRejection(let error):
            // A rejection the transport made (a sign-in redirect that did not match). Non-terminal:
            // surface it to the host's error stream for a security log and carry on (I6, BSC40).
            guard isActive else { return }
            emit(.failed(error))

        case .contactEnded(let reason):
            await teardown(reason: reason)
        }
    }

    /// Reconcile with the server after a resume or reconnect. Pages **backwards from the newest**
    /// until the transcript is exhausted or `reconcileMaxPages` is hit, because the gate decision
    /// below needs the *whole* participant history: an agent's join can be older than the newest
    /// page, and lifting dispatch on a partial view would be the very failure the dispatch gate prevents. Events are
    /// folded oldest→newest once every page is in hand so a leave after a join reads correctly.
    /// Messages, like participant events, are applied **oldest first** once every page is in hand,
    /// so a host appending `messageReceived` events in arrival order renders the transcript in
    /// server order; the store deduplicates on server id. Adds and deduplicates only — server-side
    /// edits and deletions are out of scope for v1.
    @discardableResult
    private func reconcile() async -> Bool {
        guard let contactID, let transport else { return false }
        let generation = contactGeneration
        // True while this reconcile still belongs to the live contact. Checked after every await:
        // `end()` or a failure can tear the contact down while a page is in flight.
        var live: Bool { generation == contactGeneration && state == .connected }
        do {
            var pages: [TranscriptPage] = []
            var token: String? = nil
            repeat {
                let page = try await transport.fetchTranscript(before: token, limit: Self.reconcilePageSize)
                guard live else { return false }
                pages.append(page)
                token = page.nextToken
            } while token != nil && pages.count < Self.reconcileMaxPages
            let truncated = token != nil

            if pendingCatchUp.contactID != contactID { pendingCatchUp = (contactID, []) }
            for page in pages.reversed() {               // oldest page first
                for m in page.messages {
                    // Only into this contact's slot: a stale reconcile resuming here must not wipe
                    // the rows another contact's reconcile has collected.
                    if let new = try await appendAndEmit(contactID: contactID, m), pendingCatchUp.contactID == contactID {
                        pendingCatchUp.messages.append(new)
                    }
                    guard live else { return false }
                }
                for event in page.participantEvents { foldParticipant(event) }
            }
            // The live joins/leaves seen while the pages were in flight are newer than anything the
            // pages describe — a suffix of the true history. Re-applying them last leaves every
            // participant in its latest state, so a page read before a live leave cannot resurrect
            // the agent who left. Only now is the history complete.
            for event in liveParticipantEvents { foldParticipant(event) }
            liveParticipantEvents.removeAll()
            reconciling = false
            await persistParticipants()
            guard live else { return false }
            emit(.transcriptReconciled)
            if pendingCatchUp.contactID == contactID, !pendingCatchUp.messages.isEmpty {
                let caughtUp = pendingCatchUp.messages
                pendingCatchUp.messages = []
                onIncomingMessages?(IncomingMessages(contactID: contactID, messages: caughtUp, origin: .catchUp))
            }
            // Lift the suspension only on a complete history with no human present. A truncated
            // history is not evidence of absence, so dispatch stays off and the host is told.
            if dispatch == .suspended {
                if truncated {
                    emit(.failed(.transportFailure("transcript longer than \(Self.reconcileMaxPages * Self.reconcilePageSize) items; Live Sync dispatch stays suspended")))
                } else if !participants.humanAgentPresent {
                    await setDispatch(.enabled, reason: .transcriptReconciled)
                }
            }
            return true
        } catch {
            guard live else { return false }
            // Reconciliation failure is not fatal — the live stream still flows — but dispatch stays
            // suspended, because we could not establish that no agent is present. On a healthy
            // connection nothing else would ever lift it, so retry with the reconnection backoff
            // while connected; a disconnect cancels this and the next `.connected` starts afresh.
            emit(.failed(Self.mapTransportError(error)))
            reconcileAttempt += 1
            guard reconcileAttempt <= reconnection.maxAttempts else {
                // Give up holding the outbox: at-least-once beats a queue wedged for the life of
                // the connection. Live Sync dispatch stays suspended — that gate needs the history.
                emit(.failed(.transportFailure("transcript reconciliation gave up; queued messages are being sent without it")))
                reconciling = false
                // No later reconcile is coming on this healthy connection: report what the attempts
                // did store rather than strand it.
                if pendingCatchUp.contactID == contactID, !pendingCatchUp.messages.isEmpty {
                    let caughtUp = pendingCatchUp.messages
                    pendingCatchUp.messages = []
                    onIncomingMessages?(IncomingMessages(contactID: contactID, messages: caughtUp, origin: .catchUp))
                }
                await scheduleFlush(generation: generation)
                return false
            }
            let delay = reconnection.delay(forAttempt: reconcileAttempt)
            reconcileRetry = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard let self, !Task.isCancelled, self.contactGeneration == generation, self.state == .connected else { return }
                if await self.reconcile() {
                    // Same guard as the first reconcile: do not release the outbox if this
                    // retry was superseded while it ran.
                    guard !Task.isCancelled, self.contactGeneration == generation else { return }
                    await self.scheduleFlush(generation: generation)   // the outbox was holding for this
                }
            }
            return false
        }
    }

    private static let reconcilePageSize = 100
    /// 20 pages × 100 items. Connect caps a chat at far fewer; this bounds a runaway server.
    private static let reconcileMaxPages = 20

    /// Apply one participant event to the live set — the reconcile fold's only two operations.
    private func foldParticipant(_ event: TransportEvent) {
        switch event {
        case .participantJoined(let p): participants.join(p)
        case .participantLeft(let id): participants.leave(id)
        default: break
        }
    }

    /// Store a message from the server and tell the host what changed: a new row surfaces as
    /// `messageReceived`; an adopted echo (lost ack) surfaces as the `.sent` transition its
    /// `.sending` bubble is waiting for; a true duplicate is silent. Returns the new row when it is
    /// an **inbound** one — what ``onIncomingMessages`` reports — and `nil` otherwise.
    @discardableResult
    private func appendAndEmit(contactID: String, _ message: StoredMessage) async throws -> Message? {
        switch try await store.append(contactID: contactID, message: message) {
        case .appended:
            let new = Message(message)
            emit(.messageReceived(new))
            return new.direction == .inbound ? new : nil
        case .adopted(let clientID):
            inFlight[clientID] = nil
            emit(.deliveryStateChanged(DeliveryUpdate(clientMessageID: clientID, state: .sent,
                                                      serverMessageID: message.serverMessageID.map(MessageID.init(rawValue:)),
                                                      sequence: message.sequence)))
            return nil
        case .duplicate: return nil
        }
    }

    /// Emits a notice anchored after the newest stored message. Read from the store rather than
    /// tracked, so a resumed contact — whose history this session never emitted — anchors right.
    /// One row, not the transcript: a flapping connection posts one per drop.
    private func postNotice(_ kind: TranscriptNotice.Kind) async {
        var newest: UUID?
        if let contactID { newest = try? await store.messages(contactID: contactID, before: nil, limit: 1).messages.last?.clientMessageID }
        emit(.notice(TranscriptNotice(kind: kind, after: newest)))
    }

    private func persistParticipants() async {
        guard let contactID else { return }
        try? await store.setParticipants(contactID: contactID, participants)
        emit(.participantsChanged(participants))
    }

    private func setDispatch(_ newState: DispatchState, reason: DispatchChangeReason) async {
        dispatch = newState
        dispatchReason = reason
        switch newState {
        case .suspended: await liveSync?.suspendDispatch(reason: reason)
        case .enabled: await liveSync?.resumeDispatch()
        }
        emit(.liveSyncDispatchChanged(newState, reason: reason))
    }

    /// Bounded: attempt count and total time budget, then `.ended(.connectionLost)`.
    private func scheduleReconnect(afterError error: String?) async {
        reconnectTask?.cancel()
        // Chat retains the conversation and its outbox and reconnects within the budget. Voice
        // cannot rejoin a dead Chime meeting on new credentials, so it ends.
        if let modality, CredentialBroker.refreshFailurePolicy(for: modality) == .endContact {
            await fail(with: .transportFailure(error ?? "connection lost"), end: .connectionLost)
            return
        }
        if reconnectStarted == nil { reconnectStarted = .now }
        attempt += 1
        let overBudget = reconnectStarted.map { ContinuousClock.now - $0 > reconnection.totalBudget } ?? false
        guard attempt <= reconnection.maxAttempts, !overBudget else {
            await fail(with: .transportFailure(error ?? "connection lost after \(attempt - 1) attempt(s)"), end: .connectionLost)
            return
        }
        state = .reconnecting(attempt: attempt)
        let delay = reconnection.delay(forAttempt: attempt)
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, case .reconnecting = self.state else { return }
            guard let transport = self.transport, let credentials = self.credentials else { return }
            do {
                try await transport.connect(credentials: credentials)
            } catch {
                await self.scheduleReconnect(afterError: Self.mapTransportError(error).describeForEvent)
            }
        }
    }

    private func fail(with error: TouchpointError, end reason: EndReason) async {
        emit(.failed(error))
        await teardown(reason: reason)
    }

    private func teardown(reason: EndReason) async {
        contactGeneration &+= 1          // anything still awaiting for this contact stops at its next check
        authenticationCard = nil         // a card belongs to a contact that is over; no lock outlives it
        reconnectTask?.cancel(); reconnectTask = nil
        reconcileRetry?.cancel(); reconcileRetry = nil
        flushTask?.cancel(); flushTask = nil
        flushRetry?.cancel(); flushRetry = nil
        flushRequested = false; flushAttempt = 0; flushFirstFailure = nil; reconciling = false
        liveParticipantEvents.removeAll()
        ackWatchdog?.cancel(); ackWatchdog = nil
        inFlight.removeAll()
        pump?.cancel(); pump = nil
        // A lost connection may still be alive server-side, so drop only the socket and keep the
        // participant, leaving the contact resumable. Any other end — the customer or agent
        // ended it, a fatal failure — ends the participant.
        if reason == .connectionLost { await transport?.release() } else { await transport?.disconnect() }
        await liveSync?.teardown() // We own Live Sync teardown
        if let contactID {
            // At-least-once holds only for the contact lifetime; never drop an outbox silently.
            // Each stuck row gets its own `deliveryStateChanged(.failed)` — that is the contract; a
            // store error here is surfaced too rather than quietly skipping the sweep.
            do {
                for id in try await store.pendingClientIDs(contactID: contactID) {   // raw ids: an unreadable row is failed too
                    do {
                        try await store.updateDeliveryState(clientMessageID: id, to: .failed)
                        emit(.deliveryStateChanged(DeliveryUpdate(clientMessageID: id, state: .failed)))
                    } catch {
                        emit(.failed(.persistenceFailure("outbox sweep: \(type(of: error))")))   // one bad row does not stop the sweep
                    }
                }
            } catch {
                emit(.failed(.persistenceFailure("outbox sweep: \(type(of: error))")))
            }
        }
        // A token for an ended contact is dead weight in the Keychain. After a *lost
        // connection* the contact may still be alive server-side, so the token stays and
        // `resume(contactID:)` can try again.
        if reason != .connectionLost, let contactID { await broker.forgetContactCredentials(contactID: contactID) }
        transport = nil
        credentials = nil
        needsReconciliation = false
        state = .ended(reason)
        emit(.contactEnded(reason: reason))
        // Keep only the terminal events: a surface opening after the end should see that it ended,
        // not replay the whole finished conversation. Dispatch goes with it — Live Sync was torn
        // down above, so telling a new subscriber it is "suspended" would describe nothing.
        // Notices stay: messages come back from the store, but a notice exists only here, and an
        // ended chat on web still shows the agent leaving or the connection dropping.
        let notices = replay.filter { if case .notice = $0 { true } else { false } }
        replay = notices + [.stateChanged(.ended(reason)), .contactEnded(reason: reason)]
        dispatch = .enabled
        dispatchReason = nil
    }

    private static func contactID(of c: any ExpiringCredentials) -> String {
        switch c {
        case let c as ChatContactCredentials: c.contactID
        case let c as VoiceContactCredentials: c.contactID
        default: UUID().uuidString
        }
    }

    private static func mapTransportError(_ error: Error) -> TouchpointError {
        (error as? TouchpointError) ?? .transportFailure("\(type(of: error))")
    }
}

private extension TouchpointError {
    var describeForEvent: String {
        switch self {
        case .transportFailure(let s): s
        default: "\(self)"
        }
    }
}
