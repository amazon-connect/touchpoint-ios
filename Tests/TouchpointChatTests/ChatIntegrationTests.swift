#if canImport(UIKit)
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// End-to-end through the real pieces: a `TouchpointSession` over a stub transport, the model the
/// view observes, and the view itself. The unit tests cover each piece; this covers the wiring,
/// which is where the first review round found the two defects that mattered — a sent message that
/// never appeared, and a second presentation that received no events.
@Suite("Chat UI integration", .serialized)
@MainActor
struct ChatIntegrationTests {
    private func makeSession() async throws -> (TouchpointSession, FakeChatDriver) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-ui-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let driver = FakeChatDriver()
        let transport = ConnectChatTransport(driver: driver)
        let backend = StubBackend()
        let session = TouchpointSession(broker: CredentialBroker(backend: backend, keychain: keychain),
                                        store: store, transports: [.chat: transport])
        return (session, driver)
    }

    private func eventually(_ timeout: Duration = .seconds(2), _ cond: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await cond() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await cond()
    }

    @Test("A message the user sends appears in the model immediately, before any server acknowledgement")
    func sentMessageAppears() async throws {
        let (session, driver) = try await makeSession()
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)   // what the launcher's first-page load does
        let pump = Task { @MainActor in for await e in session.events { model.ingest(e) } }
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        #expect(await eventually { model.canSend })
        _ = try await session.send("I need help with a charge")
        #expect(await eventually { model.messages.map(\.body) == ["I need help with a charge"] })
        #expect(model.rows.first?.message.direction == .outbound)
        #expect(model.rows.first?.showsDeliveryState == true)
        pump.cancel()
    }

    @Test("An agent reply reaches the model and is announced; the transcript keeps server order")
    func agentReplyAppears() async throws {
        let (session, driver) = try await makeSession()
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)   // what the launcher's first-page load does
        let pump = Task { @MainActor in for await e in session.events { model.ingest(e) } }
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        _ = await eventually { model.canSend }
        _ = try await session.send("hello")
        await driver.fire { $0.onItem(RawTranscriptItem(kind: .message, id: "a1", absoluteTime: "2026-10-08T18:00:00.000Z", contentType: "text/plain", participantRole: "AGENT", participantID: "p-a", displayName: "Ann", text: "Happy to help.", isOutgoing: false)) }
        #expect(await eventually { model.messages.count == 2 })
        // Wait for the ordering to settle rather than reading it the instant the count rises: an
        // unacknowledged echo is pinned to the tail by design, so the agent's sequenced reply sorts
        // *before* "hello" until the echo's own sequence arrives. Under load that ack lands after
        // the count does.
        #expect(await eventually { model.messages.last?.body == "Happy to help." })
        #expect(model.pendingAnnouncement?.contains("Support") == true)
        pump.cancel()
    }

    @Test("A second surface opened after the first closed still receives events (a dismissed sheet must not silence the next one)")
    func secondSurfaceStillReceivesEvents() async throws {
        let (session, driver) = try await makeSession()
        let first = ChatTranscriptModel()
        first.setInitial([], hasMore: false)
        let firstPump = Task { @MainActor in for await e in session.events { first.ingest(e) } }
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        _ = await eventually { first.canSend }
        firstPump.cancel()                             // the sheet is dismissed
        try? await Task.sleep(for: .milliseconds(50))
        let second = ChatTranscriptModel()
        second.setInitial([], hasMore: false)
        let secondPump = Task { @MainActor in for await e in session.events { second.ingest(e) } }
        try? await Task.sleep(for: .milliseconds(50))
        await driver.fire { $0.onItem(RawTranscriptItem(kind: .message, id: "a2", absoluteTime: "2026-10-08T18:01:00.000Z", contentType: "text/plain", participantRole: "AGENT", participantID: "p-a", displayName: "Ann", text: "Still here.", isOutgoing: false)) }
        #expect(await eventually { second.messages.map(\.body) == ["Still here."] })
        secondPump.cancel()
    }

    @Test("The status line follows the contact: reconnecting shows, connected clears, ended disables the composer")
    func statusFollowsContact() async throws {
        let (session, driver) = try await makeSession()
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)   // what the launcher's first-page load does
        let pump = Task { @MainActor in for await e in session.events { model.ingest(e) } }
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        #expect(await eventually { model.statusLine == nil && model.canSend })
        await driver.fire { $0.onConnectionBroken() }
        #expect(await eventually { model.statusLine == TouchpointStrings.reconnectingStatus })
        #expect(model.canSend, "composing while reconnecting is what the outbox is for")
        await driver.fire { $0.onChatEnded() }
        #expect(await eventually { model.items.last == TranscriptLayout.Item.notice(id: TranscriptLayout.endedNoticeID, text: TouchpointStrings.endedStatus) })
        // The drop said so, and with no recovery before the end it stays (Android's problem row).
        #expect(model.items.contains { if case .error(_, TouchpointStrings.connectionLostNotice) = $0 { true } else { false } })
        #expect(!model.canSend)
        pump.cancel()
    }

    @Test("Rendering the surface against a live session produces a non-empty image")
    func rendersAgainstLiveSession() async throws {
        let (session, driver) = try await makeSession()
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        let view = TouchpointChatView(session: session, header: ChatHeader(title: "Acme Support"), onClose: {})
            .frame(width: 390, height: 600)
        let renderer = ImageRenderer(content: view)
        #expect(renderer.uiImage != nil)
    }
}

private struct StubBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        ChatContactCredentials(contactID: "c-ui", participantID: "p-me", participantToken: "tok", expiresAt: nil)
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw TouchpointError.contactNotFound }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.contactNotFound }
}
#endif
