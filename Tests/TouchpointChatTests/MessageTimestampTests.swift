import Foundation
import Testing
import TouchpointCore

@testable import TouchpointChat

/// Web's `userMessageTimestamp` / `agentMessageTimestamp` (`interface.ts:446-460`,
/// `Messages.tsx:638,664,719-728`, `utils/formatTimestamp.ts`) and `headerStyle`.
@Suite("Message timestamps and header style")
struct MessageTimestampTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Toronto")!
        return c
    }()
    private let locale = Locale(identifier: "en_US")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func message(_ direction: Direction, role: ParticipantRole = .assistant, at: Date) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), body: "hi", direction: direction,
                              participantRole: direction == .outbound ? .customer : role,
                              createdAt: at, deliveryState: direction == .outbound ? .sent : .delivered))
    }

    @Test("Defaults are web's: no timestamps, no header style")
    func defaults() {
        let d = TouchpointChatOptions.default
        #expect(!d.userMessageTimestamp && !d.agentMessageTimestamp && d.headerStyle == nil)
    }

    @Test("Today shows the time only; earlier this year adds month and day; another year adds the year")
    func format() {
        let now = date(2026, 10, 22, 15, 0)
        let f = { (d: Date) in ChatOptions.timestamp(d, now: now, calendar: calendar, locale: locale) }
        let today = f(date(2026, 10, 22, 9, 5))
        #expect(today.contains("9:05") && !today.contains("Oct"))
        let earlier = f(date(2026, 3, 4, 9, 5))
        #expect(earlier.hasPrefix("Mar 4, ") && earlier.contains("9:05") && !earlier.contains("2026"))
        let lastYear = f(date(2025, 12, 31, 9, 5))
        #expect(lastYear.contains("Dec 31") && lastYear.contains("2025") && lastYear.contains("9:05"))
    }

    @Test("Each side is gated by its own option; off draws nothing")
    func gating() {
        let t = date(2026, 10, 22, 9, 0)
        let you = message(.outbound, at: t)
        let bot = message(.inbound, at: t)
        #expect(ChatOptions.timestamped([you, bot], options: .default).isEmpty)
        let userOnly = ChatOptions.timestamped([you, bot], options: TouchpointChatOptions(userMessageTimestamp: true))
        #expect(userOnly == [you.clientMessageID])
        let agentOnly = ChatOptions.timestamped([you, bot], options: TouchpointChatOptions(agentMessageTimestamp: true))
        #expect(agentOnly == [bot.clientMessageID])
    }

    @Test("Within a run, an agent stamp equal to the next one's is dropped; a different sender or minute keeps it")
    func agentRunDedupe() {
        let t = date(2026, 10, 22, 9, 0)
        let a1 = message(.inbound, role: .assistant, at: t)
        let a2 = message(.inbound, role: .assistant, at: t.addingTimeInterval(20))   // same minute
        let a3 = message(.inbound, role: .assistant, at: t.addingTimeInterval(120))  // later minute
        let agent = message(.inbound, role: .agent, at: t.addingTimeInterval(125))   // human: new sender
        let options = TouchpointChatOptions(agentMessageTimestamp: true)
        let shown = ChatOptions.timestamped([a1, a2, a3, agent], options: options) { d in
            ChatOptions.timestamp(d, now: t, calendar: calendar, locale: locale)
        }
        #expect(!shown.contains(a1.clientMessageID))   // same text as a2, same sender
        #expect(shown.contains(a2.clientMessageID))    // next differs
        #expect(shown.contains(a3.clientMessageID))    // next is another sender
        #expect(shown.contains(agent.clientMessageID)) // last
    }

    @Test("The customer's stamps are never deduplicated")
    func userStampsAll() {
        let t = date(2026, 10, 22, 9, 0)
        let y1 = message(.outbound, at: t)
        let y2 = message(.outbound, at: t.addingTimeInterval(5))
        let shown = ChatOptions.timestamped([y1, y2], options: TouchpointChatOptions(userMessageTimestamp: true))
        #expect(shown == [y1.clientMessageID, y2.clientMessageID])
    }
}
