import Foundation
import Testing
@testable import TouchpointCore

/// Scriptable transport. Tests push `TransportEvent`s and control whether connect succeeds.
/// `events` hands out a stream bound to the *current* connection, like a real adapter would — a
/// coordinator that cached one stream across end()/start() would never see the second contact.
actor StubTransport: ContactTransport {
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var pendingStream: AsyncStream<TransportEvent>?
    var connectCalls = 0
    var disconnectCalls = 0
    var sent: [OutboundMessage] = []
    var failConnects = 0          // number of upcoming connects that should throw
    var autoConnectEvent = true   // emit .connected on successful connect
    var transcriptPage = TranscriptPage(messages: [], participantEvents: [], nextToken: nil)
    var pagesByToken: [String: TranscriptPage] = [:]     // older pages, keyed by the token that reaches them
    var fetchCalls: [(before: String?, limit: Int)] = []
    var readMarks: [String] = []
    var failFetches = 0
    var fetchDelay: Duration = .zero
    var failSends = 0            // upcoming sends that should throw
    var autoAck = false          // emit .messageDelivered for each successful send
    var echoBeforeAck = false    // emit the server echo of our own message before the ack (Connect can)
    var sendDelay: Duration = .zero
    var ackSeq = 1000

    init() {}

    nonisolated var events: AsyncStream<TransportEvent> {
        // Synchronous accessor required by the protocol; hop through a detached stream that is
        // fed by whichever continuation is live. Simpler: build the stream lazily on first access.
        AsyncStream { cont in
            Task { await self.attach(cont) }
        }
    }

    private var buffered: [TransportEvent] = []

    private func attach(_ cont: AsyncStream<TransportEvent>.Continuation) {
        continuation?.finish()
        continuation = cont
        for e in buffered { cont.yield(e) }
        buffered.removeAll()
    }

    private func yield(_ e: TransportEvent) {
        if let continuation { continuation.yield(e) } else { buffered.append(e) }
    }

    func setFailConnects(_ n: Int) { failConnects = n }
    func setTranscriptPage(_ p: TranscriptPage) { transcriptPage = p }
    func setOlderPage(token: String, _ p: TranscriptPage) { pagesByToken[token] = p }
    func setFailFetches(_ n: Int) { failFetches = n }
    func setFetchDelay(_ d: Duration) { fetchDelay = d }
    func fetchTranscript(before: String?, limit: Int) async throws -> TranscriptPage {
        fetchCalls.append((before, limit))
        if fetchDelay > .zero { try await Task.sleep(for: fetchDelay) }
        if failFetches > 0 { failFetches -= 1; throw TouchpointError.transportFailure("transcript unavailable") }
        if let before { return pagesByToken[before] ?? TranscriptPage(messages: [], participantEvents: [], nextToken: nil) }
        return transcriptPage
    }
    func markRead(upTo serverMessageID: String) async throws { readMarks.append(serverMessageID) }
    func setAutoConnectEvent(_ v: Bool) { autoConnectEvent = v }

    func connect(credentials: any ExpiringCredentials) async throws {
        connectCalls += 1
        if holdConnect { await withCheckedContinuation { connectGate = $0 } }
        if failConnects > 0 { failConnects -= 1; throw TouchpointError.transportFailure("stub refused") }
        if autoConnectEvent { yield(.connected) }
    }
    /// Holds the next connects open until `releaseConnect()`, to test what lands in that window.
    var holdConnect = false
    private var connectGate: CheckedContinuation<Void, Never>?
    func setHoldConnect(_ v: Bool) { holdConnect = v }
    func releaseConnect() { connectGate?.resume(); connectGate = nil }
    func setFailSends(_ n: Int) { failSends = n }
    func setAutoAck(_ v: Bool) { autoAck = v }
    func setEchoBeforeAck(_ v: Bool) { echoBeforeAck = v }
    func setSendDelay(_ d: Duration) { sendDelay = d }
    func send(_ message: OutboundMessage) async throws {
        if sendDelay > .zero { try? await Task.sleep(for: sendDelay) }
        if failSends > 0 { failSends -= 1; throw TouchpointError.transportFailure("send refused") }
        sent.append(message)
        ackSeq += 1
        let sid = "srv-\(message.clientMessageID.uuidString.prefix(8))"
        if echoBeforeAck {
            yield(.messageReceived(StoredMessage(clientMessageID: UUID(), serverMessageID: sid, body: message.body, direction: .outbound, participantRole: .customer, sequence: ackSeq, deliveryState: .sent)))
        }
        if autoAck { yield(.messageDelivered(clientMessageID: message.clientMessageID, serverMessageID: sid, sequence: ackSeq)) }
    }
    func disconnect() async { disconnectCalls += 1; continuation?.finish(); continuation = nil }
    var typingCalls = 0
    func sendTyping() async { typingCalls += 1 }
    func push(_ e: TransportEvent) { yield(e) }
}

final class RecordingLiveSync: LiveSyncControl, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    func suspendDispatch(reason: DispatchChangeReason) async { lock.withLock { calls.append("suspend:\(reason)") } }
    func resumeDispatch() async { lock.withLock { calls.append("resume") } }
    func teardown() async { lock.withLock { calls.append("teardown") } }
}

/// Collects events off the session for assertions, with a bounded wait.
actor EventCollector {
    var events: [ContactEvent] = []
    func add(_ e: ContactEvent) { events.append(e) }
    func states() -> [ContactState] { events.compactMap { if case .stateChanged(let s) = $0 { s } else { nil } } }
}

@MainActor
private func makeSession(transport: StubTransport, policy: ReconnectionPolicy = .init(maxAttempts: 2, totalBudget: .seconds(5), initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitterFactor: 0), liveSync: (any LiveSyncControl)? = nil) async throws -> (TouchpointSession, EventCollector, Task<Void, Never>) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-sess-\(UUID().uuidString)")
    let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
    let broker = CredentialBroker(backend: ScriptedBackend(), keychain: InMemoryKeychainStore())
    let session = TouchpointSession(broker: broker, store: store, transports: [.chat: transport], reconnection: policy)
    if let liveSync { session.register(liveSync: liveSync) }
    let collector = EventCollector()
    let stream = session.events
    let pump = Task { for await e in stream { await collector.add(e) } }
    return (session, collector, pump)
}

/// Like `makeSession`, but hands back the broker, store and keychain so a test can simulate a
/// process restart by building a second session over the same persistence.
@MainActor
private func makePersistentSession(transport: StubTransport, dir: URL, keychain: InMemoryKeychainStore, liveSync: (any LiveSyncControl)? = nil) async throws -> (TouchpointSession, EventCollector, Task<Void, Never>) {
    let store = try await ConversationStore(containerURL: dir, keychain: keychain)
    let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
    let session = TouchpointSession(broker: broker, store: store, transports: [.chat: transport], reconnection: .init(maxAttempts: 2, totalBudget: .seconds(5), initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitterFactor: 0))
    if let liveSync { session.register(liveSync: liveSync) }
    let collector = EventCollector()
    let stream = session.events
    let pump = Task { for await e in stream { await collector.add(e) } }
    return (session, collector, pump)
}

private func inbound(_ body: String, id: String, seq: Int, role: ParticipantRole = .agent) -> StoredMessage {
    StoredMessage(clientMessageID: UUID(), serverMessageID: id, body: body, direction: .inbound, participantRole: role, sequence: seq, deliveryState: .delivered)
}

