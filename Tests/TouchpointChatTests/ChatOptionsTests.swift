import SwiftUI
import Testing
import TouchpointCore

@testable import TouchpointChat

/// B4 customization options (OP-1…OP-6). The decisions are pure and tested here; the rendering they
/// drive is checked on the simulator by the integrator. References are to the web SDK's
/// `interface.ts` and the Android SDK's `TouchpointChatOptions.kt`.
@Suite("Customization options (B4)")
struct ChatOptionsTests {
    private func message(_ body: String = "hi", _ direction: Direction = .inbound,
                         role: ParticipantRole = .assistant, participantID: String? = nil, seq: Int = 1) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body, direction: direction,
                              participantRole: direction == .outbound ? .customer : role,
                              participantID: participantID, sequence: seq,
                              deliveryState: direction == .outbound ? .sent : .delivered))
    }

    // MARK: Defaults equal today (web's defaults)

    @Test("The defaults are web's — today's rendering: user bubble on, agent bubble off, no participant info, welcome on")
    func defaultsAreWeb() {
        let d = TouchpointChatOptions.default
        #expect(d.userMessageBubble)
        #expect(!d.agentMessageBubble)
        #expect(!d.showParticipantInfo)
        #expect(d.welcomeScreen)
        #expect(d.welcomeScreenLogo)
        #expect(d.avatarShape == .round)
        #expect(d.assistantName == nil && d.assistantIcon == nil && d.brandIcon == nil)
        #expect(d.userMessageBubbleStyle == nil && d.agentMessageBubbleStyle == nil)
        #expect(d == TouchpointChatOptions())
        // The environment default is the same, so a host that sets nothing sees today's chat.
        #expect(EnvironmentValues().touchpointChatOptions == .default)
    }

    // MARK: OP-1 / OP-2 bubbles

    @Test("OP-1: the customer's side is gated by userMessageBubble, every inbound message by agentMessageBubble")
    func bubbleGating() {
        #expect(ChatOptions.isBubbled(outbound: true, options: .default))     // user bubble on by default
        #expect(!ChatOptions.isBubbled(outbound: false, options: .default))   // agent bubble off by default
        let both = TouchpointChatOptions(userMessageBubble: false, agentMessageBubble: true)
        #expect(!ChatOptions.isBubbled(outbound: true, options: both))
        #expect(ChatOptions.isBubbled(outbound: false, options: both))
    }

    @Test("OP-2: a bubble style applies only where that side's bubble is on, and only to that side")
    func bubbleStyleGatedOnBubble() {
        let userStyle = TouchpointBubbleStyle(fill: .red)
        let agentStyle = TouchpointBubbleStyle(fill: .blue)
        // User bubble on (default), agent off: only the user style is in force.
        let a = TouchpointChatOptions(userMessageBubbleStyle: userStyle, agentMessageBubbleStyle: agentStyle)
        #expect(a.bubbleStyle(outbound: true) == userStyle)
        #expect(a.bubbleStyle(outbound: false) == nil)   // agent side has no bubble → style ignored
        // Turn the agent bubble on and the user off: the gate flips.
        let b = TouchpointChatOptions(userMessageBubble: false, agentMessageBubble: true,
                                      userMessageBubbleStyle: userStyle, agentMessageBubbleStyle: agentStyle)
        #expect(b.bubbleStyle(outbound: true) == nil)
        #expect(b.bubbleStyle(outbound: false) == agentStyle)
    }

    @Test("OP-2: a style override is scaled with text; an unset part keeps the SDK default")
    func bubbleDimensionsScale() {
        let m1 = TranscriptMetrics(scale: 1), m2 = TranscriptMetrics(scale: 2)
        // Override present: the host's unscaled point value times the Dynamic Type scale.
        #expect(m1.scaled(16, default: 999) == 16)
        #expect(m2.scaled(16, default: 999) == 32)
        // Override absent: the SDK's already-scaled default.
        #expect(m2.scaled(nil, default: m2.bubbleHorizontalPadding) == m2.bubbleHorizontalPadding)
    }

    // MARK: OP-3 participant info

    @Test("OP-3: avatar role is web's you / agent / bot — a supervisor and an unknown party are human")
    func avatarRole() {
        #expect(ChatOptions.role(for: message("hi", .outbound)) == .you)
        #expect(ChatOptions.role(for: message(role: .agent)) == .agent)
        #expect(ChatOptions.role(for: message(role: .supervisor)) == .agent)
        #expect(ChatOptions.role(for: message(role: .unknown)) == .agent)
        #expect(ChatOptions.role(for: message(role: .assistant)) == .bot)
        #expect(ChatOptions.role(for: message(role: .system)) == .bot)
    }

    @Test("OP-3: the display name is You, the assistant's name (or AI), or the agent's own name (or the role label)")
    func displayName() {
        func name(_ role: ChatOptions.AvatarRole, assistant: String? = nil, agent: String? = nil) -> String {
            ChatOptions.displayName(role: role, assistantName: assistant, agentName: agent,
                                    youLabel: "You", defaultAssistantLabel: "AI", defaultAgentLabel: "Support")
        }
        #expect(name(.you) == "You")
        #expect(name(.bot) == "AI")
        #expect(name(.bot, assistant: "Nova") == "Nova")
        #expect(name(.bot, assistant: "") == "AI")                 // an empty name falls back
        #expect(name(.agent) == "Support")
        #expect(name(.agent, agent: "Priya") == "Priya")           // the participant set's name wins
    }

    @Test("OP-3: a run starts on the first row, on a change of sender, and after any notice between messages")
    func runStarts() {
        let bot1 = message(role: .assistant, seq: 1)
        let bot2 = message(role: .assistant, seq: 2)
        let agentA = message(role: .agent, participantID: "a1", seq: 3)
        let agentB = message(role: .agent, participantID: "a2", seq: 4)
        let you = message("hi", .outbound, seq: 5)
        let rows = TranscriptLayout.rows(for: [bot1, bot2, agentA, agentB, you])
        // Two bot messages, then two different agents, then the customer. A notice splits the bot run.
        let items: [TranscriptLayout.Item] = [
            .message(rows[0]),
            .notice(id: UUID(), text: "Agent has joined"),
            .message(rows[1]), .message(rows[2]), .message(rows[3]), .message(rows[4]),
        ]
        let starts = TranscriptLayout.runStarts(in: items)
        #expect(starts.contains(bot1.clientMessageID))   // first row
        #expect(starts.contains(bot2.clientMessageID))   // a notice broke the run, even same sender
        #expect(starts.contains(agentA.clientMessageID)) // sender changed bot → agent a1
        #expect(starts.contains(agentB.clientMessageID)) // agent a1 → agent a2 is a new sender
        #expect(starts.contains(you.clientMessageID))    // agent → customer
        #expect(starts.count == 5)
    }

    @Test("OP-3: a continued run of the same sender draws no second avatar/name")
    func runContinues() {
        let bot1 = message(role: .assistant, seq: 1)
        let bot2 = message(role: .assistant, seq: 2)
        let rows = TranscriptLayout.rows(for: [bot1, bot2])
        let starts = TranscriptLayout.runStarts(in: [.message(rows[0]), .message(rows[1])])
        #expect(starts == [bot1.clientMessageID])
    }

    // MARK: OP-5 welcome

    @Test("OP-5: the welcome screen is used only when the model offered one and the switch is on")
    func welcomeGating() {
        let opening = [message(role: .assistant)]
        #expect(ChatOptions.usesWelcome(modelWelcome: opening, enabled: true))
        #expect(!ChatOptions.usesWelcome(modelWelcome: opening, enabled: false))  // host turned it off
        #expect(!ChatOptions.usesWelcome(modelWelcome: nil, enabled: true))       // not a welcome moment
    }

    @Test("OP-5: the welcome logo shows only with a brand icon, the switch on, and the welcome screen on")
    func welcomeLogo() {
        #expect(ChatOptions.showsWelcomeLogo(hasBrandIcon: true, options: .default))
        #expect(!ChatOptions.showsWelcomeLogo(hasBrandIcon: false, options: .default))
        #expect(!ChatOptions.showsWelcomeLogo(hasBrandIcon: true,
                                              options: TouchpointChatOptions(welcomeScreenLogo: false)))
        #expect(!ChatOptions.showsWelcomeLogo(hasBrandIcon: true,
                                              options: TouchpointChatOptions(welcomeScreen: false)))
    }

    // MARK: OP-6 font family (a theme token)

    @Test("OP-6: the theme's font family flows to the metrics; the default is the platform face")
    func fontFamily() {
        #expect(TouchpointTheme.default.fontFamily == nil)
        #expect(TranscriptMetrics(scale: 1).fontFamily == nil)
        let themed = TouchpointTheme(fontFamily: "Georgia")
        #expect(themed.fontFamily == "Georgia")
        #expect(TranscriptMetrics(scale: 1, theme: themed).fontFamily == "Georgia")
        // It is a real override: a themed theme is not the default one.
        #expect(themed != TouchpointTheme.default)
        // Setting the face does not disturb any colour or radius token.
        #expect(themed.primary == TouchpointTheme.default.primary)
        #expect(themed.innerCornerRadius == TouchpointTheme.default.innerCornerRadius)
    }
}
