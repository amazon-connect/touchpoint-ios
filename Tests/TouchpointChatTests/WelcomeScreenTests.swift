import Foundation
import Testing
import TouchpointCore

@testable import TouchpointChat

/// The welcome screen — web's `App.tsx:630-664` for when it is active, and
/// `:852-900` for what it draws.
///
/// The condition is the whole of the risk here: get it wrong and either a greeting flashes away
/// mid-turn, or a live conversation stays stuck centred. The layout itself is just a `VStack`.
@Suite("Welcome screen")
@MainActor
struct WelcomeScreenTests {
    private func msg(_ body: String, _ direction: Direction, role: ParticipantRole = .assistant,
                     seq: Int, interactive: InteractiveContent? = nil) -> Message {
        Message(StoredMessage(
            clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body,
            direction: direction, participantRole: role, sequence: seq, deliveryState: .delivered,
            interactiveJSON: interactive.flatMap { try? JSONEncoder().encode($0) }))
    }

    private func welcome(_ messages: [Message], isEnded: Bool = false) -> [Message]? {
        TranscriptLayout.welcome(for: messages, isEnded: isEnded)
    }

    @Test("Before anyone has spoken, the welcome screen is on and empty — the connecting case")
    func emptyIsWelcome() {
        // Web returns an empty array rather than nil here, so the screen shows a centred status
        // instead of an empty transcript.
        #expect(welcome([])?.isEmpty == true)
    }

    @Test("The opening assistant turn is the welcome screen, and a second message does not end it")
    func openingTurn() {
        #expect(welcome([msg("Hi, how can I help?", .inbound, seq: 1)])?.map(\.body) == ["Hi, how can I help?"])
        // Web keeps the screen across the whole opening turn so the greeting does not flash away.
        #expect(welcome([msg("Hi there.", .inbound, seq: 1), msg("What can I do?", .inbound, seq: 2)])?.count == 2)
    }

    @Test("The customer's first word ends it, and it never comes back")
    func customerEndsIt() {
        #expect(welcome([
            msg("Hi, how can I help?", .inbound, seq: 1),
            msg("my card", .outbound, role: .customer, seq: 2),
            msg("Sure — which one?", .inbound, seq: 3),
        ]) == nil)
    }

    @Test("Anything that is not a plain assistant message falls back to the transcript")
    func fallsBackForNonPlainContent() {
        // A human agent's message, a system notice and a card all belong in a normal transcript —
        // web gives up on the welcome screen for each.
        // A Connect SYSTEM message is the bot's, as on web; only a person's ends the welcome screen.
        #expect(welcome([msg("Welcome", .inbound, role: .system, seq: 1)])?.count == 1)
        #expect(welcome([msg("Hello, Sam here", .inbound, role: .agent, seq: 1)]) == nil)
        // A card is a payload carrying modalities. A payload that only offers replies
        // keeps the welcome screen, as web's does (`ChoicesTests.welcomeWithChoices`).
        let card = InteractiveContent(templateType: "TouchpointModality", rawJSON: Data(#"""
        {"data":{"content":{"modalityPayload":{"type":"message","message":"x","modalities":{"card":{}}}}}}
        """#.utf8))
        #expect(welcome([msg("", .inbound, seq: 1, interactive: card)]) == nil)
    }

    @Test("An ended conversation is not a welcome screen, however it ended")
    func endedIsNotWelcome() {
        let opening = [msg("Hi, how can I help?", .inbound, seq: 1)]
        #expect(welcome(opening) != nil)
        #expect(welcome(opening, isEnded: true) == nil)
    }

    @Test("Its metrics are web's: 24pt between parts, 16pt between messages, a 48pt logo")
    func metrics() {
        let m = TranscriptMetrics(scale: 1, theme: .default)
        #expect(m.welcomeSpacing == 24)         // App.tsx:871 — gap-6
        #expect(m.welcomeMessageSpacing == 16)  // space-y-4
        #expect(m.welcomeLogoSize == 48)        // w-12 h-12
        // The greeting is text-lg, not the body size.
        #expect(m.greetingFont == .system(size: 18))
        #expect(m.greetingFont != m.bodyFont)
    }
}