@MainActor
private func eventually(_ timeout: Duration = .seconds(2), _ cond: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

@Suite("TouchpointSession", .serialized)
@MainActor
struct TouchpointSessionTests {
    @Test("Happy path: idle → connecting → connected, with a contactID")
    func happyPath() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        #expect(session.state == .idle)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        #expect(await eventually { session.state == .connected })
        #expect(session.contactID != nil)
        #expect(await eventually { (await collector.states()).prefix(2) == [.connecting, .connected] })
        pump.cancel()
    }

    @Test("A transport securityRejection surfaces to the host as .failed and is non-terminal")
    func securityRejectionSurfaces() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        #expect(await eventually { session.state == .connected })
        await t.push(.securityRejection(.invalidConfiguration("sign-in redirect did not match")))
        #expect(await eventually {
            await collector.events.contains { if case .failed(.invalidConfiguration(let s)) = $0 { s == "sign-in redirect did not match" } else { false } }
        })
        #expect(session.state == .connected, "non-terminal: the contact carries on")
        pump.cancel()
    }

    @Test("start() while a contact is active throws")
    func startWhileActiveThrows() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await #expect(throws: TouchpointError.self) {
            try await session.startChat(ChatContactRequest(displayName: "b"))
        }
        #expect(await t.connectCalls == 1)
        pump.cancel()
    }

    @Test("Inbound messages are persisted, surfaced, and auto-acknowledged delivered for agent messages")
    func inboundMessage() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.messageReceived(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "hello", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered)))
        #expect(await eventually { await collector.events.contains { if case .messageReceived(let m) = $0 { m.body == "hello" } else { false } } })
        let stored = try await session.transcript()
        #expect(stored.map(\.body) == ["hello"])
        pump.cancel()
    }

    @Test("A replayed frame with a known server id is deduplicated: no second row, no second event")
    func replayedFrameDeduplicated() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let frame = StoredMessage(clientMessageID: UUID(), serverMessageID: "sys-1", body: "Welcome", direction: .inbound, participantRole: .system, sequence: 1, deliveryState: .delivered)
        await t.push(.messageReceived(frame))
        await t.push(.messageReceived(frame))
        _ = await eventually { (try? await session.transcript().count) == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(try await session.transcript().count == 1)
        #expect(await collector.events.filter { if case .messageReceived = $0 { true } else { false } }.count == 1)
        pump.cancel()
    }

    @Test("send() persists an optimistic echo as .sending, then marks it .sent on receipt")
    func sendEcho() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("hi")
        #expect(try await session.transcript().first?.deliveryState == .sending)
        await t.push(.messageDelivered(clientMessageID: id, serverMessageID: "srv-1", sequence: 7))
        #expect(await eventually { (try? await session.transcript().first?.deliveryState) == .sent })
        #expect(try await session.transcript().first?.sequence == 7)
        pump.cancel()
    }

    @Test("Bounded reconnection: disconnect → reconnecting(1), (2) → ended(.connectionLost) + failed event")
    func boundedReconnection() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailConnects(10)
        await t.push(.disconnected(error: "socket closed"))
        #expect(await eventually(.seconds(3)) { session.state == .ended(.connectionLost) })
        let states = await collector.states()
        #expect(states.contains(.reconnecting(attempt: 1)))
        #expect(states.contains(.reconnecting(attempt: 2)))
        #expect(!states.contains(.reconnecting(attempt: 3)))
        #expect(await eventually { await collector.events.contains { if case .failed(.transportFailure) = $0 { true } else { false } } })
        #expect(await eventually { await collector.events.contains { if case .contactEnded(reason: .connectionLost) = $0 { true } else { false } } })
        #expect(await t.connectCalls == 3) // initial + 2 attempts
        pump.cancel()
    }

    @Test("A new contact after connectionLost starts with a fresh reconnection budget")
    func reconnectBudgetResetsPerContact() async throws {
        let t = StubTransport()
        // Tiny budget so a stale reconnectStarted from the first contact would trip immediately.
        let (session, collector, pump) = try await makeSession(transport: t, policy: .init(maxAttempts: 2, totalBudget: .milliseconds(150), initialDelay: .milliseconds(10), maxDelay: .milliseconds(10), jitterFactor: 0))
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailConnects(10)
        await t.push(.disconnected(error: nil))
        #expect(await eventually(.seconds(3)) { session.state == .ended(.connectionLost) })
        try await Task.sleep(for: .milliseconds(200))          // let the old budget window pass
        await t.setFailConnects(0)
        try await session.startChat(ChatContactRequest(displayName: "b"))
        _ = await eventually { session.state == .connected }
        let before = (await collector.states()).count
        await t.setFailConnects(1)                             // first reconnect attempt fails, second succeeds
        await t.push(.disconnected(error: nil))
        // Must enter reconnecting(1) and recover, not die instantly on a stale window.
        #expect(await eventually(.seconds(3)) {
            let states = await collector.states()
            return session.state == .connected && states.dropFirst(before).contains(.reconnecting(attempt: 1))
        })
        pump.cancel()
    }

    @Test("Reconnection that succeeds returns to connected and resets the attempt counter")
    func reconnectRecovers() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailConnects(1)
        await t.push(.disconnected(error: nil))
        #expect(await eventually(.seconds(3)) {
            let states = await collector.states()
            return session.state == .connected && states.contains(.reconnecting(attempt: 2))
        })
        pump.cancel()
    }

    @Test("end() disconnects the transport, tears down Live Sync, ends with customerEnded, returns to idle on next start")
    func endTearsDown() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, collector, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await session.end()
        #expect(session.state == .ended(.customerEnded))
        #expect(await t.disconnectCalls == 1)
        #expect(ls.calls.contains("teardown"))
        #expect(await eventually { await collector.events.contains { if case .contactEnded(reason: .customerEnded) = $0 { true } else { false } } })
        // A new contact after end is a new session, not a rebind.
        try await session.startChat(ChatContactRequest(displayName: "a"))
        #expect(await eventually { session.state == .connected })
        pump.cancel()
    }

    @Test("Participant set survives out-of-order join/leave and gates Live Sync dispatch")
    func participantsGateDispatch() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, collector, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let agent = Participant(id: "agent-1", role: .agent, displayName: "Sam")
        await t.push(.participantLeft(id: "agent-1"))      // stale leave first
        await t.push(.participantJoined(agent))
        #expect(await eventually { ls.calls.contains("suspend:humanAgentJoined") })
        #expect(await collector.events.contains { if case .liveSyncDispatchChanged(.suspended, reason: .humanAgentJoined) = $0 { true } else { false } })
        #expect(try await session.participants().humanAgentPresent)
        await t.push(.participantLeft(id: "agent-1"))
        #expect(await eventually { ls.calls.contains("resume") })
        #expect(await collector.events.contains { if case .liveSyncDispatchChanged(.enabled, reason: .humanAgentLeft) = $0 { true } else { false } })
        pump.cancel()
    }

    @Test("The session retains the registered LiveSyncControl so gating cannot silently vanish (M4)")
    func liveSyncRetained() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        do { let ls = RecordingLiveSync(); session.register(liveSync: ls) }   // caller drops its reference
        #expect(session.isLiveSyncRegistered)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.participantJoined(Participant(id: "a1", role: .agent, displayName: "A")))
        #expect(await eventually { session.isLiveSyncRegistered })
        pump.cancel()
    }

    @Test("Without a registered LiveSyncControl the gating calls are no-ops but events still fire")
    func noLiveSyncRegistered() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.participantJoined(Participant(id: "a1", role: .agent, displayName: "A")))
        #expect(await eventually { await collector.events.contains { if case .liveSyncDispatchChanged(.suspended, _) = $0 { true } else { false } } })
        pump.cancel()
    }

    @Test("Transport-reported contact end: outbox items still.sending become.failed and an event is surfaced")
    func contactEndFailsOutbox() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        _ = try await session.send("never acked")
        await t.push(.contactEnded(.agentEnded))
        #expect(await eventually { session.state == .ended(.agentEnded) })
        #expect(try await session.transcript().first?.deliveryState == .failed)
        #expect(await collector.events.contains { if case .deliveryStateChanged(let u) = $0 { u.state == .failed } else { false } })
        pump.cancel()
    }

    @Test("resume(contactID:) with a human agent in the persisted set suspends dispatch before anything connects")
    func resumeAgentPresentSuspends() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        await t.setAutoConnectEvent(false)      // hold the connection open so ordering is observable
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-sess-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        let creds = try await broker.startChatContact(ChatContactRequest(displayName: "seed"))   // persists the token
        try await store.upsertConversation(contactID: creds.contactID, modality: .chat)
        var set = ParticipantSet(); set.join(Participant(id: "a1", role: .agent, displayName: "A"))
        try await store.setParticipants(contactID: creds.contactID, set)
        let session = TouchpointSession(broker: broker, store: store, transports: [.chat: t])
        session.register(liveSync: ls)
        let collector = EventCollector(); let stream = session.events
        let pump = Task { for await e in stream { await collector.add(e) } }
        try await session.resume(contactID: creds.contactID)
        #expect(ls.calls.first == "suspend:resumedUnreconciled")
        #expect(await eventually { await collector.events.contains { if case .liveSyncDispatchChanged(.suspended, reason: .resumedUnreconciled) = $0 { true } else { false } } })
        #expect(session.contactID == creds.contactID)
        #expect(session.state == .connecting)
        #expect(await t.connectCalls == 1)
        #expect(!ls.calls.contains("resume"))
        pump.cancel()
    }

    @Test("resume(contactID:) for an unknown contact throws contactNotFound")
    func resumeUnknownThrows() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        await #expect(throws: TouchpointError.contactNotFound) { try await session.resume(contactID: "nope") }
        pump.cancel()
    }

    @Test("Starting a modality with no registered transport throws invalidConfiguration")
    func missingTransport() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        await #expect(throws: TouchpointError.self) {
            try await session.startVoice(VoiceContactRequest(displayName: "a"))
        }
        #expect(session.state == .idle)
        pump.cancel()
    }

    @Test("Reconnection delay is exponential, capped, and jitter is positive-only")
    func reconnectDelay() {
        let p = ReconnectionPolicy(initialDelay: .milliseconds(100), maxDelay: .seconds(1), jitterFactor: 0.5)
        #expect(p.delay(forAttempt: 1, random: 0) == .milliseconds(100))
        #expect(p.delay(forAttempt: 2, random: 0) == .milliseconds(200))
        #expect(p.delay(forAttempt: 10, random: 0) == .seconds(1))
        #expect(p.delay(forAttempt: 1, random: 1) == .milliseconds(150))
        #expect(p.delay(forAttempt: 1, random: 0) >= p.initialDelay)   // never below the base
    }

    // MARK: Resume completion, receipts, read marks, retain policy

    @Test("resume() after a restart re-connects with the persisted token, reconciles, then re-enables dispatch when no agent is present")
    func resumeReconnectsAndReconciles() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-resume-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let ls = RecordingLiveSync()
        var contactID = ""
        do {   // process 1
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            await t.push(.messageReceived(inbound("welcome", id: "s1", seq: 100, role: .system)))
            _ = await eventually { (try? await session.transcript().count) == 1 }
            contactID = session.contactID ?? ""
            pump.cancel()
            // no end(): the process dies here
        }
        // process 2
        let t = StubTransport()
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("welcome", id: "s1", seq: 100, role: .system), inbound("hello again", id: "s2", seq: 101)], participantEvents: [], nextToken: nil))
        let (session, collector, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        try await session.resume(contactID: contactID)
        #expect(await eventually { session.state == .connected })
        #expect(await t.connectCalls == 1)
        #expect(await eventually { (await collector.events).contains { if case .transcriptReconciled = $0 { true } else { false } } })
        let transcript = try await session.transcript()
        #expect(transcript.map(\.body) == ["welcome", "hello again"])             // s1 deduplicated, s2 added
        // Dispatch: suspended first (safe path), enabled only after reconciliation found no human agent.
        let calls = ls.calls
        #expect(calls.first == "suspend:resumedUnreconciled")
        #expect(calls.last == "resume")
        #expect(await t.fetchCalls.count == 1)
        pump.cancel()
    }

    @Test("resume() keeps dispatch suspended when the reconciled transcript shows a human agent on the contact")
    func resumeKeepsSuspendedWithAgent() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-resume-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let ls = RecordingLiveSync()
        let t = StubTransport()
        await t.setTranscriptPage(TranscriptPage(messages: [], participantEvents: [.participantJoined(Participant(id: "ag", role: .supervisor, displayName: "Sup"))], nextToken: nil))
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        try await session.resume(contactID: contactID)
        _ = await eventually { session.state == .connected }
        _ = await eventually { await t.fetchCalls.count == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!ls.calls.contains("resume"))
        #expect(try await session.participants().humanAgentPresent)
        pump.cancel()
    }

    @Test("resume() of a conversation whose credentials are gone (contact ended) throws contactNotFound; the transcript stays readable")
    func resumeWithoutCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-resume-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let t = StubTransport()
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = session.contactID ?? ""
        await t.push(.messageReceived(inbound("bye", id: "s1", seq: 1)))
        _ = await eventually { (try? await session.transcript().count) == 1 }
        await session.end()
        await #expect(throws: TouchpointError.contactNotFound) { try await session.resume(contactID: id) }
        #expect(try await session.transcript(contactID: id).map(\.body) == ["bye"])
        pump.cancel()
    }

    @Test("Receipts from the transport move our outbound messages forward through sent → delivered → read and surface one event each")
    func receiptsAdvanceDeliveryState() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("hi")
        await t.push(.messageDelivered(clientMessageID: id, serverMessageID: "s1", sequence: 7))
        await t.push(.receipt(serverMessageID: "s1", kind: .delivered))
        await t.push(.receipt(serverMessageID: "s1", kind: .read))
        #expect(await eventually { (try? await session.transcript().first?.deliveryState) == .read })
        let changes = await collector.events.compactMap { if case .deliveryStateChanged(let u) = $0, u.clientMessageID == id { u.state } else { nil } }
        #expect(changes == [.sent, .delivered, .read])
        pump.cancel()
    }

    @Test("markMessagesRead(upTo:) sends one read receipt on the wire for the newest inbound message and marks the rows read")
    func markReadIsHostDriven() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.messageReceived(inbound("one", id: "s1", seq: 1)))
        await t.push(.messageReceived(inbound("two", id: "s2", seq: 2)))
        _ = await eventually { (try? await session.transcript().count) == 2 }
        let two = try await session.transcript().last!
        try await session.markMessagesRead(upTo: two.clientMessageID)
        #expect(await t.readMarks == ["s2"])
        #expect(try await session.transcript().map(\.deliveryState) == [.read, .read])
        // Idempotent: nothing new to mark, nothing sent.
        try await session.markMessagesRead(upTo: two.clientMessageID)
        #expect(await t.readMarks == ["s2"])
        pump.cancel()
    }

    @Test("Chat retains the conversation and its unsent outbox across a lost connection (retainAndReconnect)")
    func chatRetainsAcrossReconnect() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setAutoConnectEvent(false)
        await t.push(.disconnected(error: nil))
        _ = await eventually { if case .reconnecting = session.state { true } else { false } }
        let queued = try await session.send("while offline")
        await t.setAutoConnectEvent(true)
        await t.push(.connected)
        _ = await eventually { session.state == .connected }
        let rows = try await session.transcript()
        #expect(rows.map(\.clientMessageID) == [queued])
        #expect(rows.first?.deliveryState == .sending) // retained; the outbox flushes it
        pump.cancel()
    }

    // MARK: Adversarial round

    @Test("A lost connection retains the credentials so the contact stays resumable; end() forgets them")
    func connectionLostRetainsCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-cl-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let t = StubTransport()
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = session.contactID ?? ""
        await t.setFailConnects(5)
        await t.push(.disconnected(error: nil))
        #expect(await eventually(.seconds(3)) { session.state == .ended(.connectionLost) })
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        #expect(await broker.storedChatCredentials(contactID: id) != nil)
        pump.cancel()
    }

    @Test("Voice ends on the first disconnect rather than reconnecting (refreshFailurePolicy .endContact)")
    func voiceEndsOnDisconnect() async throws {
        let t = StubTransport()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-voice-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let session = TouchpointSession(broker: CredentialBroker(backend: ScriptedBackend(), keychain: InMemoryKeychainStore()), store: store, transports: [.voice: t])
        try await session.startVoice(VoiceContactRequest(displayName: "v"))
        _ = await eventually { session.state == .connected }
        await t.push(.disconnected(error: "rtc gone"))
        #expect(await eventually { session.state == .ended(.connectionLost) })
        #expect(await t.connectCalls == 1)
    }

    @Test("A mid-session reconnect suspends dispatch until the transcript is reconciled, then lifts it")
    func reconnectReconciles() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, collector, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("missed while offline", id: "s5", seq: 5)], participantEvents: [], nextToken: nil))
        await t.push(.disconnected(error: nil))
        _ = await eventually { session.state == .connected }
        #expect(await eventually { (await collector.events).contains { if case .transcriptReconciled = $0 { true } else { false } } })
        #expect(try await session.transcript().map(\.body) == ["missed while offline"])
        #expect(ls.calls == ["suspend:resumedUnreconciled", "resume"])
        pump.cancel()
    }

    @Test("deleteConversation and deleteAllConversations also forget the persisted contact credentials")
    func deleteForgetsCredentials() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-del-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let t = StubTransport()
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = session.contactID ?? ""
        await t.setFailConnects(5); await t.push(.disconnected(error: nil))
        _ = await eventually(.seconds(3)) { session.state == .ended(.connectionLost) }
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        #expect(await broker.storedChatCredentials(contactID: id) != nil)
        try await session.deleteConversation(contactID: id)
        #expect(await broker.storedChatCredentials(contactID: id) == nil)
        #expect(try await session.transcript(contactID: id).isEmpty)
        pump.cancel()
    }

    // MARK: Review round

    @Test("Reconciliation pages back until the participant history is complete: an agent join older than the newest page still gates dispatch")
    func reconcilePagesForParticipants() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-page-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let ls = RecordingLiveSync()
        let t = StubTransport()
        // Newest page: 100 chatty messages, no participant events, more history behind it.
        await t.setTranscriptPage(TranscriptPage(messages: (1...100).map { inbound("m\($0)", id: "s\($0)", seq: 1000 + $0) }, participantEvents: [], nextToken: "older-1"))
        // The page before it holds the agent join.
        await t.setOlderPage(token: "older-1", TranscriptPage(messages: [], participantEvents: [.participantJoined(Participant(id: "ag", role: .agent, displayName: "Ann"))], nextToken: "older-2"))
        await t.setOlderPage(token: "older-2", TranscriptPage(messages: [inbound("welcome", id: "s0", seq: 1)], participantEvents: [], nextToken: nil))
        let (session, collector, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        try await session.resume(contactID: contactID)
        _ = await eventually { session.state == .connected }
        #expect(await eventually(.seconds(3)) { (await collector.events).contains { if case .transcriptReconciled = $0 { true } else { false } } })
        #expect(await t.fetchCalls.map(\.before) == [nil, "older-1", "older-2"])
        #expect(!ls.calls.contains("resume"))
        #expect(try await session.participants().humanAgentPresent)
        #expect(try await session.transcript().count == 101)
        // The event stream delivered the history oldest-first across pages, not page-by-page newest-first.
        let streamed = await collector.events.compactMap { if case .messageReceived(let m) = $0 { m.body } else { nil } }
        #expect(streamed.first == "welcome" && streamed.last == "m100" && streamed.count == 101)
        pump.cancel()
    }

    @Test("Participant join and leave are folded in server order across pages: a leave after a join lifts dispatch")
    func reconcileFoldsInServerOrder() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-order-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let ls = RecordingLiveSync()
        let t = StubTransport()
        await t.setTranscriptPage(TranscriptPage(messages: [], participantEvents: [.participantLeft(id: "ag")], nextToken: "older"))
        await t.setOlderPage(token: "older", TranscriptPage(messages: [], participantEvents: [.participantJoined(Participant(id: "ag", role: .agent, displayName: "Ann"))], nextToken: nil))
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        try await session.resume(contactID: contactID)
        #expect(await eventually(.seconds(3)) { ls.calls.last == "resume" })
        #expect(try await session.participants().humanAgentPresent == false)
        pump.cancel()
    }

    @Test("An adopted echo (lost ack) surfaces as deliveryStateChanged(.sent) for the bubble the host is already showing")
    func adoptedEchoEmitsSent() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("pay my bill")        // stub transport never acks
        // The server echo of that message arrives via the live stream (e.g. after a reconnect replay).
        await t.push(.messageReceived(StoredMessage(clientMessageID: UUID(), serverMessageID: "srv-7", body: "pay my bill", direction: .outbound, participantRole: .customer, sequence: 70, deliveryState: .sent)))
        #expect(await eventually { (await collector.events).contains { if case .deliveryStateChanged(let u) = $0 { u.clientMessageID == id && u.state == .sent } else { false } } })
        let rows = try await session.transcript()
        #expect(rows.count == 1 && rows[0].id == id && rows[0].serverMessageID == MessageID("srv-7") && rows[0].deliveryState == .sent)
        // One messageReceived: our own optimistic echo. The server's copy adopts that row instead
        // of surfacing a second message.
        let received = await collector.events.filter { if case .messageReceived = $0 { true } else { false } }
        #expect(received.count == 1)
        pump.cancel()
    }

    @Test("A transient reconciliation failure is retried on a healthy connection; dispatch lifts once it succeeds")
    func reconcileRetriesAfterFailure() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, collector, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailFetches(2)
        await t.push(.disconnected(error: nil))
        _ = await eventually { session.state == .connected }
        // Two failures surface, then the retry succeeds without any further disconnect.
        #expect(await eventually(.seconds(5)) { await t.fetchCalls.count >= 3 })
        #expect(await eventually(.seconds(5)) { ls.calls.last == "resume" })
        #expect(await collector.events.filter { if case .failed = $0 { true } else { false } }.count == 2)
        #expect(session.state == .connected)
        pump.cancel()
    }

    @Test("end during reconciliation never re-enables dispatch or emits after contactEnded")
    func endDuringReconcileIsSafe() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-endrec-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let ls = RecordingLiveSync()
        let t = StubTransport()
        await t.setFetchDelay(.milliseconds(300))      // reconcile is mid-flight when end() lands
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("late page", id: "s1", seq: 1)], participantEvents: [], nextToken: nil))
        let (session, collector, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        try await session.resume(contactID: contactID)
        _ = await eventually { await t.fetchCalls.count == 1 }
        await session.end()
        #expect(session.state == .ended(.customerEnded))
        try await Task.sleep(for: .milliseconds(500))  // let the delayed fetch complete
        #expect(!ls.calls.contains("resume"))
        let events = await collector.events
        let endIdx = try #require(events.firstIndex { if case .contactEnded = $0 { true } else { false } })
        let after = events[endIdx...].dropFirst()
        #expect(after.isEmpty, "events after contactEnded: \(after.count)")
        pump.cancel()
    }

    // MARK: Adversarial round

    @Test("send() surfaces the optimistic echo as an event, so a UI bound only to events shows the bubble at once")
    func sendEmitsEcho() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("hello there")
        #expect(await eventually { (await collector.events).contains { if case .messageReceived(let m) = $0 { m.clientMessageID == id && m.body == "hello there" && m.direction == .outbound } else { false } } })
        pump.cancel()
    }

    @Test("Every subscriber gets events, including one that attaches after an earlier one stopped")
    func multipleSubscribers() async throws {
        let t = StubTransport()
        let (session, first, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        // A second subscriber attaches alongside the first.
        let second = EventCollector()
        let s2 = session.events
        let pump2 = Task { for await e in s2 { await second.add(e) } }
        await t.push(.messageReceived(inbound("one", id: "s1", seq: 1)))
        #expect(await eventually { (await second.events).contains { if case .messageReceived = $0 { true } else { false } } })
        #expect(await eventually { (await first.events).contains { if case .messageReceived = $0 { true } else { false } } })
        // The first subscriber goes away — closing a sheet — and a third attaches.
        pump.cancel(); pump2.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        let third = EventCollector()
        let s3 = session.events
        let pump3 = Task { for await e in s3 { await third.add(e) } }
        try? await Task.sleep(for: .milliseconds(50))
        await t.push(.messageReceived(inbound("two", id: "s2", seq: 2)))
        #expect(await eventually { (await third.events).contains { if case .messageReceived(let m) = $0 { m.body == "two" } else { false } } })
        pump3.cancel()
    }

    @Test("A subscriber that attaches after the contact started is caught up, so a later surface is not stuck in idle")
    func lateSubscriberIsCaughtUp() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.messageReceived(inbound("said before you looked", id: "s1", seq: 1)))
        _ = await eventually { (try? await session.transcript().count) == 1 }

        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        #expect(await eventually { (await late.states()).contains(.connected) })
        #expect(await eventually { (await late.events).contains { if case .messageReceived(let m) = $0 { m.body == "said before you looked" } else { false } } })
        latePump.cancel(); pump.cancel()
    }

    @Test("The replay is per contact: a new contact does not re-deliver the previous one's events")
    func replayResetsPerContact() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.messageReceived(inbound("first contact", id: "s1", seq: 1)))
        _ = await eventually { (try? await session.transcript().count) == 1 }
        await session.end()
        try await session.startChat(ChatContactRequest(displayName: "b"))
        _ = await eventually { session.state == .connected }
        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!(await late.events).contains { if case .messageReceived(let m) = $0 { m.body == "first contact" } else { false } })
        #expect((await late.states()).contains(.connected))
        latePump.cancel(); pump.cancel()
    }

    @Test("Catching a late subscriber up does not hand it the same state transition twice")
    func replayDoesNotDuplicateState() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        #expect(await eventually { (await late.states()).contains(.connected) })
        try? await Task.sleep(for: .milliseconds(80))
        let lateStates = await late.states()
        #expect(lateStates.filter { $0 == .connected }.count == 1, "states: \(lateStates)")
        latePump.cancel(); pump.cancel()
    }

    @Test("A late subscriber is told dispatch is suspended even after the event that said so was evicted from the replay")
    func lateSubscriberLearnsDispatchState() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, _, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.participantJoined(Participant(id: "ag", role: .agent, displayName: "Ann")))
        _ = await eventually { ls.calls.contains("suspend:humanAgentJoined") }
        // Just past the 200-event replay bound: enough to evict the dispatch event, few enough that
        // the store writes do not make this test a timing experiment.
        for i in 1...205 { await t.push(.messageReceived(inbound("m\(i)", id: "s\(i)", seq: i))) }
        _ = await eventually(.seconds(10)) { (try? await session.transcript().count) == 205 }

        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        #expect(await eventually { (await late.events).contains { if case .liveSyncDispatchChanged(.suspended, _) = $0 { true } else { false } } })
        latePump.cancel(); pump.cancel()
    }

    @Test("A new contact does not inherit the previous contact's suspended dispatch")
    func dispatchDoesNotLeakAcrossContacts() async throws {
        let t = StubTransport(); let ls = RecordingLiveSync()
        let (session, _, pump) = try await makeSession(transport: t, liveSync: ls)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.participantJoined(Participant(id: "ag", role: .agent, displayName: "Ann")))
        _ = await eventually { ls.calls.contains("suspend:humanAgentJoined") }
        await session.end()

        try await session.startChat(ChatContactRequest(displayName: "b"))
        _ = await eventually { session.state == .connected }
        // A late surface on the new contact must not be told dispatch is suspended.
        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!(await late.events).contains { if case .liveSyncDispatchChanged(.suspended, _) = $0 { true } else { false } })
        latePump.cancel(); pump.cancel()
    }
}

