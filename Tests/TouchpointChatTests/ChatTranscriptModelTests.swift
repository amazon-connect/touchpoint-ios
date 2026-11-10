import Foundation
import Testing
import SwiftUI
import TouchpointCore
@testable import TouchpointChat
@testable import TouchpointCore

@Suite("Chat transcript model")
@MainActor
struct ChatTranscriptModelTests {
    private func msg(_ body: String, _ direction: Direction, role: ParticipantRole = .agent, seq: Int?, state: DeliveryState = .delivered, id: UUID = UUID()) -> Message {
        Message(StoredMessage(clientMessageID: id, serverMessageID: seq.map { "s\($0)" }, body: body,
                              direction: direction, participantRole: role, sequence: seq, deliveryState: state))
    }

    @Test("Rows are one per message, in order, with nothing merged — as web's per-message responses are")
    func rowsAreOnePerMessageInOrder() {
        // Run grouping used to drive a per-run sender name and a tighter in-run gap. Web has
        // neither: `appendResponse` is a plain append with no merging (`conversation.ts:566-569`),
        // so the only structural claim left worth asserting is that nothing is merged, dropped or
        // reordered. The previous version of this test asserted `rows.count == 4`, which holds for
        // any four messages and so tested nothing.
        let sent = [
            msg("one", .inbound, seq: 1), msg("two", .inbound, seq: 2),
            msg("mine", .outbound, role: .customer, seq: 3, state: .sent),
            msg("three", .inbound, seq: 4),
        ]
        let rows = TranscriptLayout.rows(for: sent)
        #expect(rows.map(\.message.body) == ["one", "two", "mine", "three"])
        #expect(rows.map(\.id) == sent.map(\.clientMessageID))
    }

