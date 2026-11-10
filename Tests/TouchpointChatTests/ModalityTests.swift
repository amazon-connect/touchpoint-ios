import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

/// The modalities the assistant sends, read from frames captured off the live showcase flow, and
/// the slot response a pick sends back.
@Suite("Modalities")
struct ModalityTests {
    private func inbound(_ frame: String) -> Message {
        let (body, interactive) = ConnectChatTransport.content(contentType: "application/vnd.amazonaws.connect.message.interactive", text: frame)
        return Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: body, direction: .inbound,
                                     participantRole: .assistant, sequence: 1, deliveryState: .delivered,
                                     interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) }))
    }

    @Test("A carousel arrives as one DefaultCarousel with three tappable cards saving to the Charge slot")
    func carousel() throws {
        let m = inbound(ShowcaseFrames.carousel)
        #expect(m.body == "Here are your recent charges. Which one would you like to review?")
        let mods = try #require(m.interactive?.modalities)
        #expect(mods.map(\.name) == ["DefaultCarousel"])
        let carousel = try JSONDecoder().decode(ModalityCarousel.self, from: mods[0].json)
        #expect(carousel.cards.compactMap(\.id) == ["streamly", "harbour", "riverside"])
        #expect(carousel.cards[1].rows.first == ModalityCard.Row(label: "Merchant", value: "Harbour Coffee"))
        #expect(carousel.saveAs == TouchpointModalitySaveTarget(type: .slot, id: "Charge"))
    }

    @Test("Modalities keep the flow's order: the card above the date input, the summary above the video")
    func order() throws {
        #expect(inbound(ShowcaseFrames.cardAndDate).interactive?.modalities.map(\.name) == ["DefaultCard", "DefaultDateInput"])
        #expect(inbound(ShowcaseFrames.summaryAndVideo).interactive?.modalities.map(\.name) == ["AcmeDisputeSummary", "DefaultVideo"])
    }

    @Test("Card, date input and video decode into what their views draw")
    func defaults() throws {
        let mods = try #require(inbound(ShowcaseFrames.cardAndDate).interactive?.modalities)
        let card = try JSONDecoder().decode(ModalityCard.self, from: mods[0].json)
        #expect(card.rows.map(\.value) == ["Harbour Coffee", "$6.75", "Oct 3"])
        let date = try JSONDecoder().decode(ModalitySaveOnly.self, from: mods[1].json)
        #expect(date.saveAs == TouchpointModalitySaveTarget(type: .slot, id: "Noticed"))
        let video = try JSONDecoder().decode(ModalityVideo.self,
                                             from: try #require(inbound(ShowcaseFrames.summaryAndVideo).interactive?.modalities.last).json)
        #expect(video.url.scheme == "https")
    }

    @Test("A host's custom modality reaches it as JSON it can decode")
    func custom() throws {
        struct Summary: Decodable { let merchant: String; let amount: String; let status: String }
        let mods = try #require(inbound(ShowcaseFrames.summaryAndVideo).interactive?.modalities)
        let summary = try JSONDecoder().decode(Summary.self, from: mods[0].json)
        #expect(summary.merchant == "Harbour Coffee" && summary.amount == "$6.75")
    }

    @Test("A View arrives as a guide card with web's heading and subheading, and is drawn")
    func view() {
        let m = inbound(ShowcaseFrames.view)
        #expect(m.interactive?.viewSummary?.heading == "Before we connect you")
        #expect(m.interactive?.viewSummary?.subheading == "Tell us a little about your request.")
        #expect(TranscriptLayout.isRenderable(m), "a View with no text must still draw its card, not vanish")
    }

    @Test("The slot response is web's: structured slots, an action describing them, under Connect's caps")
    func slotResponse() throws {
        let r = try InteractiveContent.slotResponse(id: "Charge", value: "harbour")
        let obj = try #require(try JSONSerialization.jsonObject(with: r.rawJSON) as? [String: Any])
        #expect(obj["templateType"] as? String == "TouchpointModality")
        #expect(obj["action"] as? String == "Charge: harbour")
        let slots = ((((obj["data"] as? [String: Any])?["modalityPayload"] as? [String: Any])?["request"] as? [String: Any])?["structured"] as? [String: Any])?["slots"] as? [[String: String]]
        #expect(slots == [["slotId": "Charge", "value": "harbour"]])
        #expect(r.isSlotResponse)
        #expect(try InteractiveContent.slotResponse(id: "x", value: String(repeating: "y", count: 500)).rawJSON.count < InteractiveContent.maxResponseBytes)
        #expect(throws: TouchpointError.self) { try InteractiveContent.slotResponse(id: "x", value: String(repeating: "y", count: 20_000)) }
    }

    @Test("Our own slot pick draws no bubble, live or read back from history")
    func slotPickHidden() throws {
        let r = try InteractiveContent.slotResponse(id: "Noticed", value: "2026-10-04")
        let (body, _) = ConnectChatTransport.content(contentType: "application/vnd.amazonaws.connect.message.interactive.response",
                                                     text: String(decoding: r.rawJSON, as: UTF8.self))
        #expect(body.isEmpty)
        let row = Message(StoredMessage(clientMessageID: UUID(), body: "", direction: .outbound, participantRole: .customer,
                                        deliveryState: .sending, interactiveJSON: try JSONEncoder().encode(r)))
        #expect(!TranscriptLayout.isRenderable(row))
    }

    @Test("Only the newest message from the other side takes a pick, until the customer answers")
    func answerable() throws {
        let first = inbound(ShowcaseFrames.carousel)
        let second = inbound(ShowcaseFrames.cardAndDate)
        #expect(TranscriptLayout.answerableMessageID(in: [first, second]) == second.id)
        let pick = Message(StoredMessage(clientMessageID: UUID(), body: "", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        #expect(TranscriptLayout.answerableMessageID(in: [first, second, pick]) == nil)
    }

    @Test("The date input sends web's YYYY-MM-DD")
    @MainActor
    func dateWire() {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 12))!
        #expect(ModalityDateInputView.wireValue(date, calendar: cal) == "2026-10-04")
    }

    @Test("A $saveAs routes as web's saveFn: slot to sendSlot, choiceId to sendChoice, context nowhere")
    @MainActor
    func saveRouting() {
        var slots: [String] = []; var choices: [String] = []
        let actions = ModalityActions(sendSlot: { slots.append("\($0)=\($1)") }, sendChoice: { choices.append($0) })
        actions.save(.init(type: .slot, id: "Charge"), "harbour")
        actions.save(.init(type: .choiceId, id: "x"), "agent")
        actions.save(.init(type: .context, id: "c"), "v")
        actions.save(nil, "ignored")
        #expect(slots == ["Charge=harbour"])
        #expect(choices == ["agent"])
    }
}