@Suite("Start cancelled during the vend")
@MainActor
struct StartCancelTests {
    actor SlowBackend: TouchpointBackend {
        var gate: CheckedContinuation<Void, Never>?
        var voiceStarts = 0
        func release() { gate?.resume(); gate = nil }
        func startChatContact(_ r: ChatContactRequest) async throws -> ChatContactCredentials { throw TouchpointError.invalidConfiguration("x") }
        func startVoiceContact(_ r: VoiceContactRequest) async throws -> VoiceContactCredentials {
            voiceStarts += 1
            await withCheckedContinuation { gate = $0 }
            return VoiceContactCredentials(contactID: "c-slow", participantID: "p", participantToken: "t", meetingJSON: Data("{}".utf8), attendeeJSON: Data("{}".utf8), expiresAt: nil)
        }
        func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("x") }
    }

    @Test("end() while credentials are being vended cancels the start: no contact is started, the transport never connects, and a new start works")
    func endDuringVend() async throws {
        let t = StubTransport(); let backend = SlowBackend()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-cancel-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let session = TouchpointSession(broker: CredentialBroker(backend: backend, keychain: InMemoryKeychainStore()), store: store, transports: [.voice: t])
        let starting = Task { @MainActor in try await session.startVoice(VoiceContactRequest(displayName: "v")) }
        #expect(await eventually { await backend.voiceStarts == 1 })
        await session.end()                                   // the customer hung up during "Calling…"
        await backend.release()
        await #expect(throws: TouchpointError.self) { try await starting.value }
        #expect(await t.connectCalls == 0, "the vended credentials were discarded, not connected")
        #expect(!session.isActive)
        #expect(session.contactID == nil)
        let second = Task { @MainActor in try await session.startVoice(VoiceContactRequest(displayName: "v")) }
        #expect(await eventually { await backend.voiceStarts == 2 })
        await backend.release()
        try await second.value
        #expect(session.isActive)
    }

    @Test("end() while the transport is connecting tears the contact down once, and a connect that completes late is disconnected")
    func endDuringConnect() async throws {
        let t = StubTransport(); await t.setHoldConnect(true)
        let backend = SlowBackend()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-cancel-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let session = TouchpointSession(broker: CredentialBroker(backend: backend, keychain: InMemoryKeychainStore()), store: store, transports: [.voice: t])
        let starting = Task { @MainActor in try await session.startVoice(VoiceContactRequest(displayName: "v")) }
        #expect(await eventually { await backend.voiceStarts == 1 })
        await backend.release()
        #expect(await eventually { await t.connectCalls == 1 })
        await session.end()                                   // hung up while the media was coming up
        #expect(session.state == .ended(.customerEnded), "end() must tear down, not be swallowed as a cancelled start")
        await t.releaseConnect()
        await #expect(throws: TouchpointError.self) { try await starting.value }
        #expect(!session.isActive)
        #expect(session.state == .ended(.customerEnded), "the late connect must not revive or re-end the contact")
        #expect(await t.disconnectCalls == 2, "teardown's disconnect, then the late connect's")
    }
}

