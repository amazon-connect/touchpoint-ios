import Foundation
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// The built-in settings panel (web's `Settings.tsx`) and the window modes. What needs a running
/// app — the panel's layout, Mini floating over the host — needs a running app's UI tests.
@Suite("Chat settings and window modes")
@MainActor
struct ChatSettingsTests {
    private func msg(_ body: String, _ direction: Direction, role: ParticipantRole, seq: Int) -> Message {
        Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s\(seq)", body: body,
                              direction: direction, participantRole: role, sequence: seq, deliveryState: .delivered))
    }

    @Test("The gear appears for end or a complete mode switch, never for restart alone or a host's own settings")
    func gearGate() {
        #expect(!TouchpointChatActions().hasBuiltInSettings)
        // Restart already sits in the header; a host that wired only it sees no new control.
        #expect(!TouchpointChatActions(onRestart: {}).hasBuiltInSettings)
        #expect(TouchpointChatActions(onEndConversation: {}).hasBuiltInSettings)
        // Half a mode switch is no switch: the panel would open with no picker in it.
        #expect(!TouchpointChatActions(onWindowModeChange: { _ in }).hasBuiltInSettings)
        #expect(TouchpointChatActions(windowMode: .full, onWindowModeChange: { _ in }).hasBuiltInSettings)
        // Host rows alone earn the panel (D3).
        var rows = TouchpointChatActions()
        rows.settingsRows = [TouchpointSettingsRow(label: "Call us", isProminent: true) {}]
        #expect(rows.hasBuiltInSettings)
        // A host's own settings still wins.
        rows.onSettings = {}
        #expect(!rows.hasBuiltInSettings)
        // The host's own settings win over the built-in panel.
        #expect(!TouchpointChatActions(onSettings: {}, onEndConversation: {}).hasBuiltInSettings)
    }

    @Test("Mini is web's floating card from 768 wide — 420 wide, the height less 16, at most 1080 — and a compact card on a phone")
    func miniSize() {
        // Phone: web's floating covers the screen below 768; iOS keeps a compact card (a named
        // deviation) so the app stays usable around it.
        let phone = ChatWindowModifier<EmptyView>.miniSize(in: CGSize(width: 402, height: 874))
        #expect(phone.width == 386)
        #expect(phone.height == 874 * 0.45)
        // Tablet: web's `md:w-[420px] md:h-[calc(100%-1rem)] md:max-h-[1080px]`.
        let pad = ChatWindowModifier<EmptyView>.miniSize(in: CGSize(width: 1024, height: 1366))
        #expect(pad == CGSize(width: 420, height: 1080))
        let padLandscape = ChatWindowModifier<EmptyView>.miniSize(in: CGSize(width: 1366, height: 1004))
        #expect(padLandscape == CGSize(width: 420, height: 988))
        let atBreakpoint = ChatWindowModifier<EmptyView>.miniSize(in: CGSize(width: 768, height: 900))
        #expect(atBreakpoint == CGSize(width: 420, height: 884))
        let belowBreakpoint = ChatWindowModifier<EmptyView>.miniSize(in: CGSize(width: 767, height: 900))
        #expect(belowBreakpoint == CGSize(width: 420, height: 900 * 0.45))
        #expect(ChatWindowModifier<EmptyView>.miniSize(in: .zero) == .zero)
        #expect(ChatWindowModifier<EmptyView>.halfHeight(874) == 437)
    }

    @Test("The downloaded transcript is each message with its sender, in order")
    func transcriptExport() {
        let text = ChatSettingsPanel.transcript([
            msg("Hi", .outbound, role: .customer, seq: 1),
            msg("How can I help?", .inbound, role: .assistant, seq: 2),
        ])
        let paragraphs = text.components(separatedBy: "\n\n")
        #expect(paragraphs.count == 2)
        #expect(paragraphs[0].hasSuffix(": Hi"))
        #expect(paragraphs[1].hasSuffix(": How can I help?"))
    }

    @Test("Every window mode has a label for the picker")
    func modeLabels() {
        for mode in TouchpointChatWindowMode.allCases { #expect(!mode.label.isEmpty) }
    }
}

@Suite("Settings: host rows")
@MainActor
struct SettingsHostRowTests {
    @Test("A host row adds a row to the built-in panel")
    func hostRowRenders() throws {
        var actions = TouchpointChatActions(onEndConversation: {})
        actions.settingsRows = [TouchpointSettingsRow(label: "Call us", isProminent: true) {}]
        // Rendered, the panel is taller with the row than without.
        func height(_ a: TouchpointChatActions) -> Int {
            let r = ImageRenderer(content: ChatSettingsPanel(model: ChatTranscriptModel(), metrics: TranscriptMetrics(scale: 1, theme: .default),
                                                             actions: a, onDone: {}).frame(width: 390).fixedSize(horizontal: false, vertical: true))
            return r.cgImage?.height ?? 0
        }
        #expect(height(actions) > height(TouchpointChatActions(onEndConversation: {})) + 40)
    }
}

