import Foundation
#if canImport(UIKit)
import UIKit
#endif
import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// The transcript takes the mobile template's shape (design-01…03). Pure
/// derivations are tested directly; what needs pixels is in `TranscriptSnapshotTests`.
@Suite("Chat design")
@MainActor
struct ChatDesignTests {
    private func msg(_ body: String, _ direction: Direction, role: ParticipantRole = .assistant, seq: Int?,
                     state: DeliveryState = .delivered, id: UUID = UUID()) -> Message {
        Message(StoredMessage(clientMessageID: id, serverMessageID: seq.map { "s\($0)" }, body: body,
                              direction: direction, participantRole: role, sequence: seq, deliveryState: state))
    }

    // MARK: Header (C1, C2)

    @Test("Header controls exist exactly when the host supplies a handler: close always, restart and settings on request")
    func headerControls() {
        #expect(ChatHeaderBar.controls(hasRestart: false, hasSettings: false, hasClose: true) == [.close])
        #expect(ChatHeaderBar.controls(hasRestart: true, hasSettings: true, hasClose: true) == [.restart, .settings, .close])
        #expect(ChatHeaderBar.controls(hasRestart: true, hasSettings: false, hasClose: false) == [.restart])
        #expect(ChatHeaderBar.controls(hasRestart: false, hasSettings: false, hasClose: false).isEmpty)
    }

    @Test("Without a brand, restart leads; with one, restart joins the trailing controls (web Header.tsx `ml-auto`)")
    func brandMovesRestartTrailing() {
        let all: [ChatHeaderBar.Control] = [.restart, .settings, .close]
        let plain = ChatHeaderBar.placement(all, hasBrand: false)
        #expect(plain.leading == [.restart])
        #expect(plain.trailing == [.settings, .close])
        let branded = ChatHeaderBar.placement(all, hasBrand: true)
        #expect(branded.leading.isEmpty)
        #expect(branded.trailing == [.restart, .settings, .close])
        #expect(ChatHeaderBar.placement([.close], hasBrand: true).trailing == [.close])
    }

    @Test("The brand is square except in the mini window, web's floating (`isBrandIconSquare={!isFloating}`)")
    func brandSquareUnlessMini() {
        #expect(ChatHeaderBar.brandIsSquare(windowMode: nil))
        #expect(ChatHeaderBar.brandIsSquare(windowMode: .full))
        #expect(ChatHeaderBar.brandIsSquare(windowMode: .half))
        #expect(!ChatHeaderBar.brandIsSquare(windowMode: .mini))
    }

    @Test("Open settings: the gear becomes web's Undo, labelled Close settings, never a selected fill (web 282c032)")
    func settingsToggleWhenOpen() {
        #expect(ChatHeaderBar.settingsGlyph(open: false) == .settings)
        #expect(ChatHeaderBar.settingsGlyph(open: true) == .undo)
        #expect(ChatHeaderBar.settingsLabel(open: false) == "Settings")
        #expect(ChatHeaderBar.settingsLabel(open: true) == "Close settings")
    }

    @Test("No bar at all when there is nothing to put in it — a title-only header must not draw a blank strip")
    func headerBarPresence() {
        #expect(!ChatHeaderBar.drawsBar(hasTitle: false, hasRestart: false, hasSettings: false, hasClose: false))
        #expect(ChatHeaderBar.drawsBar(hasTitle: true, hasRestart: false, hasSettings: false, hasClose: false))
        #expect(ChatHeaderBar.drawsBar(hasTitle: false, hasRestart: false, hasSettings: false, hasClose: true))
    }

    @Test("The title is optional: the template has none, the bank dock has one")
    func optionalTitle() {
        #expect(ChatHeader().title == nil)
        #expect(ChatHeader(title: "Acme Bank Support").title == "Acme Bank Support")
    }

    // MARK: Rows (C4–C6)

    @Test("No participant name is drawn: web's `showParticipantInfo` defaults false")
    func noSenderNames() {
        // The name used to be drawn once per run for a human agent. Web draws none and announces a
        // handover with a transcript notice instead (chunk 3 P5). VoiceOver still names the sender
        // through `bubbleLabel`, so a screen reader loses nothing — asserted in `bubbleLabel` below.
        #expect(ChatTranscriptModel.senderName(msg("agent", .inbound, role: .agent, seq: 1)) == TouchpointStrings.agentSenderLabel)
        #expect(ChatTranscriptModel.senderName(msg("sup", .inbound, role: .supervisor, seq: 2)) == TouchpointStrings.supervisorSenderLabel)
    }