@Suite("Remote activity and outbound typing", .serialized)
@MainActor
struct SessionActivityTests {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var now = Date(timeIntervalSince1970: 1_000)
        func read() -> Date { lock.withLock { now } }
        func advance(_ s: TimeInterval) { lock.withLock { now = now.addingTimeInterval(s) } }
    }

    @Test("Typing goes out at most once per 2.5 s, and only on a live chat")
    func typingThrottled() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        let clock = Clock()
        session.clock = { clock.read() }
        await session.sendTyping()
        #expect(await t.typingCalls == 0, "nothing to tell before a contact exists")
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await session.sendTyping(); await session.sendTyping()
        #expect(await t.typingCalls == 1)
        clock.advance(2.4); await session.sendTyping()
        #expect(await t.typingCalls == 1)
        clock.advance(0.2); await session.sendTyping()
        #expect(await t.typingCalls == 2)
        await session.end()
        clock.advance(5); await session.sendTyping()
        #expect(await t.typingCalls == 2, "an ended contact sends nothing")
        pump.cancel()
    }

    @Test("Remote activity reaches subscribers while connected, and is never replayed to a late one")
    func activityForwardedNotReplayed() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.remoteActivity(.typing))
        #expect(await eventually { await collector.events.contains { if case .remoteActivity(.typing) = $0 { true } else { false } } })
        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        #expect(await eventually { await late.states().last == .connected })
        #expect(await !late.events.contains { if case .remoteActivity = $0 { true } else { false } })
        latePump.cancel(); pump.cancel()
    }
}

