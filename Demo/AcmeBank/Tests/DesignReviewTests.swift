import Foundation
import Testing
@testable import AcmeBank

/// The switches and script a design review's screen recording relies on.
@Suite("Design review support", .serialized)
struct DesignReviewTests {
    @Test("slow motion triples the scripted agent's pace, and is off by default")
    func slowMotionPace() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: SupportCoordinator.slowMotionKey)
        defer { defaults.set(saved, forKey: SupportCoordinator.slowMotionKey) }
        defaults.removeObject(forKey: SupportCoordinator.slowMotionKey)
        #expect(SupportCoordinator.scriptedPace() == 1)
        defaults.set(true, forKey: SupportCoordinator.slowMotionKey)
        #expect(SupportCoordinator.scriptedPace() == 3)
    }

    @Test("one welcome suggestion is long enough to wrap onto a second line on a phone")
    func longSuggestion() {
        #expect(ScriptedChatTransport.topics.contains { $0.count >= 60 })
        // It still reaches the dispute reply, which keys on "recogni".
        #expect(ScriptedChatTransport.scriptedReply(to: ScriptedChatTransport.longTopic).text.contains("dispute"))
    }

    @Test("the customer's goodbye is how a person's chat ends; anything else they answer")
    func agentWrapUp() {
        #expect(ScriptedChatTransport.isWrapUp("Goodbye"))
        #expect(ScriptedChatTransport.isWrapUp("That's all"))
        #expect(!ScriptedChatTransport.isWrapUp("Is my card blocked?"))
        #expect(ScriptedChatTransport.agentReply(to: "Thank you").hasPrefix("You're welcome"))
    }

    @Test("rich replies are the ones the interim message precedes")
    func interimBeforeRichReplies() {
        #expect(ScriptedChatTransport.scriptedReply(to: "Show me cards").modalitiesJSON != nil)
        #expect(ScriptedChatTransport.scriptedReply(toSlot: "Charge").modalitiesJSON != nil)
        #expect(ScriptedChatTransport.scriptedReply(to: "Where is my replacement card?").modalitiesJSON == nil)
    }
}
