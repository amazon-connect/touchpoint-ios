import Foundation
import Testing
@testable import TouchpointCore

@Suite("Message projection and roles")
struct MessageProjectionTests {
    @Test("Every schema-v1 field survives the store → Message projection, including the empty increment-2 fields")
    func projectionRoundTrip() throws {
        let client = UUID()
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let citations = try JSONEncoder().encode([Citation(title: "Fees schedule", url: URL(string: "https://example.invalid/fees"), snippet: "p. 2")])
        let interactive = try JSONEncoder().encode(InteractiveContent(templateType: "ListPicker", rawJSON: Data("{\"x\":1}".utf8)))
        let stored = StoredMessage(
            clientMessageID: client, serverMessageID: "srv-1", body: "hello", direction: .inbound, participantRole: .agent,
            participantID: "p-agent-1", sequence: 1_700_000_000_123, createdAt: created, deliveryState: .delivered,
            interactiveJSON: interactive, citationsJSON: citations, isStreaming: true
        )
        let m = Message(stored)
        #expect(m.id == client)                                 // Identifiable key: stable for the row's whole life
        #expect(m.serverMessageID == MessageID("srv-1"))
        #expect(m.clientMessageID == client)
        #expect(m.participantID == "p-agent-1")
        #expect(m.direction == .inbound)
        #expect(m.participantRole == .agent)
        #expect(m.body == "hello")
        #expect(m.sequence == 1_700_000_000_123)
        #expect(m.createdAt == created)
        #expect(m.deliveryState == .delivered)
        #expect(m.isStreaming == true)
        #expect(m.citations.count == 1 && m.citations.first?.title == "Fees schedule")
        #expect(m.interactive?.templateType == "ListPicker")

        // Empty increment-2 fields project to empty, not to a failure.
        let bare = Message(StoredMessage(clientMessageID: client, body: "x", direction: .outbound, participantRole: .customer, deliveryState: .sending))
        #expect(bare.id == client && bare.serverMessageID == nil && bare.participantID == nil)
        #expect(bare.interactive == nil && bare.citations.isEmpty && bare.isStreaming == false)
    }

    @Test("Malformed increment-2 blobs project leniently rather than dropping the message")
    func malformedBlobsAreLenient() {
        let m = Message(StoredMessage(clientMessageID: UUID(), body: "x", direction: .inbound, participantRole: .assistant, deliveryState: .delivered, interactiveJSON: Data([0xFF]), citationsJSON: Data([0x00])))
        #expect(m.interactive == nil)
        #expect(m.citations.isEmpty)
        #expect(m.body == "x")
    }

    @Test("Connect role strings map onto the SDK role; supervisors are human; unknown never becomes the bot")
    func roleMapping() {
        #expect(ParticipantRole(connectRole: "AGENT") == .agent)
        #expect(ParticipantRole(connectRole: "CUSTOMER") == .customer)
        #expect(ParticipantRole(connectRole: "SYSTEM") == .system)
        #expect(ParticipantRole(connectRole: "SUPERVISOR") == .supervisor)
        #expect(ParticipantRole(connectRole: "CUSTOM_BOT") == .assistant)
        #expect(ParticipantRole(connectRole: "agent") == .agent)            // case-insensitive
        // An unrecognised role must fail safe for the dispatch gate: it is treated as a person until proven otherwise.
        #expect(ParticipantRole(connectRole: "SOMETHING_NEW") == .unknown)
        #expect(ParticipantRole.agent.isHuman && ParticipantRole.supervisor.isHuman && ParticipantRole.unknown.isHuman)
        #expect(!ParticipantRole.assistant.isHuman && !ParticipantRole.system.isHuman && !ParticipantRole.customer.isHuman)
    }

    @Test("A supervisor alone, or an unknown role alone, counts as a human agent for the dispatch gate")
    func supervisorGatesDispatch() {
        var set = ParticipantSet()
        set.join(Participant(id: "s1", role: .supervisor, displayName: "Sup"))
        #expect(set.humanAgentPresent)
        var unknown = ParticipantSet()
        unknown.join(Participant(id: "u1", role: .unknown, displayName: "?"))
        #expect(unknown.humanAgentPresent)
    }
}