@Suite("Transcript notices from the session", .serialized)
@MainActor
struct SessionNoticeTests {
    private func notices(_ c: EventCollector) async -> [TranscriptNotice] {
        await c.events.compactMap { if case .notice(let n) = $0 { n } else { nil } }
    }

    @Test("An agent joining and leaving posts web's two notices, anchored after the newest message; a supervisor and a repeated join post none")
    func agentNotices() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("I need a person")
        _ = await eventually { (try? await session.transcript().count) == 1 }
        await t.push(.participantJoined(Participant(id: "sup", role: .supervisor, displayName: "S")))
        await t.push(.participantJoined(Participant(id: "a1", role: .agent, displayName: "Alex")))
        await t.push(.participantJoined(Participant(id: "a1", role: .agent, displayName: "Alex")))
        await t.push(.participantLeft(id: "a1"))
        #expect(await eventually { await notices(collector).count == 2 })
        let posted = await notices(collector)
        #expect(posted.map(\.kind) == [.agentJoined, .agentLeft])
        #expect(posted.allSatisfy { $0.after == id }, "anchored after the customer's message")
        pump.cancel()
    }

    @Test("A drop from a live connection posts one Connection lost; a late subscriber is replayed it")
    func connectionLost() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailConnects(5)   // the reconnect attempts fail too
        await t.push(.disconnected(error: nil))
        #expect(await eventually { await notices(collector).map(\.kind) == [.connectionLost] })
        #expect(await eventually { if case .ended = session.state { true } else { false } })
        #expect(await notices(collector).count == 1, "failed reconnect attempts are the same outage")
        let late = EventCollector()
        let stream = session.events
        let latePump = Task { for await e in stream { await late.add(e) } }
        #expect(await eventually { await notices(late).map(\.kind) == [.connectionLost] })
        latePump.cancel(); pump.cancel()
    }
}

