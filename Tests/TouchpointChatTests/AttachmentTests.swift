import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

// MARK: - Attachments (gap index AT-1…7)
//
// The vendor SDK uploads and signs downloads; these tests cover what the SDK adds around it: the
// message carrier, the transport mapping (live and history), the session API, the composer's
// validation and visibility rules, and the transcript's treatment of attachment rows.

private let receipt = MessageAttachment(id: "att-1", name: "receipt.pdf", contentType: "application/pdf")

private func attachmentItem(id: String = "m-att", outgoing: Bool = false) -> RawTranscriptItem {
    RawTranscriptItem(kind: .message, id: id, absoluteTime: "2026-10-08T14:00:02.000Z", contentType: "application/pdf",
                      participantRole: outgoing ? "CUSTOMER" : "AGENT", participantID: outgoing ? "p-me" : "p-agent",
                      displayName: outgoing ? "Me" : "Agent", text: "receipt.pdf", isOutgoing: outgoing,
                      attachment: receipt)
}

private let chatCreds = ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: "tok", expiresAt: nil)

private actor Sink {
    var events: [TransportEvent] = []
    func add(_ e: TransportEvent) { events.append(e) }
}

private func pumpEvents(_ t: ConnectChatTransport) -> (Sink, Task<Void, Never>) {
    let sink = Sink()
    let stream = t.events
    return (sink, Task { for await e in stream { await sink.add(e) } })
}

private func waitUntil(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

private func message(body: String = "", direction: Direction, attachment: MessageAttachment?) throws -> Message {
    Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s", body: body, direction: direction,
                          participantRole: direction == .outbound ? .customer : .agent, deliveryState: .delivered,
                          interactiveJSON: try attachment.map { try JSONEncoder().encode(InteractiveContent.attachment($0)) }))
}

@Suite("Attachments: carrier, mapping, rules")
struct AttachmentTests {
    @Test("A1: an attachment round-trips through the interactive carrier; nothing else reads as one")
    func carrier() throws {
        let content = InteractiveContent.attachment(receipt)
        #expect(content.templateType == InteractiveContent.attachmentTemplateType)
        #expect(content.attachment == receipt)
        #expect(content.choices.isEmpty)
        #expect(content.modalities.isEmpty)
        let decoded = try JSONDecoder().decode(InteractiveContent.self, from: JSONEncoder().encode(content))
        #expect(decoded.attachment == receipt, "persists through interactiveJSON with no schema change")
        #expect(InteractiveContent(templateType: "QuickReply", rawJSON: Data("{}".utf8)).attachment == nil)
        #expect(InteractiveContent(templateType: InteractiveContent.attachmentTemplateType, rawJSON: Data("nope".utf8)).attachment == nil)
    }

