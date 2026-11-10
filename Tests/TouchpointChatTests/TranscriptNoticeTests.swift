import Foundation
import Testing
@testable import TouchpointChat
@testable import TouchpointCore

/// Web's transcript notices (`conversation.ts:820-855, 944-952, 990-1003`; drawn by
/// `Messages.tsx:641-683`): where they sit, what they say, and that they are announced once.
@Suite("Transcript notices")
@MainActor
struct TranscriptNoticeTests {
    private func msg(_ body: String, _ direction: Direction = .inbound, role: ParticipantRole = .assistant, seq: Int) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body, direction: direction,
                              participantRole: role, sequence: seq, deliveryState: .delivered))
    }

    private func shape(_ items: [TranscriptLayout.Item]) -> [String] {
        items.map {
            switch $0 {
            case .message(let row): "m:\(row.message.body)"
            case .notice(_, let text): "n:\(text)"
            case .error(_, let text): "e:\(text)"
            case .authentication(let card): "a:\(card.status)"
            }
        }
    }

    @Test("A notice sits after the message it followed; one with no message leads; the connection problem, then ended, are last")
    func placement() {
        let a = msg("hello", seq: 1), b = msg("hi", .outbound, role: .customer, seq: 2), c = msg("Alex here", role: .agent, seq: 3)
        let messages = [a, b, c]
        let notices = [TranscriptNotice(kind: .agentJoined, after: b.clientMessageID),
                       TranscriptNotice(kind: .agentLeft, after: nil)]
        let items = TranscriptLayout.items(rows: TranscriptLayout.rows(for: messages), messages: messages, notices: notices,
                                           isEnded: true, connectionProblem: true)
        #expect(shape(items) == ["n:\(TouchpointStrings.agentLeftNotice)", "m:hello", "m:hi",
                                 "n:\(TouchpointStrings.agentJoinedNotice)", "m:Alex here",
                                 "e:\(TouchpointStrings.connectionLostNotice)", "n:\(TouchpointStrings.endedStatus)"])
    }

    @Test("Android parity: the connection problem clears on reconnect, on a send getting through, and on dismiss")
    func connectionProblemClears() {
        let model = ChatTranscriptModel()
        model.setInitial([msg("Hi", seq: 1)])
        let isShown = { model.items.contains { $0.id == TranscriptLayout.connectionProblemID } }
        model.ingest(.stateChanged(.connected))
        model.ingest(.notice(TranscriptNotice(kind: .connectionLost, after: nil)))
        model.ingest(.stateChanged(.reconnecting(attempt: 1)))
        #expect(isShown())
        #expect(model.notices.isEmpty, "a drop is not a transcript notice")
        #expect(model.pendingAnnouncements == [TouchpointStrings.connectionLostNotice])
        #expect(model.welcome == nil, "a problem ends the welcome screen, as any notice does")
        model.ingest(.stateChanged(.connected))
        #expect(!isShown(), "connected again: the drop is over")

        model.ingest(.notice(TranscriptNotice(kind: .connectionLost, after: nil)))
        let sent = Message(StoredMessage(clientMessageID: UUID(), body: "still there?", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        model.ingest(.messageReceived(sent))
        #expect(isShown())
        model.ingest(.deliveryStateChanged(DeliveryUpdate(clientMessageID: sent.clientMessageID, state: .sent, serverMessageID: MessageID("s9"), sequence: 9)))
        #expect(!isShown(), "a message getting through is the news that the problem has passed")

        model.ingest(.notice(TranscriptNotice(kind: .connectionLost, after: nil)))
        model.dismissConnectionProblem()
        #expect(!isShown())
        model.ingest(.notice(TranscriptNotice(kind: .connectionLost, after: nil)))
        model.ingest(.stateChanged(.ended(.connectionLost)))
        #expect(isShown(), "a drop that never recovered stays, as Android's does")
    }

    @Test("A notice after an undrawn message moves to the nearest drawn one before it; an unloaded anchor leads")
    func anchorsThatAreNotDrawn() {
        let a = msg("hello", seq: 1), blank = msg("   ", seq: 2), c = msg("next", seq: 3)
        let messages = [a, blank, c]
        let notices = [TranscriptNotice(kind: .agentLeft, after: blank.clientMessageID),
                       TranscriptNotice(kind: .agentJoined, after: UUID())]   // on a page not loaded
        let items = TranscriptLayout.items(rows: TranscriptLayout.rows(for: messages), messages: messages, notices: notices, isEnded: false)
        #expect(shape(items) == ["n:\(TouchpointStrings.agentJoinedNotice)", "m:hello",
                                 "n:\(TouchpointStrings.agentLeftNotice)", "m:next"])
    }

    @Test("A notice ends the welcome screen, as web's Notice and Failure responses do")
    func noticeEndsWelcome() {
        let greeting = [msg("Hi, how can I help?", seq: 1)]
        #expect(TranscriptLayout.welcome(for: greeting, isEnded: false) != nil)
        #expect(TranscriptLayout.welcome(for: greeting, isEnded: false, hasNotices: true) == nil)
    }

    @Test("The model keeps a replayed notice once, and announces it once")
    func modelDedupesAndAnnounces() {
        let model = ChatTranscriptModel()
        let drop = TranscriptNotice(kind: .connectionLost, after: nil)
        model.ingest(.notice(drop))                       // before a first page: cannot tell replay from live
        #expect(model.pendingAnnouncement == nil)
        model.setInitial([])
        let joined = TranscriptNotice(kind: .agentJoined, after: nil)
        model.ingest(.notice(joined))
        model.ingest(.notice(joined))                     // a re-subscription replays it
        #expect(model.notices == [joined])
        #expect(model.pendingAnnouncement == TouchpointStrings.agentJoinedNotice)
        model.clearAnnouncement()
        #expect(model.pendingAnnouncement == nil, "the replay is not announced again")
        model.reset()
        #expect(model.notices.isEmpty)
    }

    @Test("A new contact's first page drops the last contact's notices")
    func newContactClears() {
        let model = ChatTranscriptModel()
        model.setInitial([])
        model.ingest(.notice(TranscriptNotice(kind: .agentLeft, after: nil)))
        model.setInitial([msg("Hi again", seq: 1)])
        #expect(model.notices.isEmpty)
    }
}