@Suite("Choices through the outbox", .serialized)
@MainActor
struct SessionChoiceTests {
    @Test("A choice is queued as the customer's message and goes out carrying web's interactive response")
    func choiceQueuedAndSent() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        // Generous waits: under the full parallel suite the outbox drain can take longer than the
        // 2s default (it failed there at 3.1s, never in isolation), and a discarded connect wait
        // let the send race the connection.
        #expect(await eventually(.seconds(10)) { session.state == .connected })
        try await session.sendChoice(InteractiveChoice(id: "card", text: "Replacement card"))
        #expect(await eventually(.seconds(10)) { await t.sent.count == 1 })
        let sent = try #require(await t.sent.first)
        #expect(sent.body == "Replacement card")
        #expect(sent.interactiveResponse?.templateType == "TouchpointModality")
        // The transcript row is the echo web draws: the choice's text, ours, outbound.
        let row = try #require(try await session.transcript().last)
        #expect(row.body == "Replacement card")
        #expect(row.direction == .outbound)
        pump.cancel()
    }

    @Test("Typed text still goes out as text, with no interactive response")
    func textHasNoResponse() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        _ = try await session.send("hello")
        #expect(await eventually { await t.sent.count == 1 })
        #expect(await t.sent.first?.interactiveResponse == nil)
        pump.cancel()
    }

    /// Android's rule (CV-6): past Connect's interactive-response limit the choice goes as its
    /// words, so the conversation continues. Web drops it silently; refusing left a failed row.
    @Test("A choice too large for an interactive response is sent as its text")
    func oversizedChoiceFallsBackToText() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        #expect(await eventually(.seconds(10)) { session.state == .connected })
        // The action is capped at 200 characters, so it is the id that carries the bulk.
        let huge = InteractiveChoice(id: String(repeating: "x", count: 20_000), text: "Big")
        try await session.sendChoice(huge)
        #expect(await eventually(.seconds(10)) { await t.sent.count == 1 })
        #expect(await t.sent.first?.body == "Big")
        #expect(await t.sent.first?.interactiveResponse == nil)
        pump.cancel()
    }

    @Test("Only an outbound row's own envelope is sent as a response; an inbound card never is")
    func onlyOutboundEnvelopes() throws {
        let response = try JSONEncoder().encode(try InteractiveContent.choiceResponse(InteractiveChoice(id: "a", text: "A")))
        let outbound = StoredMessage(clientMessageID: UUID(), body: "A", direction: .outbound, participantRole: .customer,
                                     deliveryState: .sending, interactiveJSON: response)
        let inbound = StoredMessage(clientMessageID: UUID(), body: "A", direction: .inbound, participantRole: .assistant,
                                    deliveryState: .delivered, interactiveJSON: response)
        #expect(TouchpointSession.interactiveResponse(of: outbound) != nil)
        #expect(TouchpointSession.interactiveResponse(of: inbound) == nil)
    }

    // MARK: Start, resume and reconcile hardenings

    @Test("A second start while the first is still vending does not vend a second backend contact")
    func concurrentStartVendsOnce() async throws {
        let t = StubTransport()
        let backend = ScriptedBackend()
        await backend.setDelay(.milliseconds(120))
        let (session, _, pump) = try await makeSessionWithBackend(transport: t, backend: backend)
        defer { pump.cancel() }
        let first = Task { try await session.startChat(ChatContactRequest(displayName: "a")) }
        try? await Task.sleep(for: .milliseconds(30))   // the first start is now inside its vend
        await #expect(throws: TouchpointError.self) { try await session.startChat(ChatContactRequest(displayName: "b")) }
        try await first.value
        #expect(await backend.chatCalls == 1)            // the second start never reached the backend
        await session.end()
    }

    @Test("A resume whose connect fails after end does not end a replacement contact")
    func resumeConnectFailureAfterEndIsGenerationChecked() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-resume-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let t = StubTransport()
        await t.setHoldConnect(true)
        await t.setFailConnects(1)   // the held connect throws once released
        let (session, collector, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        defer { pump.cancel() }
        let resumeTask = Task { try? await session.resume(contactID: contactID) }
        #expect(await eventually { await t.connectCalls == 1 })   // resume is holding at connect
        await session.end()                                       // tears the contact down; generation bumps
        await t.releaseConnect()                                  // the held connect now fails
        _ = await resumeTask.value
        try? await Task.sleep(for: .milliseconds(60))
        // Exactly one end: the resume's failing connect must not run teardown again on the ended
        // (or a replacement) contact.
        let ends = await collector.events.filter { if case .contactEnded = $0 { true } else { false } }.count
        #expect(ends == 1)
    }

    @Test("An agent leaving during reconcile never leaves a human agent present with dispatch enabled")
    func agentLeaveDuringReconcile() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-resume-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let agent = Participant(id: "ag", role: .agent, displayName: "Ann")
        var contactID = ""
        do {   // process 1: an agent joins, so the persisted set and the history both hold one
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            await t.push(.participantJoined(agent))
            _ = await eventually { (try? await session.participants().humanAgentPresent) == true }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        // process 2: resume suspends dispatch, then reconciles. The history re-adds the agent; a
        // live leave lands while the (slow) fetch is in flight.
        let t = StubTransport()
        await t.setTranscriptPage(TranscriptPage(messages: [], participantEvents: [.participantJoined(agent)], nextToken: nil))
        await t.setFetchDelay(.milliseconds(150))
        let ls = RecordingLiveSync()
        let (session, collector, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain, liveSync: ls)
        defer { pump.cancel() }
        let resumeTask = Task { try await session.resume(contactID: contactID) }
        #expect(await eventually { await t.fetchCalls.count > 0 })   // reconcile is fetching
        await t.push(.participantLeft(id: "ag"))                     // the agent leaves mid-reconcile
        try await resumeTask.value
        #expect(await eventually { (await collector.events).contains { if case .transcriptReconciled = $0 { true } else { false } } })
        try? await Task.sleep(for: .milliseconds(50))
        // The dispatch-gate invariant: a human agent present must never coexist with dispatch enabled. The
        // bug lifted dispatch on the live leave, then the page fold re-added the agent.
        let present = try await session.participants().humanAgentPresent
        #expect(!(present && session.dispatchState == .enabled), "agent present with dispatch enabled")
    }
}

