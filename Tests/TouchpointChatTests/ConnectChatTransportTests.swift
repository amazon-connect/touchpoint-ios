import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

/// Scriptable stand-in for the upstream `ChatSession`. Records every call so the tests can assert
/// what reached the wire — in particular that `resendFailedMessage` never does.
actor FakeChatDriver: ChatSessionDriving {
    var handlers: ChatDriverHandlers?
    var connects: [String] = []           // participant tokens
    var disconnects = 0
    var sentBodies: [String] = []
    var sentContentTypes: [String] = []
    var receipts: [(ReceiptKind, String)] = []
    var transcriptPages: [RawTranscriptPage] = []
    var transcriptRequests: [String?] = []
    var transcriptLimits: [Int] = []
    var failNextSend: Error?
    var failConnect: Error?
    var receiptDelay: Duration = .zero
    var sendDelay: Duration = .zero
    func setSendDelay(_ d: Duration) { sendDelay = d }
    var nextServerID = 0

    func setHandlers(_ h: ChatDriverHandlers) { handlers = h }

    func connect(contactID: String, participantID: String, participantToken: String?) async throws {
        if let e = failConnect { failConnect = nil; throw e }
        connects.append(participantToken ?? "<none>")
    }

    func disconnect() async throws { disconnects += 1 }
    var releases = 0
    func release() async throws { releases += 1 }

    func sendMessage(_ body: String, contentType: String) async throws -> SentMessageAck {
        if sendDelay > .zero { try await Task.sleep(for: sendDelay) }
        if let e = failNextSend { failNextSend = nil; throw e }
        sentBodies.append(body)
        sentContentTypes.append(contentType)
        nextServerID += 1
        return SentMessageAck(serverMessageID: "srv-\(nextServerID)", absoluteTime: "2026-10-08T14:00:0\(nextServerID).123Z")
    }

    func sendReceipt(_ kind: ReceiptKind, messageID: String) async throws {
        if receiptDelay > .zero { try await Task.sleep(for: receiptDelay) }
        receipts.append((kind, messageID))
    }
    func setReceiptDelay(_ d: Duration) { receiptDelay = d }
    var typingSent = 0
    func sendTyping() async throws { typingSent += 1 }

    var attachmentsSent: [URL] = []
    var failNextAttachment: Error?
    var downloadRequests: [String] = []
    func sendAttachment(file: URL) async throws {
        if let e = failNextAttachment { failNextAttachment = nil; throw e }
        attachmentsSent.append(file)
    }
    func attachmentDownloadURL(id: String) async throws -> URL {
        downloadRequests.append(id)
        return URL(string: "https://files.example/\(id)")!
    }
    func setFailNextAttachment(_ e: Error) { failNextAttachment = e }

    // Connect Views (A7)
    var describeRequests: [String] = []
    var nextViewDefinition = ConnectViewDefinition(id: "v-1", name: "Form", version: 1,
                                                   template: Data(#"{"Head":{"Title":"T"}}"#.utf8), inputSchema: nil, actions: ["Submit"])
    var failNextDescribe: Error?
    func describeView(viewToken: String) async throws -> ConnectViewDefinition {
        describeRequests.append(viewToken)
        if let e = failNextDescribe { failNextDescribe = nil; throw e }
        return nextViewDefinition
    }
    func setNextViewDefinition(_ d: ConnectViewDefinition) { nextViewDefinition = d }
    func setFailNextDescribe(_ e: Error) { failNextDescribe = e }

    // Authentication (A6)
    var authEventsEnabled = false
    var authURLRequests: [(sessionID: String, redirectURI: URL)] = []
    var cancelRequests: [String] = []
    var nextAuthURL: URL? = URL(string: "https://login.example/oauth2/authorize?client_id=c&state=st-1&nonce=n")
    var failCancel = false
    func enableAuthenticationEvents() { authEventsEnabled = true }
    func authenticationURL(sessionID: String, redirectURI: URL) async throws -> URL {
        authURLRequests.append((sessionID, redirectURI))
        guard let url = nextAuthURL else { throw NSError(domain: "auth", code: 1) }
        return url
    }
    func cancelAuthentication(sessionID: String) async throws {
        cancelRequests.append(sessionID)
        if failCancel { throw NSError(domain: "auth", code: 2) }
    }
    func setNextAuthURL(_ u: URL?) { nextAuthURL = u }
    func setFailCancel(_ f: Bool) { failCancel = f }

    func fetchTranscript(nextToken: String?, maxResults: Int) async throws -> RawTranscriptPage {
        transcriptRequests.append(nextToken)
        transcriptLimits.append(maxResults)
        guard !transcriptPages.isEmpty else { return RawTranscriptPage(items: [], nextToken: nil) }
        return transcriptPages.removeFirst()
    }

    // Scripting
    func setPages(_ p: [RawTranscriptPage]) { transcriptPages = p }
    func setFailNextSend(_ e: Error) { failNextSend = e }
    func setFailConnect(_ e: Error) { failConnect = e }
    func fire(_ f: @Sendable (ChatDriverHandlers) -> Void) { if let handlers { f(handlers) } }

}

private func agentMessage(_ text: String, id: String, time: String = "2026-10-08T14:00:00.500Z", role: String = "AGENT", pid: String? = "p-agent") -> RawTranscriptItem {
    RawTranscriptItem(kind: .message, id: id, absoluteTime: time, contentType: "text/plain", participantRole: role, participantID: pid, displayName: "Agent", text: text, isOutgoing: false)
}

private func customerEcho(_ text: String, id: String) -> RawTranscriptItem {
    RawTranscriptItem(kind: .message, id: id, absoluteTime: "2026-10-08T14:00:01.000Z", contentType: "text/plain", participantRole: "CUSTOMER", participantID: "p-me", displayName: "Me", text: text, isOutgoing: true)
}

private func participantEvent(_ contentType: String, role: String, pid: String, name: String = "X") -> RawTranscriptItem {
    RawTranscriptItem(kind: .event, id: "ev-\(pid)-\(contentType.suffix(6))", absoluteTime: "2026-10-08T14:00:00.000Z", contentType: contentType, participantRole: role, participantID: pid, displayName: name, text: nil, isOutgoing: false)
}

/// Collects transport events with a bounded wait.
actor TransportEventSink {
    var events: [TransportEvent] = []
    func add(_ e: TransportEvent) { events.append(e) }
}

private func drain(_ transport: ConnectChatTransport) -> (TransportEventSink, Task<Void, Never>) {
    let sink = TransportEventSink()
    let stream = transport.events
    let task = Task { for await e in stream { await sink.add(e) } }
    return (sink, task)
}

private func eventually(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

private let creds = ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: "tok", expiresAt: nil)

@Suite("ConnectChatTransport", .serialized)
struct ConnectChatTransportTests {
    @Test("Ordering contract: events raised before the first subscriber attaches are buffered, not dropped")
    func buffersUntilSubscribed() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(agentMessage("early", id: "m1")) }
        let (sink, task) = drain(t)   // subscribe late
        #expect(await eventually { await sink.events.count == 2 })
        #expect(await sink.events.first == .connected)
        task.cancel()
    }

    @Test("Lifecycle: connect → .connected; broken → .disconnected; ended → .contactEnded(.agentEnded); disconnect reaches the SDK once")
    func lifecycle() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        #expect(await d.connects == ["tok"])
        await d.fire { $0.onConnected() }
        await d.fire { $0.onConnectionBroken() }
        await d.fire { $0.onChatEnded() }
        #expect(await eventually { await sink.events.count == 3 })
        #expect(await sink.events == [.connected, .disconnected(error: nil), .contactEnded(.agentEnded)])
        await t.disconnect()
        #expect(await d.disconnects == 1)
        task.cancel()
    }

    @Test("Inbound agent message: normalised with ms sequence and participant id, stored as delivered, and a delivered receipt goes on the wire exactly once")
    func inboundAgentMessage() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(agentMessage("hello", id: "m1", time: "2026-10-08T14:00:00.500Z")) }
        #expect(await eventually { await sink.events.count == 2 })
        guard case .messageReceived(let m) = await sink.events[1] else { Issue.record("expected messageReceived"); return }
        #expect(m.serverMessageID == "m1")
        #expect(m.body == "hello")
        #expect(m.direction == .inbound && m.participantRole == .agent && m.deliveryState == .delivered)
        #expect(m.sequence == 1_791_468_000_500)                 // 2026-10-08T14:00:00.500Z in ms
        #expect(m.createdAt == Date(timeIntervalSince1970: 1_791_468_000.5))
        #expect(await eventually { await d.receipts.count == 1 })
        let receipts = await d.receipts
        #expect(receipts.first?.0 == .delivered && receipts.first?.1 == "m1")
        task.cancel()
    }

    @Test("Supervisor messages are human (delivered receipt sent); system and bot messages get no receipt and bot maps to assistant")
    func receiptPolicyByRole() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(agentMessage("sys", id: "s1", role: "SYSTEM", pid: nil)) }
        await d.fire { $0.onItem(agentMessage("bot", id: "b1", role: "CUSTOM_BOT", pid: "p-bot")) }
        await d.fire { $0.onItem(agentMessage("sup", id: "u1", role: "SUPERVISOR", pid: "p-sup")) }
        #expect(await eventually { await sink.events.count == 4 })
        let roles = await sink.events.compactMap { if case .messageReceived(let m) = $0 { m.participantRole } else { nil } }
        #expect(roles == [.system, .assistant, .supervisor])
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await d.receipts.map(\.1) == ["u1"])
        task.cancel()
    }

    @Test("Our own live echo is dropped: the server id comes from the send acknowledgement, not the websocket")
    func ownEchoDropped() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        _ = await eventually { await sink.events == [.connected] }   // the coordinator sends only once connected
        let id = UUID()
        try await t.send(OutboundMessage(clientMessageID: id, body: "hi"))
        await d.fire { $0.onItem(customerEcho("hi", id: "srv-1")) }
        #expect(await eventually { await sink.events.count == 2 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await sink.events.count == 2)
        #expect(await sink.events[1] == .messageDelivered(clientMessageID: id, serverMessageID: "srv-1", sequence: 1_791_468_001_123))
        #expect(await d.sentBodies == ["hi"])
        #expect(await d.sentContentTypes == ["text/plain"])
        task.cancel()
    }

    @Test("A choice goes out as web's interactive response, not as its text; the text stays the transcript's")
    func choiceSentAsInteractiveResponse() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        let response = try InteractiveContent.choiceResponse(InteractiveChoice(id: "card", text: "Replacement card"))
        try await t.send(OutboundMessage(body: "Replacement card", interactiveResponse: response))
        #expect(await d.sentContentTypes == ["application/vnd.amazonaws.connect.message.interactive.response"])
        let sent = try #require(await d.sentBodies.first)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: Any])
        #expect(obj["templateType"] as? String == "TouchpointModality")
        #expect(obj["action"] as? String == "Replacement card")
    }

    @Test("A failed send maps to TouchpointError.transportFailure carrying only the upstream domain and code, and never retries through the SDK")
    func sendFailureMapped() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        // Shaped like an AWS SDK for Swift service error: a Swift struct whose description can carry
        // request details. It bridges to the domain `<module>.AccessDeniedException`, code 1.
        await d.setFailNextSend(AccessDeniedException(message: "token=SECRET"))
        do {
            try await t.send(OutboundMessage(body: "x"))
            Issue.record("expected throw")
        } catch let e as TouchpointError {
            guard case .transportFailure(let s) = e else { Issue.record("wrong case \(e)"); return }
            #expect(s.hasSuffix(".AccessDeniedException(1)"), "\(s)")
            #expect(!s.contains("SECRET"))
        }
        #expect(await d.sentBodies.isEmpty)
    }

    @Test("connect failure maps to the taxonomy")
    func connectFailureMapped() async throws {
        let d = FakeChatDriver()
        await d.setFailConnect(NSError(domain: "ChatService", code: -1))
        let t = ConnectChatTransport(driver: d)
        await #expect(throws: TouchpointError.self) { try await t.connect(credentials: creds) }
    }

    @Test("Participant joined/left events carry the id and mapped role; receipts become TransportEvent.receipt")
    func participantsAndReceipts() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(participantEvent("application/vnd.amazonaws.connect.event.participant.joined", role: "AGENT", pid: "p-a", name: "Ann")) }
        await d.fire { $0.onItem(participantEvent("application/vnd.amazonaws.connect.event.participant.left", role: "AGENT", pid: "p-a")) }
        await d.fire { $0.onReceipt(.read, "srv-9") }
        #expect(await eventually { await sink.events.count == 4 })
        #expect(await sink.events[1] == .participantJoined(Participant(id: "p-a", role: .agent, displayName: "Ann")))
        #expect(await sink.events[2] == .participantLeft(id: "p-a"))
        #expect(await sink.events[3] == .receipt(serverMessageID: "srv-9", kind: .read))
        task.cancel()
    }

    @Test("Remote activity: agent typing becomes .typing, the customer's own echo does not, an interim frame becomes a status line and never a row")
    func remoteActivity() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onTyping("CUSTOMER") }                         // our own, echoed back
        await d.fire { $0.onTyping("AGENT") }
        let interim = #"{"templateType":"TouchpointModality","data":{"content":{"modalityPayload":{"type":"interim","message":"Checking your account…"}}}}"#
        let frame = RawTranscriptItem(kind: .message, id: "m-int", absoluteTime: "2026-10-08T14:00:02.000Z", contentType: ConnectContentType.interactive,
                                      participantRole: "CUSTOM_BOT", participantID: "p-bot", displayName: "Bot", text: interim, isOutgoing: false)
        await d.fire { $0.onItem(frame) }
        #expect(await eventually { await sink.events.count == 3 })
        #expect(await sink.events == [.connected, .remoteActivity(.typing), .remoteActivity(.interim("Checking your account…"))])
        // History never replays an interim message as a row.
        await d.setPages([RawTranscriptPage(items: [frame], nextToken: nil)])
        #expect(try await t.fetchTranscript(before: nil, limit: 10).messages.isEmpty)
        // Outbound typing reaches the wire.
        await t.sendTyping()
        #expect(await d.typingSent == 1)
        task.cancel()
    }

    @Test("Wrong credential type is rejected before any network call")
    func wrongCredentialType() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let voice = VoiceContactCredentials(contactID: "v", participantID: "p", participantToken: "t", meetingJSON: Data(), attendeeJSON: Data(), expiresAt: nil)
        await #expect(throws: TouchpointError.self) { try await t.connect(credentials: voice) }
        #expect(await d.connects.isEmpty)
    }

    @Test("markRead sends one read receipt for the given server id")
    func markRead() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        try await t.markRead(upTo: "m7")
        #expect(await d.receipts.map { "\($0.0)-\($0.1)" } == ["read-m7"])
    }

    @Test("fetchTranscript maps a page: messages (ours as outbound .sent, theirs as inbound .delivered), joins/leaves as events, token passthrough")
    func fetchTranscriptPage() async throws {
        let d = FakeChatDriver()
        await d.setPages([RawTranscriptPage(items: [
            participantEvent("application/vnd.amazonaws.connect.event.participant.joined", role: "AGENT", pid: "p-a", name: "Ann"),
            customerEcho("mine", id: "c-1"),
            agentMessage("theirs", id: "a-1"),
            RawTranscriptItem(kind: .event, id: "typing", absoluteTime: "2026-10-08T14:00:02.000Z", contentType: "application/vnd.amazonaws.connect.event.typing", participantRole: "AGENT", participantID: "p-a", displayName: "Ann", text: nil, isOutgoing: false),
        ], nextToken: "older")])
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        let page = try await t.fetchTranscript(before: nil, limit: 50)
        #expect(await d.transcriptRequests == [nil])
        #expect(page.nextToken == "older")
        #expect(page.participantEvents == [.participantJoined(Participant(id: "p-a", role: .agent, displayName: "Ann"))])
        #expect(page.messages.map(\.serverMessageID) == ["c-1", "a-1"])
        #expect(page.messages[0].direction == .outbound && page.messages[0].deliveryState == .sent && page.messages[0].participantRole == .customer)
        #expect(page.messages[1].direction == .inbound && page.messages[1].deliveryState == .delivered)
        // Transcript fetch does not re-send delivered receipts for history.
        #expect(await d.receipts.isEmpty)
        // Empty token from the service means exhausted.
        await d.setPages([RawTranscriptPage(items: [], nextToken: "")])
        #expect(try await t.fetchTranscript(before: "older", limit: 50).nextToken == nil)
    }

    @Test("Markdown and interactive content types are carried; interactive goes into interactiveJSON with the template type")
    func contentTypes() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(RawTranscriptItem(kind: .message, id: "md", absoluteTime: "2026-10-08T14:00:00.000Z", contentType: "text/markdown", participantRole: "AGENT", participantID: "p-a", displayName: "A", text: "**bold**", isOutgoing: false)) }
        let interactive = #"{"templateType":"ListPicker","version":"1.0","data":{"content":{"title":"Pick"}}}"#
        await d.fire { $0.onItem(RawTranscriptItem(kind: .message, id: "ix", absoluteTime: "2026-10-08T14:00:00.000Z", contentType: "application/vnd.amazonaws.connect.message.interactive", participantRole: "CUSTOM_BOT", participantID: "p-b", displayName: "Bot", text: interactive, isOutgoing: false)) }
        #expect(await eventually { await sink.events.count == 3 })
        let msgs = await sink.events.compactMap { if case .messageReceived(let m) = $0 { m } else { nil } }
        #expect(msgs[0].body == "**bold**" && msgs[0].interactiveJSON == nil)
        #expect(msgs[1].body == "Pick")                       // the title is the fallback body
        let ic = try JSONDecoder().decode(InteractiveContent.self, from: msgs[1].interactiveJSON ?? Data())
        #expect(ic.templateType == "ListPicker")
        // A template with no title (or a shape we do not summarise yet) must not surface raw JSON as the body.
        let untitled = #"{"templateType":"TimePicker","version":"1.0","data":{"content":{"timeslots":[]}}}"#
        await d.fire { $0.onItem(RawTranscriptItem(kind: .message, id: "tp", absoluteTime: "2026-10-08T14:00:00.000Z", contentType: "application/vnd.amazonaws.connect.message.interactive", participantRole: "CUSTOM_BOT", participantID: "p-b", displayName: "Bot", text: untitled, isOutgoing: false)) }
        #expect(await eventually { await sink.events.count == 4 })
        guard case .messageReceived(let m) = await sink.events[3] else { Issue.record("expected message"); return }
        #expect(m.body == "" && m.interactiveJSON != nil)
        task.cancel()
    }

    @Test("After disconnect, late SDK callbacks are dropped and nothing leaks into the next subscriber")
    func disconnectDropsLateFrames() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        _ = await eventually { await sink.events.count == 1 }
        await t.disconnect()
        await d.fire { $0.onItem(agentMessage("late", id: "late-1")) }
        await d.fire { $0.onConnectionBroken() }
        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()
        // A fresh subscriber for the next connection sees only what happens after it.
        let (sink2, task2) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        #expect(await eventually { await sink2.events.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await sink2.events == [.connected])
        #expect(await d.receipts.isEmpty)          // the late frame was never acknowledged either
        task2.cancel()
    }

    @Test("release keeps the server participant alive — driver.release, not disconnect — and still drops the socket")
    func releaseKeepsParticipant() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        _ = await eventually { await sink.events.count == 1 }
        await t.release()
        #expect(await d.releases == 1)
        #expect(await d.disconnects == 0)      // the participant was NOT ended, so the contact can resume
        // After release the socket is gone, so late frames are dropped like any dead connection.
        await d.fire { $0.onItem(agentMessage("late", id: "late-1")) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await sink.events == [.connected])
    }

    @Test("An ack that returns after the connection went is dropped, not buffered into the next contact")
    func lateAckDropped() async throws {
        let d = FakeChatDriver()
        await d.setSendDelay(.milliseconds(150))
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        _ = await eventually { await sink.events.count == 1 }
        let sendTask = Task { try await t.send(OutboundMessage(clientMessageID: UUID(), body: "hi")) }
        try? await Task.sleep(for: .milliseconds(30))   // the send is now awaiting its slow ack
        await t.disconnect()                            // the connection goes; the epoch moves on
        _ = try? await sendTask.value                   // the ack returns late, into a dead connection
        task.cancel()
        // A fresh contact's subscriber must never receive that stale ack.
        let (sink2, task2) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        #expect(await eventually { await sink2.events.count == 1 })
        try? await Task.sleep(for: .milliseconds(80))
        #expect(await sink2.events == [.connected])     // no .messageDelivered leaked across
        task2.cancel()
    }

    @Test("A slow delivered-receipt round trip does not delay the frames behind it")
    func receiptDoesNotBlockPump() async throws {
        let d = FakeChatDriver()
        await d.setReceiptDelay(.milliseconds(400))
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        for i in 1...5 { await d.fire { $0.onItem(agentMessage("m\(i)", id: "m\(i)")) } }
        // All five frames reach the consumer before a single 400 ms receipt has completed: proof the
        // receipt is off the pump. Completeness-and-ordering, not a wall-clock bound.
        #expect(await eventually { await sink.events.count == 6 })
        #expect(await d.receipts.isEmpty)
        let ids = await sink.events.compactMap { if case .messageReceived(let m) = $0 { m.serverMessageID } else { nil } }
        #expect(ids == ["m1", "m2", "m3", "m4", "m5"])                 // ordering preserved
        #expect(await eventually(.seconds(3)) { await d.receipts.count == 5 })
        task.cancel()
    }

    @Test("Receipts queued before a drop never go out on the next connection")
    func staleReceiptsDoNotCrossConnections() async throws {
        let d = FakeChatDriver()
        await d.setReceiptDelay(.milliseconds(200))
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        for i in 1...3 { await d.fire { $0.onItem(agentMessage("m\(i)", id: "old-\(i)")) } }
        _ = await eventually { await sink.events.count == 4 }
        await t.disconnect()                           // three receipts are still queued/in flight
        task.cancel()
        let (sink2, task2) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(agentMessage("fresh", id: "new-1")) }
        _ = await eventually { await sink2.events.count == 2 }
        #expect(await eventually(.seconds(3)) { await d.receipts.contains { $0.1 == "new-1" } })
        try? await Task.sleep(for: .milliseconds(700))
        let sent = await d.receipts.map(\.1)
        #expect(!sent.contains("old-2") && !sent.contains("old-3"), "stale receipts leaked: \(sent)")
        task2.cancel()
    }
    @Test("A subscriber that goes away without a disconnect does not swallow events meant for the next one")
    func eventsAfterSubscriberCancelledAreBuffered() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = drain(t)
        try await t.connect(credentials: creds)
        await d.fire { $0.onConnected() }
        _ = await eventually { await sink.events.count == 1 }
        // No `disconnect` (which clears the continuation itself): the consumer simply stops, as a
        // host that drops its own `events` iteration does. A yield into the finished stream reports
        // `.terminated`; the event must be buffered for the next subscriber, not dropped.
        task.cancel()
        try? await Task.sleep(for: .milliseconds(50))
        await d.fire { $0.onItem(agentMessage("after", id: "a-1")) }
        try? await Task.sleep(for: .milliseconds(50))
        let (sink2, task2) = drain(t)
        #expect(await eventually { await sink2.events.contains { if case .messageReceived(let m) = $0 { m.body == "after" } else { false } } })
        task2.cancel()
    }
}

// MARK: Custom chat client (web's `customChatClient`)

extension ConnectChatTransportTests {
    private var tokenless: ChatContactCredentials {
        ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: nil, expiresAt: nil)
    }

    @Test("No participant token and no custom chat client: connect fails naming the cause, and nothing reaches the SDK")
    func tokenlessWithoutCustomClientFails() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        await #expect(throws: TouchpointError.invalidConfiguration("no participant token and no custom chat client")) {
            try await t.connect(credentials: tokenless)
        }
        #expect(await d.connects.isEmpty)
    }

    @Test("With a custom chat client a contact needs no participant token: the session connects without one")
    func tokenlessWithCustomClientConnects() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d, usesCustomChatClient: true)
        try await t.connect(credentials: tokenless)
        #expect(await d.connects == ["<none>"])
    }
}

private struct AccessDeniedException: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