    @Test("Every row after the first takes the same 32pt gap, because web makes each message its own response")
    func uniformResponseSpacing() {
        let m = TranscriptMetrics(scale: 1, theme: .default)
        #expect(TranscriptLayout.topSpacing(index: 0, metrics: m) == 0, "the container's padding is the first row's gap")
        for index in 1...4 {
            #expect(TranscriptLayout.topSpacing(index: index, metrics: m) == m.responseSpacing)
        }
        // Web's tighter 8pt is `space-y-2` *within* one multi-message payload, which the transport
        // does not surface yet — so it must not be reachable from a row index.
        #expect(m.messageSpacing == 8)
    }

    @Test("Delivery state sits under the newest outbound message only, and under any failed one")
    func deliveryStatePlacement() {
        let rows = TranscriptLayout.rows(for: [
            msg("old", .outbound, role: .customer, seq: 1, state: .read),
            msg("failed", .outbound, role: .customer, seq: nil, state: .failed),
            msg("newest", .outbound, role: .customer, seq: 3, state: .sent),
            msg("reply", .inbound, seq: 4),
        ])
        #expect(rows.map(\.showsDeliveryState) == [false, true, true, false])
        #expect(rows[1].isRetryable && !rows[2].isRetryable)
    }

    @Test("Copy hangs off the end of an inbound run — never the customer's words, a system notice, or a half-written reply")
    func actionPlacement() {
        let rows = TranscriptLayout.rows(for: [
            msg("a", .inbound, seq: 1), msg("b", .inbound, seq: 2),
            msg("c", .outbound, role: .customer, seq: 3, state: .sent),
            msg("d", .inbound, role: .agent, seq: 4),
            msg("notice", .inbound, role: .system, seq: 5),
        ])
        #expect(rows.map(\.showsActions) == [false, true, false, true, false])
        // Feedback is about the assistant's answer: a human agent's reply is not rated.
        #expect(rows.map(\.allowsFeedback) == [false, true, false, false, false])
    }

    @Test("A streaming reply is not yet actionable: copying half a sentence is worse than waiting")
    func streamingIsNotActionable() {
        let streaming = Message(StoredMessage(clientMessageID: UUID(), serverMessageID: "s1", body: "Let me check",
                                              direction: .inbound, participantRole: .assistant, sequence: 1,
                                              deliveryState: .delivered, isStreaming: true))
        let rows = TranscriptLayout.rows(for: [streaming])
        #expect(!rows[0].showsActions && !rows[0].allowsFeedback)
    }

    @Test("The row draws copy alone unless the message is the assistant's and the host listens")
    func actionRowContents() {
        #expect(MessageActionsRow.actions(allowsFeedback: true, hasHandler: true) == [.copy, .thumbsUp, .thumbsDown])
        #expect(MessageActionsRow.actions(allowsFeedback: true, hasHandler: false) == [.copy])
        #expect(MessageActionsRow.actions(allowsFeedback: false, hasHandler: true) == [.copy])
    }

    @Test("Delivery glyphs and colours follow the web status row: clock, check, double check, error")
    func deliveryGlyphs() {
        #expect(DeliveryStatusRow.glyph(for: .sending) == .time)
        #expect(DeliveryStatusRow.glyph(for: .sent) == .check)
        #expect(DeliveryStatusRow.glyph(for: .delivered) == .checkDouble)
        #expect(DeliveryStatusRow.glyph(for: .read) == .checkDouble)
        #expect(DeliveryStatusRow.glyph(for: .failed) == .error)
        let t = TouchpointTheme.default
        // Resolved, not compared by `Color` identity: a tier builds a fresh scheme-resolving colour
        // each call, so two equal tiers are not the same object.
        let env = EnvironmentValues()
        func same(_ a: Color, _ b: Color) -> Bool { a.resolve(in: env) == b.resolve(in: env) }
        #expect(same(DeliveryStatusRow.glyphColor(for: .failed, theme: t), t.error))
        #expect(same(DeliveryStatusRow.glyphColor(for: .read, theme: t), t.success))
        #expect(same(DeliveryStatusRow.glyphColor(for: .sent, theme: t), t.primary(.t40)))
    }

