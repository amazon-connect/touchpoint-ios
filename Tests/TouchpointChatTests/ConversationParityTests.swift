import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

// MARK: - Conversation parity with Android and web (gap index CV-1…9)

private let creds = ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: "tok", expiresAt: nil)

private func item(_ kind: RawTranscriptItem.Kind = .message, id: String, contentType: String = "text/plain", role: String = "AGENT",
                  name: String = "Alex", text: String?, attachment: MessageAttachment? = nil) -> RawTranscriptItem {
    RawTranscriptItem(kind: kind, id: id, absoluteTime: "2026-10-08T14:00:0\(id.suffix(1)).000Z", contentType: contentType,
                      participantRole: role, participantID: "p-\(role)", displayName: name, text: text,
                      isOutgoing: role == "CUSTOMER", attachment: attachment)
}

private func waitUntil(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

private func inbound(_ body: String, interactive: InteractiveContent? = nil) -> Message {
    Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s", body: body, direction: .inbound, participantRole: .agent,
                          deliveryState: .delivered, interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) }))
}

@Suite("Conversation parity (B1)")
struct ConversationParityTests {
    // MARK: CV-1 server transcript

    @Test("CV-1: the server's lines are the words a person reads — no files, events, interim lines or raw JSON")
    func transcriptEntries() async throws {
        let d = FakeChatDriver()
        let quick = #"{"templateType":"QuickReply","data":{"content":{"title":"Pick one","elements":[{"title":"A"}]}}}"#
        let interim = #"{"templateType":"TouchpointModality","data":{"content":{"modalityPayload":{"type":"interim","message":"Checking"}}}}"#
        await d.setPages([RawTranscriptPage(items: [
            item(id: "m1", text: "Hello"),
            item(id: "m2", role: "CUSTOMER", name: "", text: "Hi"),
            item(.event, id: "e3", contentType: ConnectContentType.joined, text: nil),
            item(id: "m4", text: "file.pdf", attachment: MessageAttachment(id: "a", name: "file.pdf", contentType: "application/pdf")),
            item(id: "m5", contentType: ConnectContentType.interactive, text: quick),
            item(id: "m6", contentType: ConnectContentType.interactive, text: interim),
            item(id: "m7", contentType: ConnectContentType.json, text: #"{"messages":[{"text":"From JSON"}]}"#),
        ], nextToken: nil)])
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: creds)
        let entries = try await t.fetchTranscriptEntries(limit: 100)
        #expect(entries.map(\.text) == ["Hello", "Hi", "Pick one", "From JSON"])
        #expect(entries.map(\.name) == ["Alex", "CUSTOMER", "Alex", "Alex"], "Connect's display name, or the role when it has none")
        #expect(entries.first?.absoluteTime == "2026-10-08T14:00:01.000Z")
        #expect(await d.transcriptLimits == [100])
        #expect(!String(describing: entries[0]).contains("Hello"), "a transcript line's words are redacted from logs")
    }

    @Test("CV-1: web's file format — [time] name: words, one line each")
    func transcriptFormat() {
        let text = ChatSettingsPanel.transcript(entries: [
            TranscriptEntry(absoluteTime: "t1", name: "Alex", role: .agent, text: "Hello"),
            TranscriptEntry(absoluteTime: "t2", name: "Jordan", role: .customer, text: "Hi"),
        ])
        #expect(text == "[t1] Alex: Hello\n[t2] Jordan: Hi")
    }

    // MARK: CV-2 contact ended, once

    @Test("CV-2: an end is reported once; not the end the view found on subscribing; not an end during restart")
    func contactEndReporter() {
        var fresh = ContactEndReporter(endedAtSubscribe: nil)
        let first = fresh.shouldReport(contactID: "c1"), repeated = fresh.shouldReport(contactID: "c1"), next = fresh.shouldReport(contactID: "c2")
        #expect(first)
        #expect(!repeated, "a repeated end is the same end")
        #expect(next)

        var late = ContactEndReporter(endedAtSubscribe: "c1")
        let replayed = late.shouldReport(contactID: "c1"), later = late.shouldReport(contactID: "c2")
        #expect(!replayed, "the replay of an end that happened before the view existed")
        #expect(later)

        var restarting = ContactEndReporter(endedAtSubscribe: nil)
        restarting.restarting = true
        let during = restarting.shouldReport(contactID: "c1")
        restarting.restarting = false
        let after = restarting.shouldReport(contactID: "c1"), nextContact = restarting.shouldReport(contactID: "c2")
        #expect(!during)
        #expect(!after, "the restart's end stays unreported once it is over")
        #expect(nextContact)
    }

    // MARK: CV-3 announcements