@MainActor
private func makeSessionWithBackend(transport: StubTransport, backend: ScriptedBackend) async throws -> (TouchpointSession, EventCollector, Task<Void, Never>) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-sess-\(UUID().uuidString)")
    let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
    let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
    let session = TouchpointSession(broker: broker, store: store, transports: [.chat: transport],
                                    reconnection: .init(maxAttempts: 2, totalBudget: .seconds(5), initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitterFactor: 0))
    let collector = EventCollector()
    let stream = session.events
    let pump = Task { for await e in stream { await collector.add(e) } }
    return (session, collector, pump)
}

// MARK: - The host's new-message handler (replaces APNs push)

@MainActor
private final class IncomingRecorder {
    var calls: [IncomingMessages] = []
    var bodies: [[String]] { calls.map { $0.messages.map(\.body) } }
    /// Waits for `n` calls, outside `#expect`: written inline as
    /// `#expect(await eventually { recorder.calls.count == n })`, two of these tests failed in
    /// about one full-suite run in three, while the same wait outside the macro passed five full
    /// runs in a row. The cause is not established.
    func reaches(_ n: Int) async -> Bool { await eventually { self.calls.count == n } }
}

@Suite("onIncomingMessages: a host-owned handler for new messages from the other side", .serialized)
@MainActor
struct IncomingMessagesTests {
    private func started(_ t: StubTransport) async throws -> (TouchpointSession, IncomingRecorder, Task<Void, Never>) {
        let (session, _, pump) = try await makeSession(transport: t)
        let recorder = IncomingRecorder()
        session.onIncomingMessages = { recorder.calls.append($0) }
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        return (session, recorder, pump)
    }