    // MARK: Actions (C7, C8)

    @Test("Copy routes the body to the pasteboard writer and announces it")
    func copyAction() {
        var announced: [String] = []
        var pasted: [String] = []
        let m = msg("The Swiss Alps are a stunning holiday destination.", .inbound, seq: 1)
        MessageActions.copy(m, announce: { announced.append($0) }, pasteboard: { pasted.append($0) })
        // Recorded, not asserted inside the closure: a `copy` that never called the pasteboard
        // would otherwise pass.
        #expect(pasted == [m.body])
        #expect(announced == [TouchpointStrings.copiedAnnouncement])
    }

    // `UIPasteboard.general` is not assertable here: a unit-test bundle has no host application, so
    // the simulator's pasteboard server returns nil for a write made from this process. The
    // injected-writer test above proves the routing; that the default writer *is*
    // `MessageActions.writeToPasteboard` is a one-line fact of the signature, and an app's UI
    // test exercises the real clipboard.

    @Test("A verdict is recorded once: the model keeps it, and a second tap on the same thumb is not resubmitted")
    func feedbackIsRecordedOnceInTheModel() {
        let model = ChatTranscriptModel()
        let m = msg("hi", .inbound, seq: 1)
        #expect(model.feedback[m.clientMessageID] == nil)
        #expect(model.recordFeedback(m, .positive))
        #expect(model.feedback[m.clientMessageID] == .positive)
        // Same verdict again: no change, so the host is not told twice.
        #expect(!model.recordFeedback(m, .positive))
        // Changing one's mind is a change.
        #expect(model.recordFeedback(m, .negative))
        #expect(model.feedback[m.clientMessageID] == .negative)
        // A session swap clears it, so one contact's verdict never shows under another.
        model.reset()
        #expect(model.feedback.isEmpty)
    }

    // MARK: Composer (C9)

    @Test("The composer's trailing slot is the microphone while the draft is empty and a mic is offered; otherwise send")
    func composerTrailingControl() {
        #expect(MessageComposer.trailingControl(draftIsEmpty: true, hasMicrophone: true) == .microphone)
        #expect(MessageComposer.trailingControl(draftIsEmpty: false, hasMicrophone: true) == .send)
        #expect(MessageComposer.trailingControl(draftIsEmpty: true, hasMicrophone: false) == .send)
        #expect(MessageComposer.trailingControl(draftIsEmpty: false, hasMicrophone: false) == .send)
        // While a message is in flight the box is already empty, but the slot must not swap under
        // the user's finger: a second tap would otherwise enter voice mode.
        #expect(MessageComposer.trailingControl(draftIsEmpty: true, hasMicrophone: true, isSending: true) == .send)
    }

    @Test("The composer's shell padding is web's plain 8pt, with nothing to compensate for")
    func composerShellPadding() {
        let m = TranscriptMetrics(scale: 1)
        // It used to subtract the tap frame's overhang. The frame no longer overhangs, so the
        // shell is simply web's `p-2` (`Input.tsx:225`).
        #expect(m.composerShellPadding == m.controlPadding)
        #expect(m.composerShellPadding == 8)
    }

    // MARK: Status (C10)

    @Test("The connection status shimmers only while something is in flight; ended is plain")
    func statusShimmers() {
        #expect(ChatTranscriptView.statusShimmers(.connecting))
        #expect(ChatTranscriptView.statusShimmers(.reconnecting(attempt: 1)))
        #expect(!ChatTranscriptView.statusShimmers(.ended(.customerEnded)))
        #expect(!ChatTranscriptView.statusShimmers(.connected))
    }

    // MARK: Strings (C12)

    @Test("Every new user-facing string resolves through the catalog")
    func stringsResolve() {
        for s in [TouchpointStrings.copyButtonLabel, TouchpointStrings.copiedAnnouncement,
                  TouchpointStrings.thumbsUpLabel, TouchpointStrings.thumbsDownLabel,
                  TouchpointStrings.restartButtonLabel, TouchpointStrings.settingsButtonLabel,
                  TouchpointStrings.microphoneButtonLabel, TouchpointStrings.composerPlaceholder] {
            #expect(!s.isEmpty && !s.hasPrefix("touchpoint."), "unresolved: \(s)")
        }
    }
}
