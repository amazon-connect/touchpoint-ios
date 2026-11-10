import Foundation
import Testing
import TouchpointCore

@testable import TouchpointChat

/// Scoped to the defect: content the transport dropped, and the blank row that
/// dropping it produced.
///
/// Cards and choices arrive as a `TouchpointModality` — `data.content.modalityPayload`
/// (`connect/conversation.ts:1091-1109`) — which has no `title`. The transport read only the title,
/// so every modality message lost the assistant's words and arrived with an empty body, and nothing
/// filtered empty bodies out, so the transcript drew a blank row with a delivery tick and no text.
@Suite("Modality content and empty rows")
struct ModalityContentTests {
    private func summary(_ json: String) -> (template: String, text: String?) {
        ConnectChatTransport.interactiveSummary(Data(json.utf8))
    }

    @Test("A modality's message text becomes the body — the words that used to be thrown away")
    func modalityMessageIsTheBody() {
        let (template, text) = summary("""
        {"templateType":"TouchpointModality","data":{"content":{"modalityPayload":{
          "type":"message","message":"I can help with that. Which card?","choices":[]}}}}
        """)
        #expect(template == "TouchpointModality")
        #expect(text == "I can help with that. Which card?")
    }

    @Test("A Connect template's title still wins, and is preferred over any payload text")
    func titleStillWins() {
        // ListPicker and friends carry a title; that behaviour predates this fix and must survive.
        #expect(summary("""
        {"templateType":"ListPicker","data":{"content":{"title":"Choose an account"}}}
        """).text == "Choose an account")
        // Both present: the title is the template's own displayable string, so it wins.
        #expect(summary("""
        {"templateType":"ListPicker","data":{"content":{"title":"Choose an account",
          "modalityPayload":{"type":"message","message":"ignored"}}}}
        """).text == "Choose an account")
    }

    @Test("An interim payload is web's typing indicator, not a message, so it yields no body")
    func interimIsNotAMessage() {
        // `conversation.ts:1108-1109` routes `interim` to `setInterimMessage`, not the transcript.
        // Letting "One moment." land as a message would be worse than dropping it.
        #expect(summary("""
        {"templateType":"TouchpointModality","data":{"content":{"modalityPayload":{
          "type":"interim","message":"One moment."}}}}
        """).text == nil)
    }

    @Test("Malformed, empty and unknown payloads yield no body and never throw")
    func leniency() {
        #expect(summary("not json at all").template == "unknown")
        #expect(summary("not json at all").text == nil)
        #expect(summary("{}").template == "unknown")
        #expect(summary("""
        {"templateType":"TouchpointModality","data":{"content":{"modalityPayload":{
          "type":"message","message":""}}}}
        """).text == nil, "an empty string is not a body")
        #expect(summary("""
        {"templateType":"TouchpointModality","data":{"content":{}}}
        """).text == nil)
    }

    // MARK: The blank row

    private func msg(_ body: String, seq: Int) -> Message {
        Message(StoredMessage(
            clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body,
            direction: .inbound, participantRole: .assistant, sequence: seq, deliveryState: .delivered))
    }

    @Test("A message with nothing to draw is not given a row")
    func emptyMessagesAreSuppressed() {
        #expect(!TranscriptLayout.isRenderable(msg("", seq: 1)))
        #expect(!TranscriptLayout.isRenderable(msg("   \n ", seq: 2)), "whitespace is not content")
        #expect(TranscriptLayout.isRenderable(msg("Hello", seq: 3)))

        let rows = TranscriptLayout.rows(for: [
            msg("Before", seq: 1),
            msg("", seq: 2),          // the modality that used to draw a blank row
            msg("After", seq: 3),
        ])
        #expect(rows.map(\.message.body) == ["Before", "After"])
    }

    @Test("Suppressing a row does not shift the delivery tick onto the wrong message")
    func deliveryStateFollowsTheVisibleMessages() {
        // The tick belongs to the newest *outbound* message. Filtering happens before that index is
        // computed, so an empty row cannot leave it pointing at a message nobody can see.
        let outbound = Message(StoredMessage(
            clientMessageID: UUID(), serverMessageID: "s2", body: "mine",
            direction: .outbound, participantRole: .customer, sequence: 2, deliveryState: .sent))
        let rows = TranscriptLayout.rows(for: [msg("", seq: 1), outbound, msg("", seq: 3)])
        #expect(rows.count == 1)
        #expect(rows[0].showsDeliveryState, "the only visible outbound message carries the tick")
    }
}
