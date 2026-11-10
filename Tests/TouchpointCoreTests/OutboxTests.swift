import Foundation
import Testing
@testable import TouchpointCore

/// The offline behaviour users expect from every messaging app they already use.
@Suite("Outbox", .serialized)
@MainActor
struct OutboxTests {
    private func makeSession(_ t: StubTransport, dir: URL? = nil, keychain: InMemoryKeychainStore = InMemoryKeychainStore(), ackTimeout: Duration = .seconds(30)) async throws -> (TouchpointSession, EventCollector, Task<Void, Never>) {
        let dir = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("tp-outbox-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        let session = TouchpointSession(broker: broker, store: store, transports: [.chat: t], reconnection: .init(maxAttempts: 3, totalBudget: .seconds(5), initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitterFactor: 0), ackTimeout: ackTimeout)
        let collector = EventCollector(); let stream = session.events
        let pump = Task { for await e in stream { await collector.add(e) } }
        return (session, collector, pump)
    }

    private func eventually(_ timeout: Duration = .seconds(2), _ cond: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline { if await cond() { return true }; try? await Task.sleep(for: .milliseconds(10)) }
        return await cond()
    }

    @Test("Send offline, reconnect: every queued message is delivered exactly once, in composition order")
    func flushOnReconnect() async throws {
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setAutoConnectEvent(false)
        await t.push(.disconnected(error: nil))
        _ = await eventually { if case .reconnecting = session.state { true } else { false } }
        let a = try await session.send("one"); let b = try await session.send("two"); let c = try await session.send("three")
        #expect(await t.sent.isEmpty)                                 // nothing went out while offline
        await t.setAutoConnectEvent(true); await t.push(.connected)
        #expect(await eventually { await t.sent.count == 3 })
        #expect(await t.sent.map(\.clientMessageID) == [a, b, c])
        #expect(await eventually { (try? await session.transcript().allSatisfy { $0.deliveryState == .sent }) == true })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await t.sent.count == 3)                              // exactly once
        pump.cancel()
    }

    @Test("A send that fails on a healthy connection is retried automatically with backoff; the row stays .sending meanwhile")
    func failedSendAutoRetries() async throws {
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailSends(2)
        let a = try await session.send("flaky")
        #expect(await eventually { (await collector.events).contains { if case .failed(.transportFailure) = $0 { true } else { false } } })
        #expect(await eventually(.seconds(3)) { await t.sent.map(\.clientMessageID) == [a] })
        #expect(await eventually { (try? await session.transcript().first?.deliveryState) == .sent })
        pump.cancel()
    }

    @Test("A later send never overtakes an earlier failed one")
    func failedSendKeepsOrder() async throws {
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailSends(1)
        let a = try await session.send("first (fails once)")
        let b = try await session.send("second")
        #expect(await eventually(.seconds(3)) { await t.sent.count == 2 })
        #expect(await t.sent.map(\.clientMessageID) == [a, b])
        pump.cancel()
    }

    @Test("A send that fails stays queued while offline and goes out on the next connect")
    func failedSendGoesOutOnReconnect() async throws {
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setFailSends(1)
        let a = try await session.send("first (fails)")
        try? await Task.sleep(for: .milliseconds(5))
        await t.push(.disconnected(error: nil))
        _ = await eventually { session.state == .connected }
        #expect(await eventually(.seconds(3)) { await t.sent.map(\.clientMessageID) == [a] })
        pump.cancel()
    }

    // MARK: Adversarial round

    @Test("Lost ack then resume: reconcile adopts the server's copy and the flush does NOT resend it")
    func lostAckThenResumeNoDuplicate() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-lostack-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""; var sentID = UUID()
        do {   // process 1: the server accepts, the ack never arrives, the app dies
            let t = StubTransport()                      // autoAck off: send succeeds, no .messageDelivered
            let (session, _, pump) = try await makeSession(t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            sentID = try await session.send("pay my bill")
            _ = await eventually { await t.sent.count == 1 }
            pump.cancel()
        }
        let t = StubTransport(); await t.setAutoAck(true)
        await t.setTranscriptPage(TranscriptPage(messages: [StoredMessage(clientMessageID: UUID(), serverMessageID: "srv-bill", body: "pay my bill", direction: .outbound, participantRole: .customer, sequence: 5, deliveryState: .sent)], participantEvents: [], nextToken: nil))
        let (session, collector, pump) = try await makeSession(t, dir: dir, keychain: keychain)
        try await session.resume(contactID: contactID)
        #expect(await eventually(.seconds(3)) { (await collector.events).contains { if case .transcriptReconciled = $0 { true } else { false } } })
        try? await Task.sleep(for: .milliseconds(150))   // give a wrongly-ordered flush every chance to fire
        #expect(await t.sent.isEmpty, "flush resent a message the server already had")
        let rows = try await session.transcript()
        #expect(rows.count == 1 && rows[0].id == sentID && rows[0].serverMessageID == MessageID("srv-bill") && rows[0].deliveryState == .sent)
        pump.cancel()
    }

    @Test("send() during an in-flight flush with a lagging ack does not resend the in-flight message")
    func sendDuringFlushNoResend() async throws {
        let t = StubTransport(); await t.setSendDelay(.milliseconds(120))   // ack arrives only after the slow send returns
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("A")
        try? await Task.sleep(for: .milliseconds(30))
        let b = try await session.send("B")                              // arrives while A's send is in flight
        #expect(await eventually(.seconds(3)) { await t.sent.count == 2 })
        try? await Task.sleep(for: .milliseconds(200))
        let sentIDs = await t.sent.map(\.clientMessageID)
        #expect(sentIDs == [a, b], "sent: \(sentIDs.count)")
        pump.cancel()
    }

    @Test("A disconnect during an in-flight send: the message is not resent if the server has it (reconcile first), and the stale send result is ignored")
    func reconnectDuringInFlightSend() async throws {
        let t = StubTransport(); await t.setSendDelay(.milliseconds(150))
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("in flight")
        try? await Task.sleep(for: .milliseconds(30))
        await t.setTranscriptPage(TranscriptPage(messages: [StoredMessage(clientMessageID: UUID(), serverMessageID: "srv-if", body: "in flight", direction: .outbound, participantRole: .customer, sequence: 9, deliveryState: .sent)], participantEvents: [], nextToken: nil))
        await t.push(.disconnected(error: nil))
        _ = await eventually { session.state == .connected }
        try? await Task.sleep(for: .milliseconds(400))
        #expect(await t.sent.map(\.clientMessageID) == [a])             // the original, once; no resend
        let rows = try await session.transcript()
        #expect(rows.count == 1 && rows[0].deliveryState == .sent && rows[0].serverMessageID == MessageID("srv-if"))
        pump.cancel()
    }

    @Test("end() during an in-flight send: the row is failed, and nothing is emitted after contactEnded")
    func teardownDuringInFlightSend() async throws {
        let t = StubTransport(); await t.setSendDelay(.milliseconds(150)); await t.setFailSends(1)
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("doomed")
        try? await Task.sleep(for: .milliseconds(30))
        await session.end()
        try? await Task.sleep(for: .milliseconds(300))                   // the slow send fails after teardown
        let events = await collector.events
        let endIdx = try #require(events.firstIndex { if case .contactEnded = $0 { true } else { false } })
        #expect(events[endIdx...].dropFirst().isEmpty)
        #expect(try await session.transcript(contactID: session.contactID ?? "").first.map { $0.id == a && $0.deliveryState == .failed } == true)
        // A new contact flushes normally — the dead flush did not wedge the session.
        let t2 = StubTransport(); await t2.setAutoAck(true)
        let (s2, _, p2) = try await makeSession(t2)
        try await s2.startChat(ChatContactRequest(displayName: "b"))
        _ = await eventually { s2.state == .connected }
        let c = try await s2.send("fresh")
        #expect(await eventually { await t2.sent.map(\.clientMessageID) == [c] })
        pump.cancel(); p2.cancel()
    }

    @Test("Interleaving: an inbound message arriving mid-flush is surfaced without waiting for the flush")
    func inboundMidFlush() async throws {
        let t = StubTransport(); await t.setSendDelay(.milliseconds(150)); await t.setAutoAck(true)
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        _ = try await session.send("slow one")
        try? await Task.sleep(for: .milliseconds(20))
        await t.push(.messageReceived(StoredMessage(clientMessageID: UUID(), serverMessageID: "in-1", body: "agent says hi", direction: .inbound, participantRole: .agent, sequence: 1, deliveryState: .delivered)))
        #expect(await eventually(.milliseconds(100)) { (await collector.events).contains { if case .messageReceived = $0 { true } else { false } } })
        #expect(await t.sent.isEmpty)                                       // the inbound beat the still-in-flight send
        _ = await eventually(.seconds(2)) { await t.sent.count == 1 }
        #expect(try await session.transcript().map(\.body) == ["agent says hi", "slow one"])   // server sequence first, echo tail after
        pump.cancel()
    }

    @Test("The server echo of our own message can beat the ack: one row, one .sent transition, no messageReceived")
    func echoBeforeAck() async throws {
        let t = StubTransport(); await t.setAutoAck(true); await t.setEchoBeforeAck(true)
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("race me")
        #expect(await eventually { (try? await session.transcript().first?.deliveryState) == .sent })
        try? await Task.sleep(for: .milliseconds(60))
        let rows = try await session.transcript()
        #expect(rows.count == 1 && rows[0].id == a)
        let sentEvents = await collector.events.filter { if case .deliveryStateChanged(let u) = $0 { u.clientMessageID == a && u.state == .sent } else { false } }
        #expect(sentEvents.count == 1)
        // Exactly one messageReceived: the optimistic echo. The server's echo must not add another.
        let received = await collector.events.filter { if case .messageReceived = $0 { true } else { false } }
        #expect(received.count == 1)
        pump.cancel()
    }

    @Test("Ordering with skewed device clocks: server sequence governs; local echoes pin to the tail in composition order")
    func skewedClocks() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-skew-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        try await store.upsertConversation(contactID: "c", modality: .chat)
        let farFuture = Date().addingTimeInterval(86_400 * 30), farPast = Date(timeIntervalSince1970: 0)
        // Reconciled rows: created-at wildly wrong on purpose, sequence correct.
        try await store.append(contactID: "c", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s2", body: "second", direction: .inbound, participantRole: .agent, sequence: 2, createdAt: farPast, deliveryState: .delivered))
        try await store.append(contactID: "c", message: StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "first", direction: .outbound, participantRole: .customer, sequence: 1, createdAt: farFuture, deliveryState: .sent))
        // Local echoes: composed later, but the device clock jumped backwards between them.
        let e1 = UUID(), e2 = UUID()
        try await store.append(contactID: "c", message: StoredMessage(clientMessageID: e1, body: "echo one", direction: .outbound, participantRole: .customer, createdAt: Date(), deliveryState: .sending))
        try await store.append(contactID: "c", message: StoredMessage(clientMessageID: e2, body: "echo two", direction: .outbound, participantRole: .customer, createdAt: Date().addingTimeInterval(-3600), deliveryState: .sending))
        let bodies = try await store.messages(contactID: "c").map(\.body)
        #expect(bodies == ["first", "second", "echo one", "echo two"])
    }

