import Foundation
import Testing
import TouchpointCore

@testable import TouchpointChat

/// Choices come from the conversation, in every shape web reads, and answering one
/// sends what web sends. References are to the web SDK's `connect/conversation.ts` and `App.tsx`.
@Suite("Choices from the wire")
struct ChoicesTests {
    private func content(_ template: String, _ json: String) -> InteractiveContent {
        InteractiveContent(templateType: template, rawJSON: Data(json.utf8))
    }

    private func message(_ body: String, _ direction: Direction = .inbound, role: ParticipantRole = .assistant,
                         interactive: InteractiveContent? = nil, seq: Int) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body, direction: direction,
                              participantRole: direction == .outbound ? .customer : role, sequence: seq,
                              deliveryState: direction == .outbound ? .sent : .delivered,
                              interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) }))
    }

    private let offer = InteractiveContent(templateType: "QuickReply", rawJSON: Data("""
    {"templateType":"QuickReply","data":{"content":{"title":"Pick one","elements":[{"title":"Yes"},{"title":"No"}]}}}
    """.utf8))

    // MARK: Decoding

    @Test("QuickReply and ListPicker: element titles are both id and text; `replies` is read too; an untitled element is web's Option N (CV-7)")
    func connectTemplates() {
        #expect(offer.choices == [InteractiveChoice(id: "Yes", text: "Yes"), InteractiveChoice(id: "No", text: "No")])
        let replies = content("ListPicker", """
        {"data":{"content":{"title":"t","replies":[{"title":"A"},{"subtitle":"no title"},{"title":""}]}}}
        """)
        #expect(replies.choices == [InteractiveChoice(id: "A", text: "A"), InteractiveChoice(id: "choice-1", text: "Option 2"),
                                    InteractiveChoice(id: "choice-2", text: "Option 3")])
    }

    @Test("TouchpointModality message choices are read; an interim or other type offers none")
    func modality() {
        let modality = content("TouchpointModality", """
        {"data":{"content":{"modalityPayload":{"type":"message","message":"Which?",
          "choices":[{"choiceId":"c1","choiceText":"Card"},{"id":"c2","label":"Account"}]}}}}
        """)
        #expect(modality.choices == [InteractiveChoice(id: "c1", text: "Card"), InteractiveChoice(id: "c2", text: "Account")])
        #expect(content("TouchpointModality", """
        {"data":{"content":{"modalityPayload":{"type":"interim","choices":[{"choiceText":"x"}]}}}}
        """).choices.isEmpty)
    }

    @Test("application/json offers the last message's choices that has any, read leniently")
    func json() {
        let json = content(InteractiveContent.jsonTemplateType, """
        {"messages":[{"text":"a","choices":[{"choiceId":"x","choiceText":"Old"}]},
                     {"text":"b","choices":[{"text":"New"}]},{"text":"c"}]}
        """)
        #expect(json.choices == [InteractiveChoice(id: "choice-0", text: "New")])
    }

    @Test("Malformed payloads and other templates offer nothing and never throw")
    func leniency() {
        #expect(content("QuickReply", "not json").choices.isEmpty)
        #expect(content("TimePicker", #"{"data":{"content":{"title":"When?"}}}"#).choices.isEmpty)
    }

    // MARK: The outbound envelope

    @Test("The response is web's envelope: version 1.0, action and title set alike, content beside modalityPayload")
    func envelope() throws {
        let response = try InteractiveContent.choiceResponse(InteractiveChoice(id: "card", text: "  Replacement card  "))
        let obj = try #require(try JSONSerialization.jsonObject(with: response.rawJSON) as? [String: Any])
        #expect(obj["templateType"] as? String == "TouchpointModality")
        #expect(obj["version"] as? String == "1.0")
        #expect(obj["action"] as? String == "Replacement card")
        let data = try #require(obj["data"] as? [String: Any])
        #expect((data["content"] as? [String: Any])?["title"] as? String == "Replacement card")
        let payload = try #require(data["modalityPayload"] as? [String: Any])
        // The flow rejects any key in modalityPayload beyond request and context; web's is empty (CV-5).
        #expect(Set(payload.keys) == ["request", "context"])
        #expect((payload["context"] as? [String: Any])?.isEmpty == true)
        #expect(((payload["request"] as? [String: Any])?["structured"] as? [String: Any])?["choiceId"] as? String == "card")
    }

    @Test("The action is capped at Connect's 200 characters, and a blank choice says what happened")
    func actionLimits() throws {
        let long = try InteractiveContent.choiceResponse(InteractiveChoice(id: "x", text: String(repeating: "a", count: 300)))
        let obj = try #require(try JSONSerialization.jsonObject(with: long.rawJSON) as? [String: Any])
        #expect((obj["action"] as? String)?.count == 200)
        let blank = try InteractiveContent.choiceResponse(InteractiveChoice(id: "x", text: " "))
        let blankObj = try #require(try JSONSerialization.jsonObject(with: blank.rawJSON) as? [String: Any])
        #expect(blankObj["action"] as? String == "Selected an option")
    }

    // MARK: Normalising the wire

    @Test("application/json: the body is the messages' text, never the JSON; unparseable JSON shows as text")
    func jsonNormalised() {
        let (body, interactive) = ConnectChatTransport.content(contentType: "application/json", text: """
        {"messages":[{"text":"First"},{"text":"Second","choices":[{"text":"Go"}]}]}
        """)
        #expect(body == "First\n\nSecond")
        #expect(interactive?.choices.map(\.text) == ["Go"])
        #expect(ConnectChatTransport.content(contentType: "application/json", text: "{oops").body == "{oops")
    }

    @Test("Plain text that is really a modalities envelope is read as JSON, as web reads it; other text is untouched")
    func plainTextEnvelope() {
        let (body, interactive) = ConnectChatTransport.content(contentType: "text/plain", text: #"{"text":"Hi","modalities":{"x":1}}"#)
        #expect(body == "Hi")
        #expect(interactive?.carriesCard == true)
        #expect(ConnectChatTransport.content(contentType: "text/plain", text: "{not an envelope}").body == "{not an envelope}")
    }

    @Test("Our own interactive response read back from the transcript shows as the choice's text")
    func ownResponseReadBack() throws {
        let response = try InteractiveContent.choiceResponse(InteractiveChoice(id: "c", text: "Unknown charge"))
        let (body, _) = ConnectChatTransport.content(contentType: "application/vnd.amazonaws.connect.message.interactive.response",
                                                     text: String(decoding: response.rawJSON, as: UTF8.self))
        #expect(body == "Unknown charge")
    }

    @Test("A Connect template with only a subtitle shows the subtitle, as web falls back")
    func subtitleFallback() {
        #expect(ConnectChatTransport.interactiveSummary(Data(#"{"templateType":"QuickReply","data":{"content":{"subtitle":"Choose"}}}"#.utf8)).text == "Choose")
    }

    // MARK: When choices are offered

    @Test("The newest message's choices are offered until the customer answers, by choice or by typing")
    func offeredUntilAnswered() {
        let asked = message("Pick one", interactive: offer, seq: 1)
        #expect(TranscriptLayout.choices(for: [asked]).map(\.text) == ["Yes", "No"])
        #expect(TranscriptLayout.choices(for: [asked, message("Yes", .outbound, seq: 2)]).isEmpty)
        #expect(TranscriptLayout.choices(for: [asked, message("something else", .outbound, seq: 2)]).isEmpty)
    }

    @Test("An older message's choices are not re-offered once a newer reply without any arrives, SYSTEM included")
    func onlyTheNewest() {
        let asked = message("Pick one", interactive: offer, seq: 1)
        #expect(TranscriptLayout.choices(for: [asked, message("More", seq: 2)]).isEmpty)
        #expect(TranscriptLayout.choices(for: [asked, message("Flow text", role: .system, seq: 2)]).isEmpty)
    }

    /// The device defect: Connect sends the flow's and the assistant's messages as SYSTEM, so a menu from
    /// either must offer its choices (web: every non-agent message is the bot's).
    @Test("A SYSTEM message's choices are offered, and its modalities take input")
    func systemMenuOffersChoices() {
        let welcome = message("Welcome", role: .system, seq: 1)
        let menu = message("What would you like to try?", role: .system, interactive: offer, seq: 2)
        #expect(TranscriptLayout.choices(for: [welcome, menu]).map(\.text) == ["Yes", "No"])
        #expect(TranscriptLayout.answerableMessageID(in: [welcome, menu]) == menu.id)
        #expect(TranscriptLayout.welcome(for: [welcome, menu], isEnded: false)?.count == 2, "web's welcome screen: both are the bot's")
    }

    @Test("A greeting that offers choices keeps the welcome screen; one carrying a card does not")
    func welcomeWithChoices() {
        #expect(TranscriptLayout.welcome(for: [message("Hi", interactive: offer, seq: 1)], isEnded: false)?.count == 1)
        let card = content(InteractiveContent.jsonTemplateType, #"{"text":"Hi","modalities":{"card":{}}}"#)
        #expect(TranscriptLayout.welcome(for: [message("Hi", interactive: card, seq: 1)], isEnded: false) == nil)
    }

    @Test("Choices are withdrawn while connecting and once ended, and kept while reconnecting")
    @MainActor
    func gatedOnState() {
        let model = ChatTranscriptModel()
        model.setInitial([message("Pick one", interactive: offer, seq: 1)])
        model.ingest(.stateChanged(.connecting))
        #expect(model.choices.isEmpty)
        model.ingest(.stateChanged(.connected))
        #expect(model.choices.count == 2)
        model.ingest(.stateChanged(.reconnecting(attempt: 1)))
        #expect(model.choices.count == 2)
        model.ingest(.stateChanged(.ended(.agentEnded)))
        #expect(model.choices.isEmpty)
    }
}
