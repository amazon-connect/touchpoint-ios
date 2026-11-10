import Foundation
import Testing
@testable import TouchpointCore

@Suite("Redaction")
struct RedactionTests {
    @Test("No description or debugDescription prints a message body, a name, or an HTTP response body")
    func noContentLeaksIntoDescriptions() throws {
        let secret = "SECRET-BODY-\(UUID().uuidString)"
        let name = "Jane-PII-\(UUID().uuidString)"

        let stored = StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: secret,
                                   direction: .outbound, participantRole: .customer, sequence: 7, deliveryState: .sending)
        let message = Message(stored)
        let participant = Participant(id: "id-\(UUID().uuidString)", role: .agent, displayName: name)
        var set = ParticipantSet(); set.join(participant)
        let outbound = OutboundMessage(body: secret)
        let chatReq = ChatContactRequest(displayName: name, attributes: ["topic": secret])
        let voiceReq = VoiceContactRequest(displayName: name, attributes: ["topic": secret])
        let attachment = MessageAttachment(id: "a1", name: "\(name).pdf", contentType: "application/pdf")
        let interactive = InteractiveContent(templateType: "ListPicker", rawJSON: Data(secret.utf8))
        let entry = TranscriptEntry(absoluteTime: "2026-10-08T14:00:00Z", name: name, role: .agent, text: secret)
        let httpError = TouchpointError.httpFailure(statusCode: 500, responseBody: secret)

        let values: [Any] = [stored, message, participant, set, outbound, chatReq, voiceReq, attachment, interactive, entry, httpError]
        for v in values {
            let described = String(describing: v)
            let reflected = String(reflecting: v)
            #expect(!described.contains(secret), "\(type(of: v)) description leaked a body/HTTP body")
            #expect(!reflected.contains(secret), "\(type(of: v)) debugDescription leaked a body/HTTP body")
            #expect(!described.contains(name), "\(type(of: v)) description leaked PII")
            #expect(!reflected.contains(name), "\(type(of: v)) debugDescription leaked PII")
        }
        // The attribute *keys* remain, since they are not content and are useful in a log.
        #expect(String(describing: chatReq).contains("topic"))
    }
}