    @Test("A live inbound message calls the handler once, as live, with the contact id")
    func liveInbound() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        await t.push(.messageReceived(inbound("hello", id: "s1", seq: 1)))
        #expect(await recorder.reaches(1))
        let call = try #require(recorder.calls.first)
        #expect(call.origin == .live)
        #expect(call.contactID == session.contactID)
        #expect(call.messages.map(\.body) == ["hello"])
        #expect(call.messages.first?.direction == .inbound)
        pump.cancel()
    }

    @Test("Every inbound role is passed on — system and flow messages too — and the host filters")
    func everyInboundRole() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        await t.push(.messageReceived(inbound("welcome", id: "s1", seq: 1, role: .system)))
        await t.push(.messageReceived(inbound("hi", id: "s2", seq: 2, role: .agent)))
        let ok = await eventually { recorder.calls.count == 2 }
        let transcript = (try? await session.transcript().map(\.body)) ?? []
        #expect(ok, "calls=\(recorder.bodies) transcript=\(transcript) state=\(session.state)")
        #expect(recorder.calls.flatMap(\.messages).map(\.participantRole) == [.system, .agent])
        pump.cancel()
    }

    @Test("The customer's own messages never call it: not the optimistic echo, not the server's echo")
    func ownMessagesAreSilent() async throws {
        let t = StubTransport()
        await t.setEchoBeforeAck(true); await t.setAutoAck(true)
        let (session, recorder, pump) = try await started(t)
        _ = try await session.send("where is my card?")
        #expect(await eventually { await t.sent.count == 1 })
        await t.push(.messageReceived(inbound("checking", id: "s9", seq: 9)))
        #expect(await recorder.reaches(1))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.bodies == [["checking"]])
        pump.cancel()
    }

    @Test("A repeated frame is one message: the duplicate is silent")
    func duplicateIsSilent() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        let frame = inbound("hello", id: "s1", seq: 1)
        await t.push(.messageReceived(frame))
        await t.push(.messageReceived(frame))
        let ok = await eventually { recorder.calls.count == 1 }
        let transcript = (try? await session.transcript().count) ?? -1
        #expect(ok, "calls=\(recorder.calls.count) transcript=\(transcript) state=\(session.state)")
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.calls.count == 1)
        pump.cancel()
    }

    @Test("After a reconnect, the replies missed while away come as ONE catch-up call, oldest first, without the ones already shown")
    func reconnectCatchUp() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        await t.push(.messageReceived(inbound("seen", id: "s1", seq: 1)))
        #expect(await recorder.reaches(1))
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("seen", id: "s1", seq: 1),
                                                           inbound("missed one", id: "s2", seq: 2),
                                                           inbound("missed two", id: "s3", seq: 3)],
                                                 participantEvents: [], nextToken: nil))
        await t.push(.disconnected(error: nil))
        #expect(await recorder.reaches(2))
        let catchUp = recorder.calls[1]
        #expect(catchUp.origin == .catchUp)
        #expect(catchUp.contactID == session.contactID)
        #expect(catchUp.messages.map(\.body) == ["missed one", "missed two"])
        pump.cancel()
    }

    @Test("A reconcile cut short by a drop loses nothing: every missed reply is reported once in total, never twice")
    func interruptedCatchUpLosesNothing() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        let missed = (1...200).map { inbound("missed \($0)", id: "m\($0)", seq: $0) }
        await t.setTranscriptPage(TranscriptPage(messages: missed, participantEvents: [], nextToken: nil))
        // Drop once to start a reconcile, then drop again once it has begun storing the page — the
        // window the fix covers. (Waiting on the fetch alone could drop before anything is stored.)
        await t.push(.disconnected(error: nil))
        _ = await eventually { ((try? await session.transcript(contactID: session.contactID ?? "").count) ?? 0) >= 1 }
        await t.push(.disconnected(error: nil))
        // The reconnect after the second drop reconciles the same page again.
        _ = await eventually(.seconds(5)) { recorder.calls.flatMap(\.messages).count >= missed.count }
        try? await Task.sleep(for: .milliseconds(200))
        let reported = recorder.calls.flatMap(\.messages).map(\.body)
        #expect(Set(reported) == Set(missed.map(\.body)), "every missed reply reported")
        #expect(reported.count == missed.count, "none reported twice")
        #expect(await t.fetchCalls.count >= 2, "a second reconcile ran after the drop")
        #expect(session.isActive)
        pump.cancel()
    }

    @Test("If reconciliation gives up, the rows earlier attempts stored are still reported, not stranded")
    func giveUpReportsStoredRows() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        let missed = (1...200).map { inbound("missed \($0)", id: "m\($0)", seq: $0) }
        await t.setTranscriptPage(TranscriptPage(messages: missed, participantEvents: [], nextToken: nil))
        await t.push(.disconnected(error: nil))
        _ = await eventually { ((try? await session.transcript(contactID: session.contactID ?? "").count) ?? 0) >= 1 }
        // Every fetch from here fails, so the next reconcile retries and gives up.
        await t.setFailFetches(1_000)
        await t.push(.disconnected(error: nil))
        _ = await eventually(.seconds(5)) { !recorder.calls.isEmpty }
        let reported = recorder.calls.flatMap(\.messages).map(\.body)
        let stored = try await session.transcript(contactID: session.contactID ?? "").map(\.body)
        #expect(!reported.isEmpty, "the stored rows are reported when reconciliation gives up")
        #expect(Set(reported) == Set(stored), "exactly the rows that were stored")
        #expect(recorder.calls.allSatisfy { $0.origin == .catchUp })
        pump.cancel()
    }

    @Test("A reconnect that finds nothing new calls nothing")
    func emptyCatchUpIsSilent() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        await t.push(.messageReceived(inbound("seen", id: "s1", seq: 1)))
        #expect(await recorder.reaches(1))
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("seen", id: "s1", seq: 1)], participantEvents: [], nextToken: nil))
        await t.push(.disconnected(error: nil))
        #expect(await eventually { await t.fetchCalls.count == 1 && session.state == .connected })
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.calls.count == 1)
        pump.cancel()
    }

    @Test("Resuming after a relaunch reports what arrived while the app was gone as one catch-up call")
    func resumeCatchUp() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-incoming-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {   // process 1
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            await t.push(.messageReceived(inbound("before", id: "s1", seq: 1)))
            _ = await eventually { (try? await session.transcript().count) == 1 }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let t = StubTransport()
        await t.setTranscriptPage(TranscriptPage(messages: [inbound("before", id: "s1", seq: 1), inbound("while away", id: "s2", seq: 2)],
                                                 participantEvents: [], nextToken: nil))
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        let recorder = IncomingRecorder()
        session.onIncomingMessages = { recorder.calls.append($0) }
        try await session.resume(contactID: contactID)
        #expect(await recorder.reaches(1))
        #expect(recorder.calls.first?.origin == .catchUp)
        #expect(recorder.bodies == [["while away"]])
        pump.cancel()
    }

    @Test("Nothing is reported once the contact has ended")
    func silentAfterEnd() async throws {
        let t = StubTransport()
        let (session, recorder, pump) = try await started(t)
        await session.end()
        await t.push(.messageReceived(inbound("late", id: "s1", seq: 1)))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.calls.isEmpty)
        pump.cancel()
    }

    @Test("A handler set after messages arrived is not handed them: it hears only what comes next")
    func lateHandlerGetsNoBackfill() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.push(.messageReceived(inbound("early", id: "s1", seq: 1)))
        _ = await eventually { (try? await session.transcript().count) == 1 }
        let recorder = IncomingRecorder()
        session.onIncomingMessages = { recorder.calls.append($0) }
        await t.push(.messageReceived(inbound("later", id: "s2", seq: 2)))
        #expect(await recorder.reaches(1))
        #expect(recorder.bodies == [["later"]])
        pump.cancel()
    }

    // Ported from the removed push-bridge suite: resume is not push-specific.

    @Test("Resume renders from the store before any network call succeeds: the transcript is readable while connect hangs")
    func resumeBeforeNetwork() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-incoming-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""
        do {
            let t = StubTransport()
            let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            await t.push(.messageReceived(inbound("Your replacement card has shipped.", id: "s1", seq: 1)))
            _ = await eventually { (try? await session.transcript().count) == 1 }
            contactID = session.contactID ?? ""
            pump.cancel()
        }
        let t = StubTransport()
        await t.setHoldConnect(true)
        let (session, _, pump) = try await makePersistentSession(transport: t, dir: dir, keychain: keychain)
        let resume = Task { try await session.resume(contactID: contactID) }
        #expect(await eventually { await t.connectCalls == 1 })
        #expect(session.state == .connecting)
        #expect(try await session.transcript(contactID: contactID).map(\.body) == ["Your replacement card has shipped."])
        await t.releaseConnect()
        _ = try? await resume.value
        pump.cancel()
    }

    @Test("A contact whose connection was lost for good can be resumed again: an ended id is not an active one")
    func resumeAfterConnectionLost() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(transport: t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try #require(session.contactID)
        await t.push(.contactEnded(.connectionLost))
        #expect(await eventually { !session.isActive })
        #expect(session.contactID == id)
        try await session.resume(contactID: id)
        #expect(await eventually { session.state == .connected })
        #expect(await t.connectCalls == 2)
        pump.cancel()
    }
}

@Suite("The SDK posts no notifications of its own")
struct NoNotificationsInSDKTests {
    @Test("No SDK source imports UserNotifications: posting a notification is the host's decision")
    func noUserNotificationsImport() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? [])
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.firstMatch(of: /import\s+(\w+\s+)?UserNotifications\b/) == nil, "\(url.lastPathComponent) imports UserNotifications")
        }
    }
}