    @Test("A2: a live agent attachment becomes a message with an empty body and the attachment")
    func liveMapping() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        let (sink, task) = pumpEvents(t); defer { task.cancel() }
        try await t.connect(credentials: chatCreds)
        await d.fire { $0.onConnected() }
        await d.fire { $0.onItem(attachmentItem()) }
        #expect(await waitUntil { await sink.events.count >= 2 })
        guard case .messageReceived(let stored) = await sink.events[1] else { Issue.record("expected a message"); return }
        let m = Message(stored)
        #expect(m.body == "")
        #expect(m.direction == .inbound)
        #expect(m.attachment == receipt)
    }

    @Test("A3: history keeps attachments, the customer's own as outbound (AT-6)")
    func historyMapping() async throws {
        let d = FakeChatDriver()
        await d.setPages([RawTranscriptPage(items: [attachmentItem(id: "h1"), attachmentItem(id: "h2", outgoing: true)], nextToken: nil)])
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: chatCreds)
        let page = try await t.fetchTranscript(before: nil, limit: 20)
        let messages = page.messages.map(Message.init)
        #expect(messages.map(\.attachment) == [receipt, receipt])
        #expect(messages.map(\.direction) == [.inbound, .outbound])
    }

    @Test("A5: sending forwards the file to the driver; a driver failure surfaces as a TouchpointError")
    func sendForwards() async throws {
        let d = FakeChatDriver()
        let t = ConnectChatTransport(driver: d)
        try await t.connect(credentials: chatCreds)
        let file = URL(fileURLWithPath: "/tmp/receipt.pdf")
        try await t.sendAttachment(fileURL: file)
        #expect(await d.attachmentsSent == [file])
        await d.setFailNextAttachment(NSError(domain: "x", code: 1))
        await #expect(throws: TouchpointError.self) { try await t.sendAttachment(fileURL: file) }
        let url = try await t.attachmentURL(id: "att-1")
        #expect(url.absoluteString == "https://files.example/att-1")
        #expect(await d.downloadRequests == ["att-1"])
    }

    @Test("A7: web's types and 8 MB cap; webp and avi refused (the vendor SDK refuses them)")
    func validation() {
        let mb = 1024 * 1024
        #expect(AttachmentPolicy.validate(fileName: "a.PDF", size: 1) == .accepted)
        for name in ["a.jpg", "a.jpeg", "a.png", "a.mp4", "a.mov", "a.pdf"] {
            #expect(AttachmentPolicy.validate(fileName: name, size: 8 * mb) == .accepted, "\(name)")
        }
        #expect(AttachmentPolicy.validate(fileName: "a.pdf", size: 8 * mb + 1) == .tooBig)
        #expect(AttachmentPolicy.validate(fileName: "a.webp", size: 1) == .unsupportedType)
        #expect(AttachmentPolicy.validate(fileName: "a.avi", size: 1) == .unsupportedType)
        #expect(AttachmentPolicy.validate(fileName: "noext", size: 1) == .unsupportedType)
        #expect(AttachmentPolicy.contentTypes.count == 5, "jpeg, png, mpeg-4, quicktime, pdf")
    }

    @Test("A8: an attachment row is renderable with an empty body, in either direction")
    func renderable() throws {
        #expect(TranscriptLayout.isRenderable(try message(direction: .inbound, attachment: receipt)))
        #expect(TranscriptLayout.isRenderable(try message(direction: .outbound, attachment: receipt)))
        #expect(!TranscriptLayout.isRenderable(try message(direction: .outbound, attachment: nil)))
    }

    @MainActor
    @Test("A9: the downloaded transcript leaves attachments out (AT-7)")
    func transcriptExclusion() throws {
        let text = ChatSettingsPanel.transcript([
            try message(body: "Here it is", direction: .outbound, attachment: nil),
            try message(direction: .outbound, attachment: receipt),
        ])
        #expect(text.contains("Here it is"))
        #expect(!text.contains("receipt.pdf"))
    }

    @Test("A10: the paperclip shows only while a human agent is present, the chat can send, and a host handles it")
    func composerVisibility() {
        #expect(MessageComposer.offersAttachment(isEnabled: true, agentPresent: true, canAttach: true))
        #expect(!MessageComposer.offersAttachment(isEnabled: true, agentPresent: false, canAttach: true))
        #expect(!MessageComposer.offersAttachment(isEnabled: false, agentPresent: true, canAttach: true))
        #expect(!MessageComposer.offersAttachment(isEnabled: true, agentPresent: true, canAttach: false))
    }
}

private struct ChatOnlyBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { chatCreds }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        throw TouchpointError.invalidConfiguration("chat only")
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
}

@Suite("Attachments: session API", .serialized)
@MainActor
struct AttachmentSessionTests {
    @Test("A11: the session forwards only on a connected chat")
    func sessionGuards() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-att-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let driver = FakeChatDriver()
        let session = TouchpointSession(broker: CredentialBroker(backend: ChatOnlyBackend(), keychain: keychain),
                                        store: store, transports: [.chat: ConnectChatTransport(driver: driver)])
        let file = URL(fileURLWithPath: "/tmp/receipt.pdf")
        await #expect(throws: TouchpointError.self) { try await session.sendAttachment(fileURL: file) }

        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        #expect(await waitUntil { await MainActor.run { session.state == .connected } })
        try await session.sendAttachment(fileURL: file)
        #expect(await driver.attachmentsSent == [file])
        #expect(try await session.attachmentURL(id: "att-1").absoluteString == "https://files.example/att-1")
        await session.end()
    }
}