    @Test("A supervisor is still named to VoiceOver, even though no name is drawn")
    func supervisorNamedToVoiceOver() {
        // Web has no supervisor concept at all — it maps every non-AGENT role to "bot" — so not
        // drawing the name is not a parity loss. The name still reaches a screen reader.
        #expect(ChatTranscriptModel.senderName(msg("supervisor", .inbound, role: .supervisor, seq: 2))
                == TouchpointStrings.supervisorSenderLabel)
    }

    @Test("Only the newest outbound message shows its delivery state; earlier ones stay quiet unless failed")
    func deliveryStateVisibility() {
        let rows = TranscriptLayout.rows(for: [
            msg("old", .outbound, role: .customer, seq: 1, state: .read),
            msg("failed", .outbound, role: .customer, seq: nil, state: .failed),
            msg("newest", .outbound, role: .customer, seq: 3, state: .sent),
        ])
        #expect(rows.map(\.showsDeliveryState) == [false, true, true])
        #expect(rows[1].isRetryable)
        #expect(!rows[2].isRetryable)
    }

    @Test("The model surfaces an announcement only for inbound messages that are new to it")
    func announcements() async throws {
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)      // a first page landed: announcements are meaningful
        #expect(model.pendingAnnouncement == nil)
        model.ingest(.messageReceived(msg("hello", .inbound, seq: 1)))
        #expect(model.pendingAnnouncement == "hello", "web speaks the message's words (CV-3)")
        model.clearAnnouncement()
        #expect(model.pendingAnnouncement == nil)
        // Our own echo is not announced: the user just typed it.
        model.ingest(.messageReceived(msg("mine", .outbound, role: .customer, seq: 2, state: .sent)))
        #expect(model.pendingAnnouncement == nil)
    }

    @Test("Connection state maps to a status line the host can render, and only when it is not connected")
    func statusLine() {
        let model = ChatTranscriptModel()
        #expect(model.statusLine == nil)
        // `.connecting` is carried by `interim`, not `statusLine`, because web's
        // `CONNECTING_INTERIM_MESSAGE` is an interim message rather than a separate status row.
        // Drawing it in both would draw it twice.
        model.ingest(.stateChanged(.connecting))
        #expect(model.statusLine == nil)
        #expect(model.interim == TouchpointStrings.connectingStatus)
        model.ingest(.stateChanged(.reconnecting(attempt: 2)))
        #expect(model.statusLine == TouchpointStrings.reconnectingStatus)
        #expect(model.interim == nil, "reconnecting is the transport talking, not the assistant")
        model.ingest(.stateChanged(.connected))
        #expect(model.statusLine == nil)
        #expect(model.interim == nil)
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.statusLine == nil, "ended is a transcript notice now, as web's is")
        #expect(model.items.last == TranscriptLayout.Item.notice(id: TranscriptLayout.endedNoticeID, text: TouchpointStrings.endedStatus))
        #expect(model.interim == nil)
        #expect(!model.canSend)
    }

    /// Web sets its interim message when a send goes out and clears it on anything inbound
    /// (`conversation.ts:1320` and every inbound path). Before this existed, sending a message
    /// produced no visible change at all until the reply landed.
    @Test("A send shows the assistant working; an inbound message clears it")
    func interimOnSend() {
        let model = ChatTranscriptModel()
        model.setInitial([])                       // a first page has landed: traffic is live
        model.ingest(.stateChanged(.connected))
        #expect(model.interim == nil)

        model.ingest(.messageReceived(msg("hello", .outbound, seq: 1)))
        #expect(model.interim == TouchpointStrings.thinkingStatus)

        model.ingest(.messageReceived(msg("hi there", .inbound, seq: 2)))
        #expect(model.interim == nil, "an inbound message means the assistant is no longer working")
    }

    /// The guard that stops a resumed conversation shimmering at nobody: until a first page has
    /// landed the model cannot tell replayed history from a live send, and a backlog whose newest
    /// row happens to be ours would otherwise look like a turn in flight for ever.
    @Test("Replayed history does not show the assistant working")
    func interimIgnoresReplay() {
        let model = ChatTranscriptModel()
        model.ingest(.stateChanged(.connected))
        // No `setInitial`, so nothing has established what is live yet.
        model.ingest(.messageReceived(msg("mine", .outbound, seq: 1)))
        #expect(model.interim == nil)
    }

    /// Web: `escalated ? undefined : copy.thinking`. A human agent may take minutes, so claiming
    /// the assistant is thinking would be a lie.
    @Test("An escalated contact does not claim the assistant is thinking")
    func interimSuppressedWhenEscalated() {
        let model = ChatTranscriptModel()
        model.setInitial([])
        model.ingest(.stateChanged(.connected))
        var participants = ParticipantSet()
        participants.join(Participant(id: "a1", role: .agent, displayName: "Chirag"))
        model.ingest(.participantsChanged(participants))

        model.ingest(.messageReceived(msg("hello", .outbound, seq: 1)))
        #expect(model.interim == nil)

        // The assistant alone is not an escalation.
        var botOnly = ParticipantSet()
        botOnly.join(Participant(id: "bot", role: .assistant, displayName: "Assistant"))
        model.ingest(.participantsChanged(botOnly))
        model.ingest(.messageReceived(msg("again", .outbound, seq: 2)))
        #expect(model.interim == TouchpointStrings.thinkingStatus)
    }

    @Test("Reset drops the working state with everything else")
    func interimClearedOnReset() {
        let model = ChatTranscriptModel()
        model.setInitial([])
        model.ingest(.stateChanged(.connected))
        model.ingest(.messageReceived(msg("hello", .outbound, seq: 1)))
        #expect(model.interim == TouchpointStrings.thinkingStatus)
        model.reset()
        #expect(model.interim == nil)
    }

    /// Web's single interim slot (`conversation.ts:954-967, 1108-1109`): an agent typing event
    /// shows "Typing…", a flow's interim frame shows its own words, the last one wins, and any
    /// inbound message clears it. Typing is shown on an escalated contact — that is who types.
    @Test("Typing and a flow's interim words share web's one interim slot; an inbound message clears it")
    func remoteActivityInterim() {
        let model = ChatTranscriptModel()
        model.setInitial([])
        model.ingest(.stateChanged(.connected))
        var agent = ParticipantSet()
        agent.join(Participant(id: "a1", role: .agent, displayName: "Sam"))
        model.ingest(.participantsChanged(agent))

        model.ingest(.remoteActivity(.typing))
        #expect(model.interim == TouchpointStrings.typingStatus)
        model.ingest(.remoteActivity(.interim("Checking your account…")))
        #expect(model.interim == "Checking your account…", "the last writer wins, as in web")
        model.ingest(.messageReceived(msg("Found it.", .inbound, seq: 1)))
        #expect(model.interim == nil)

        // A send replaces typing with "Thinking…" (withheld here, since the contact is escalated).
        model.ingest(.remoteActivity(.typing))
        model.ingest(.messageReceived(msg("ok", .outbound, role: .customer, seq: 2)))
        #expect(model.interim == nil)
        // Nothing survives the contact ending.
        model.ingest(.remoteActivity(.typing))
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.interim == nil)
    }

    @Test("Typing lapses on its own when no message follows, and a fresh event restarts the clock")
    func typingExpires() async {
        let model = ChatTranscriptModel()
        model.typingLifetime = .milliseconds(150)
        model.setInitial([])
        model.ingest(.stateChanged(.connected))
        model.ingest(.remoteActivity(.typing))
        try? await Task.sleep(for: .milliseconds(100))
        model.ingest(.remoteActivity(.typing))            // still typing: the 150 ms restarts
        try? await Task.sleep(for: .milliseconds(100))
        #expect(model.interim == TouchpointStrings.typingStatus, "the second event should have restarted the lifetime")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(model.interim == nil, "typing should lapse without a message")
        // A flow's interim words do not lapse: they are cleared by the reply.
        model.ingest(.remoteActivity(.interim("One moment")))
        try? await Task.sleep(for: .milliseconds(250))
        #expect(model.interim == "One moment")
    }

    @Test("canSend reflects the contact state so the composer disables itself rather than failing silently")
    func canSend() {
        let model = ChatTranscriptModel()
        #expect(!model.canSend)                       // idle: nothing to send to
        model.ingest(.stateChanged(.connected))
        #expect(model.canSend)
        model.ingest(.stateChanged(.reconnecting(attempt: 1)))
        #expect(model.canSend)                        // offline composing is the whole point of the outbox
        model.ingest(.stateChanged(.ended(.customerEnded)))
        #expect(!model.canSend)
    }

    @Test("Messages are replaced in place by client id, so a delivery-state change does not duplicate a row")
    func updateInPlace() {
        let model = ChatTranscriptModel()
        let id = UUID()
        model.ingest(.messageReceived(msg("mine", .outbound, role: .customer, seq: nil, state: .sending, id: id)))
        #expect(model.messages.count == 1)
        model.ingest(.deliveryStateChanged(DeliveryUpdate(clientMessageID: id, state: .sent)))
        #expect(model.messages.count == 1)
        #expect(model.messages[0].deliveryState == .sent)
    }

    @Test("Paging: the model asks for earlier messages once and knows when the transcript is exhausted")
    func paging() async throws {
        let model = ChatTranscriptModel()
        model.setInitial([msg("newest", .inbound, seq: 10)])
        #expect(!model.canLoadEarlier, "an empty or complete first page must not offer to load more")
        model.setInitial([msg("newest", .inbound, seq: 10)], hasMore: true)
        #expect(model.canLoadEarlier)
        var calls = 0
        await model.loadEarlier { calls += 1; return ([self.msg("older", .inbound, seq: 1)], true) }
        #expect(calls == 1 && model.messages.map(\.body) == ["older", "newest"])
        await model.loadEarlier { calls += 1; return ([], false) }
        #expect(calls == 2 && !model.canLoadEarlier)
        await model.loadEarlier { calls += 1; return ([], false) }
        #expect(calls == 2)                           // exhausted: no further requests
    }

    @Test("A page that overlaps rows the live stream already delivered does not duplicate them")
    func pagingDeduplicates() async throws {
        let model = ChatTranscriptModel()
        let shared = UUID()
        model.setInitial([msg("already here", .inbound, seq: 5, id: shared)], hasMore: true)
        await model.loadEarlier { ([self.msg("older", .inbound, seq: 1), self.msg("already here", .inbound, seq: 5, id: shared)], false) }
        #expect(model.messages.map(\.body) == ["older", "already here"])
        #expect(model.messages.count == 2)
    }

    @Test("A failed page is reported rather than leaving an inert button")
    func pagingFailureVisible() async throws {
        struct Boom: Error {}
        let model = ChatTranscriptModel()
        model.setInitial([msg("newest", .inbound, seq: 2)], hasMore: true)
        await model.loadEarlier { throw Boom() }
        #expect(model.pagingFailed)
        #expect(model.canLoadEarlier)                 // still retryable
        await model.loadEarlier { ([self.msg("older", .inbound, seq: 1)], false) }
        #expect(!model.pagingFailed)
    }

    @Test("Reduce Motion removes the scroll animation rather than the scroll")
    func reduceMotionDisablesAnimation() {
        #expect(ChatTranscriptView.scrollAnimation(reduceMotion: true) == nil)
        #expect(ChatTranscriptView.scrollAnimation(reduceMotion: false) != nil)
    }

    @Test("Dynamic Type categories map to a strictly increasing metric scale")
    func typeScaleMonotonic() {
        let sizes: [DynamicTypeSize] = [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge,
                                        .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5]
        let scales = sizes.map { ChatTranscriptView.scale(for: $0) }
        for (a, b) in zip(scales, scales.dropFirst()) { #expect(b > a) }
    }

    @Test("The chat surface takes an optional header: a title and a close action, as every screen in the design has one")
    func headerConfiguration() {
        var header = ChatHeader(title: "Acme Assistant")
        #expect(header.title == "Acme Assistant")
        header.title = "Acme Support"
        #expect(header.title == "Acme Support")
        #expect(ChatHeader().title == nil)   // the template draws no title
        // The close control exists exactly when the host supplies an action for it; there is no
        // separate flag that could promise a button and then render nothing.
    }

    @Test("Historical rows delivered after the live tail are placed in transcript order, not arrival order")
    func reconciledRowsSortIntoPlace() {
        let model = ChatTranscriptModel()
        model.ingest(.messageReceived(msg("newest", .inbound, seq: 30)))
        let echo = UUID()
        model.ingest(.messageReceived(msg("my echo", .outbound, role: .customer, seq: nil, state: .sending, id: echo)))
        // Reconciliation now delivers two older rows, after the tail.
        model.ingest(.messageReceived(msg("oldest", .inbound, seq: 10)))
        model.ingest(.messageReceived(msg("middle", .inbound, seq: 20)))
        #expect(model.messages.map(\.body) == ["oldest", "middle", "newest", "my echo"])
        // The unsequenced echo stays pinned to the tail until it is acknowledged.
        #expect(model.messages.last?.clientMessageID == echo)
    }

    @Test("After a failed first load the replayed backlog is silent, but once connected live arrivals are announced")
    func failedLoadIsSilentUntilConnected() {
        let model = ChatTranscriptModel()
        model.initialLoadFailed()
        model.ingest(.messageReceived(msg("replayed", .inbound, seq: 1)))
        model.ingest(.messageReceived(msg("replayed too", .inbound, seq: 2)))
        #expect(model.pendingAnnouncement == nil)
        #expect(model.messages.count == 2)        // still shown, just not read aloud
        // The connected transition separates the past from live traffic. A VoiceOver user whose
        // page failed to load must not be left with a silent transcript for the whole session.
        model.ingest(.stateChanged(.connected))
        model.ingest(.messageReceived(msg("live", .inbound, seq: 3)))
        #expect(model.pendingAnnouncement != nil)
    }

    @Test("A replayed or reconciled backlog is not read aloud: only a message arriving as the newest is announced")
    func historyIsNotAnnounced() {
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)
        model.ingest(.messageReceived(msg("newest", .inbound, seq: 30)))
        #expect(model.pendingAnnouncement != nil)       // a live arrival is announced
        model.clearAnnouncement()
        model.ingest(.messageReceived(msg("older", .inbound, seq: 10)))
        model.ingest(.messageReceived(msg("middle", .inbound, seq: 20)))
        #expect(model.pendingAnnouncement == nil, "history must not be announced")
        // A row already on screen, re-delivered by the session's catch-up replay, is not announced.
        let known = UUID()
        model.ingest(.messageReceived(msg("known", .inbound, seq: 40, id: known)))
        model.clearAnnouncement()
        model.ingest(.messageReceived(msg("known", .inbound, seq: 40, id: known)))
        #expect(model.pendingAnnouncement == nil)
    }

    @Test("An agent reply is announced even when an unacknowledged echo sits at the tail")
    func announcedBehindPendingEcho() {
        let model = ChatTranscriptModel()
        model.setInitial([msg("earlier", .inbound, seq: 5)], hasMore: false)
        model.ingest(.messageReceived(msg("my message", .outbound, role: .customer, seq: nil, state: .sending)))
        model.clearAnnouncement()
        // The reply sorts before the unsequenced echo, so a tail-position test would miss it.
        model.ingest(.messageReceived(msg("agent reply", .inbound, seq: 6)))
        #expect(model.pendingAnnouncement == "agent reply")
        #expect(model.messages.map(\.body) == ["earlier", "agent reply", "my message"])
    }

    @Test("An acknowledged echo leaves the unsequenced tail, so a later reply does not jump above it")
    func ackedEchoLeavesTheTail() {
        let model = ChatTranscriptModel()
        let mine = UUID()
        model.setInitial([msg("earlier", .inbound, seq: 5)])
        model.ingest(.messageReceived(msg("my message", .outbound, role: .customer, seq: nil, state: .sending, id: mine)))
        // The server accepts it and assigns sequence 6.
        model.ingest(.deliveryStateChanged(DeliveryUpdate(clientMessageID: mine, state: .sent, serverMessageID: MessageID("s6"), sequence: 6)))
        #expect(model.messages.map(\.body) == ["earlier", "my message"])
        // A reply at 7 must land *after* it, not above it.
        model.ingest(.messageReceived(msg("agent reply", .inbound, seq: 7)))
        #expect(model.messages.map(\.body) == ["earlier", "my message", "agent reply"])
        #expect(model.messages[1].sequence == 6 && model.messages[1].serverMessageID == MessageID("s6"))
    }

    @Test("A page that arrives after a session swap is discarded, not prepended into the new transcript")
    func resetDiscardsInFlightPage() async throws {
        let model = ChatTranscriptModel()
        model.setInitial([msg("old session", .inbound, seq: 5)], hasMore: true)
        // The fetch suspends; the session is swapped while it is in flight.
        await model.loadEarlier {
            model.reset()
            return ([self.msg("from the old session", .inbound, seq: 1)], true)
        }
        #expect(model.messages.isEmpty, "a page for the previous session must not land in the new one")
        #expect(!model.pagingFailed)
    }

    @Test("Two messages arriving in one update are both announced: the queue is not a single slot")
    func burstAnnouncementsAreQueued() {
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)
        model.ingest(.messageReceived(msg("first", .inbound, seq: 1)))
        model.ingest(.messageReceived(msg("second", .inbound, seq: 2)))
        #expect(model.pendingAnnouncements.count == 2)
        model.clearAnnouncement()
        #expect(model.pendingAnnouncements.count == 1)
        model.clearAnnouncement()
        #expect(model.pendingAnnouncement == nil)
        model.clearAnnouncement()                 // draining an empty queue is harmless
        #expect(model.pendingAnnouncements.isEmpty)
    }

    @Test("Two identical messages queue two identical announcements, and both drain")
    func identicalAnnouncementsBothDrain() {
        let model = ChatTranscriptModel()
        model.setInitial([], hasMore: false)
        model.ingest(.messageReceived(msg("OK", .inbound, seq: 1)))
        model.ingest(.messageReceived(msg("OK", .inbound, seq: 2)))
        // Identical text, so a drain keyed on the *value* changing would stall on the head.
        #expect(model.pendingAnnouncements.count == 2)
        #expect(model.pendingAnnouncements[0] == model.pendingAnnouncements[1])
        model.clearAnnouncement()
        #expect(model.pendingAnnouncement != nil)
        model.clearAnnouncement()
        #expect(model.pendingAnnouncement == nil)
    }
}
