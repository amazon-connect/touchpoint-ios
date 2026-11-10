import Foundation
import Testing
@testable import TouchpointCore

@Suite("ParticipantSet")
struct ParticipantSetTests {
    @Test("Out-of-order leave-then-join still reports the agent present")
    func outOfOrder() {
        // Encodes the web SDK's live defect as a regression guard: a last-wins fold of
        // [leave(agent1), join(agent1)] would report "no agent" if events were replayed reversed.
        var set = ParticipantSet()
        set.join(Participant(id: "agent-1", role: .agent, displayName: "Sam"))
        set.leave("agent-1")
        set.join(Participant(id: "agent-1", role: .agent, displayName: "Sam"))
        #expect(set.humanAgentPresent)

        var reversed = ParticipantSet()
        reversed.leave("agent-1")              // stale leave arrives first
        reversed.join(Participant(id: "agent-1", role: .agent, displayName: "Sam"))
        #expect(reversed.humanAgentPresent)
    }

    @Test("Two agents: one leaving keeps the other present")
    func twoAgents() {
        var set = ParticipantSet()
        set.join(Participant(id: "a1", role: .agent, displayName: "A"))
        set.join(Participant(id: "a2", role: .agent, displayName: "B"))
        set.leave("a1")
        #expect(set.humanAgentPresent)
        set.leave("a2")
        #expect(!set.humanAgentPresent)
    }

    @Test("Bot and system participants never count as a human agent")
    func botsDoNotCount() {
        var set = ParticipantSet()
        set.join(Participant(id: "bot", role: .assistant, displayName: "Assistant"))
        set.join(Participant(id: "sys", role: .system, displayName: "System"))
        set.join(Participant(id: "me", role: .customer, displayName: "Me"))
        #expect(!set.humanAgentPresent)
    }

    @Test("Join is idempotent and keyed on id, not display name")
    func idempotentJoin() {
        var set = ParticipantSet()
        set.join(Participant(id: "a1", role: .agent, displayName: "Sam"))
        set.join(Participant(id: "a1", role: .agent, displayName: "Samuel"))
        #expect(set.count == 1)
        #expect(set.participants.first?.displayName == "Samuel")
    }

    @Test("Codable round-trip preserves the set")
    func codable() throws {
        var set = ParticipantSet()
        set.join(Participant(id: "a1", role: .agent, displayName: "Sam"))
        let data = try JSONEncoder().encode(set)
        let back = try JSONDecoder().decode(ParticipantSet.self, from: data)
        #expect(back == set)
    }
}
