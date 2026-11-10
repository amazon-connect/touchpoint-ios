import Foundation
import Testing
import TouchpointCore

@testable import TouchpointChat

/// What replaces web's input block at the foot of the transcript
/// (`App.tsx:936-947`) — nothing while connecting, "Start new conversation" once ended.
@Suite("The transcript's foot")
@MainActor
struct ConversationFootTests {
    @Test("Connecting hides the field; reconnecting keeps it, since queuing is what the outbox is for")
    func connectingHidesTheField() {
        let model = ChatTranscriptModel()
        model.ingest(.stateChanged(.connecting))
        #expect(model.foot == .none)
        model.ingest(.stateChanged(.connected))
        #expect(model.foot == .composer)
        model.ingest(.stateChanged(.reconnecting(attempt: 1)))
        #expect(model.foot == .composer)
    }

    @Test("Once the contact ends, however it ended, the field gives way to starting a new conversation")
    func endedOffersStartNew() {
        let model = ChatTranscriptModel()
        model.ingest(.stateChanged(.connected))
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.foot == .startNew)
        model.ingest(.stateChanged(.ended(.customerEnded)))
        #expect(model.foot == .startNew)
        // A new contact on the same session brings the field back.
        model.ingest(.stateChanged(.connecting))
        model.ingest(.stateChanged(.connected))
        #expect(model.foot == .composer)
    }

    @Test("The ended state says so as the transcript's last notice, and announces it once — live only")
    func endedStillAnnounced() {
        let replayed = ChatTranscriptModel()
        replayed.ingest(.stateChanged(.ended(.agentEnded)))   // before a first page: a replay, not news
        #expect(replayed.pendingAnnouncement == nil)
        let model = ChatTranscriptModel()
        model.setInitial([])
        model.ingest(.stateChanged(.connected))
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.items.last == TranscriptLayout.Item.notice(id: TranscriptLayout.endedNoticeID, text: TouchpointStrings.endedStatus))
        #expect(model.pendingAnnouncement == TouchpointStrings.endedStatus)
        model.clearAnnouncement()
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.pendingAnnouncement == nil, "a repeated ended state is not news")
    }
}