    @Test("CV-3: an arrival is announced by its words, then how many options it offers")
    func announcements() {
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("Hello **there**")) == "Hello there")
        let two = InteractiveContent(templateType: "QuickReply", rawJSON: Data(#"{"data":{"content":{"title":"Pick","elements":[{"title":"A"},{"title":"B"}]}}}"#.utf8))
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("Pick", interactive: two)) == "Pick 2 options to choose from")
        let one = InteractiveContent(templateType: "QuickReply", rawJSON: Data(#"{"data":{"content":{"title":"Pick","elements":[{"title":"A"}]}}}"#.utf8))
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("Pick", interactive: one)) == "Pick 1 option to choose from")
        let file = InteractiveContent.attachment(MessageAttachment(id: "a", name: "receipt.pdf", contentType: "application/pdf"))
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("", interactive: file)) == "receipt.pdf")
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("")) == "Response received")
        #expect(ChatTranscriptModel.arrivalAnnouncement(inbound("1. First\n2. Second")) == "First. Second")
    }

    // MARK: CV-4 cap

    @Test("CV-4: at most 100 choices")
    func choiceCap() {
        let elements = (1...150).map { #"{"title":"c\#($0)"}"# }.joined(separator: ",")
        let content = InteractiveContent(templateType: "QuickReply", rawJSON: Data(#"{"data":{"content":{"title":"t","elements":[\#(elements)]}}}"#.utf8))
        #expect(content.choices.count == 100)
        let lenient = (1...150).map { #"{"choiceText":"c\#($0)"}"# }.joined(separator: ",")
        let modality = InteractiveContent(templateType: "TouchpointModality",
                                          rawJSON: Data(#"{"data":{"content":{"modalityPayload":{"type":"message","choices":[\#(lenient)]}}}}"#.utf8))
        #expect(modality.choices.count == 100)
    }

    @Test("CV-7: a lenient choice with no text is Option N")
    func untitledLenient() {
        let modality = InteractiveContent(templateType: "TouchpointModality",
                                          rawJSON: Data(#"{"data":{"content":{"modalityPayload":{"type":"message","choices":[{"choiceId":"a"},{"choiceText":"B"}]}}}}"#.utf8))
        #expect(modality.choices == [InteractiveChoice(id: "a", text: "Option 1"), InteractiveChoice(id: "choice-1", text: "B")])
    }
}

@Suite("Conversation parity (B1): session", .serialized)
@MainActor
struct ConversationParitySessionTests {
    private struct Backend: TouchpointBackend {
        func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { creds }
        func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw TouchpointError.invalidConfiguration("chat only") }
        func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
    }

    private func connected() async throws -> (TouchpointSession, FakeChatDriver) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-cv-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let driver = FakeChatDriver()
        let session = TouchpointSession(broker: CredentialBroker(backend: Backend(), keychain: keychain), store: store,
                                        transports: [.chat: ConnectChatTransport(driver: driver)])
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        #expect(await waitUntil { await MainActor.run { session.state == .connected } })
        return (session, driver)
    }

    @Test("CV-1: the session asks for at most 100 lines")
    func serverTranscriptLimit() async throws {
        let (session, driver) = try await connected()
        _ = try await session.serverTranscript(limit: 500)
        #expect(await driver.transcriptLimits.last == 100)
        await session.end()
    }

    // Sent as the connection comes up, so it races the connect's own flush — the case that once
    // failed it unsent (two outbox reads, the row appended between them, looked unreadable).
    @Test("CV-6: a choice too large for an interactive response goes as its text instead of failing")
    func oversizedChoiceFallsBack() async throws {
        let (session, driver) = try await connected()
        _ = try await session.sendChoice(InteractiveChoice(id: String(repeating: "x", count: 20_000), text: "Yes please"))
        #expect(await waitUntil(.seconds(10)) { await driver.sentBodies == ["Yes please"] })
        #expect(await driver.sentContentTypes == [ConnectContentType.plainText])
        await session.end()
    }

    @Test("CV-9: a re-established connection reconciles and holds dispatch, as a reconnect does")
    func reestablishedReconciles() async throws {
        let (session, driver) = try await connected()
        let before = await driver.transcriptRequests.count
        await driver.fire { $0.onReestablished() }
        #expect(await waitUntil { await driver.transcriptRequests.count > before }, "no reconcile after re-establishing")
        #expect(session.state == .connected)
        await session.end()
    }

    @Test("Android parity: a drop that reconnects takes its \"Connection lost\" row away again")
    func reconnectClearsConnectionProblem() async throws {
        let (session, driver) = try await connected()
        let model = ChatTranscriptModel()
        model.setInitial([])
        let pump = Task { @MainActor in for await e in session.events { model.ingest(e) } }
        defer { pump.cancel() }
        let id = TranscriptLayout.connectionProblemID
        #expect(await waitUntil { await MainActor.run { model.state == .connected } })
        await driver.fire { $0.onConnectionBroken() }
        #expect(await waitUntil { await MainActor.run { model.items.contains { $0.id == id } && model.statusLine == TouchpointStrings.reconnectingStatus } })
        // The session reconnects on its own: a second connect, which the socket then completes.
        #expect(await waitUntil(.seconds(10)) { await driver.connects.count >= 2 }, "no reconnect attempt")
        await driver.fire { $0.onConnected() }
        #expect(await waitUntil { await MainActor.run { model.state == .connected && !model.items.contains { $0.id == id } } },
                "the row outlived the reconnect")
        await session.end()
    }
}