    @Test("The outbox survives process termination: a new session over the same store flushes what the old one never sent")
    func survivesTermination() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-term-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        var contactID = ""; var queued: [UUID] = []
        do {   // process 1: goes offline, composes, dies
            let t = StubTransport()
            let (session, _, pump) = try await makeSession(t, dir: dir, keychain: keychain)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            _ = await eventually { session.state == .connected }
            contactID = session.contactID ?? ""
            await t.setAutoConnectEvent(false); await t.push(.disconnected(error: nil))
            _ = await eventually { if case .reconnecting = session.state { true } else { false } }
            queued = [try await session.send("drafted offline 1"), try await session.send("drafted offline 2")]
            pump.cancel()
        }
        // process 2: resume → connect → flush
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, _, pump) = try await makeSession(t, dir: dir, keychain: keychain)
        try await session.resume(contactID: contactID)
        #expect(await eventually(.seconds(3)) { await t.sent.map(\.clientMessageID) == queued })
        #expect(await eventually { (try? await session.transcript().allSatisfy { $0.deliveryState == .sent }) == true })
        pump.cancel()
    }

    @Test("A duplicate server echo of a flushed message is suppressed")
    func duplicateEchoSuppressed() async throws {
        let t = StubTransport(); await t.setAutoAck(true)
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let id = try await session.send("hello")
        _ = await eventually { (try? await session.transcript().first?.deliveryState) == .sent }
        let sid = try await session.transcript().first?.serverMessageID?.rawValue ?? ""
        await t.push(.messageReceived(StoredMessage(clientMessageID: UUID(), serverMessageID: sid, body: "hello", direction: .outbound, participantRole: .customer, sequence: 1001, deliveryState: .sent)))
        try? await Task.sleep(for: .milliseconds(60))
        #expect(try await session.transcript().count == 1)
        #expect(try await session.transcript().first?.id == id)
        let received = await collector.events.filter { if case .messageReceived = $0 { true } else { false } }
        #expect(received.count == 1)   // the echo only; the duplicate server frame is suppressed
        pump.cancel()
    }

    @Test("Contact end with a non-empty outbox surfaces failures rather than losing them")
    func contactEndFailsOutbox() async throws {
        let t = StubTransport()
        let (session, collector, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setAutoConnectEvent(false); await t.push(.disconnected(error: nil))
        _ = await eventually { if case .reconnecting = session.state { true } else { false } }
        let a = try await session.send("never sent"); let b = try await session.send("never sent 2")
        await session.end()
        let states = try await session.transcript(contactID: session.contactID ?? "").map { ($0.id, $0.deliveryState) }
        #expect(states.map(\.1) == [.failed, .failed] && states.map(\.0) == [a, b])
        let changes = await collector.events.compactMap { if case .deliveryStateChanged(let u) = $0, u.state == .failed { u.clientMessageID } else { nil } }
        #expect(changes == [a, b])
        pump.cancel()
    }

    @Test("A send whose ack was lost to a disconnect and that the server never received is resent after reconnect (at-least-once)")
    func lostOnWireIsResent() async throws {
        let t = StubTransport()                       // autoAck off: send "succeeds" but no ack ever comes
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("vanished on the wire")
        _ = await eventually { await t.sent.count == 1 }
        // Acknowledge from here on **before** triggering the reconnect: the flush that follows
        // `.connected` can outrun a later `setAutoAck`, which made this test flaky rather than the
        // behaviour it tests.
        await t.setAutoAck(true)
        await t.push(.disconnected(error: nil))       // server transcript (empty page) shows it never arrived
        _ = await eventually { session.state == .connected }
        #expect(await eventually(.seconds(3)) { await t.sent.map(\.clientMessageID) == [a, a] })
        #expect(await eventually(.seconds(3)) { (try? await session.transcript().first?.deliveryState) == .sent })
        pump.cancel()
    }

    @Test("An ack lost on a socket that stays up: the message is resent after the ack timeout, not waited on forever")
    func lostAckOnLiveSocketResent() async throws {
        let t = StubTransport()                       // first send is swallowed: no ack, no disconnect
        let (session, _, pump) = try await makeSession(t, ackTimeout: .milliseconds(150))
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        let a = try await session.send("ack me")
        _ = await eventually { await t.sent.count == 1 }
        await t.setAutoAck(true)
        #expect(await eventually(.seconds(3)) { await t.sent.map(\.clientMessageID) == [a, a] })
        #expect(await eventually(.seconds(3)) { (try? await session.transcript().first?.deliveryState) == .sent })
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await t.sent.count == 2)              // acknowledged: the watchdog stops
        pump.cancel()
    }

    @Test("Retry resends a failed message as a fresh outbound row, leaving the failed one as the record")
    func retryFailed() async throws {
        let t = StubTransport()
        let (session, _, pump) = try await makeSession(t)
        try await session.startChat(ChatContactRequest(displayName: "a"))
        _ = await eventually { session.state == .connected }
        await t.setAutoConnectEvent(false); await t.push(.disconnected(error: nil))
        _ = await eventually { if case .reconnecting = session.state { true } else { false } }
        let a = try await session.send("please retry me")
        await session.end()
        #expect(try await session.transcript(contactID: session.contactID ?? "").first?.deliveryState == .failed)

        // A new contact, then retry: the body goes out again under a new client id.
        let t2 = StubTransport(); await t2.setAutoAck(true)
        let (s2, _, p2) = try await makeSession(t2)
        try await s2.startChat(ChatContactRequest(displayName: "b"))
        _ = await eventually { s2.state == .connected }
        let failedRow = try await session.transcript(contactID: session.contactID ?? "").first!
        let retried = try await s2.resend(failedRow)
        #expect(retried != a)
        // A message that did not fail is rejected rather than silently duplicated.
        let live = try await s2.transcript().first!
        await #expect(throws: TouchpointError.self) { _ = try await s2.resend(live) }
        #expect(await eventually { await t2.sent.map(\.body) == ["please retry me"] })
        pump.cancel(); p2.cancel()
    }

}
