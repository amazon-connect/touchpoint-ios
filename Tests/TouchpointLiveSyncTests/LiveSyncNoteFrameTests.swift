import Foundation
import Testing

@testable import TouchpointLiveSync

/// The engine delivers the assistant's own speech on the action socket, under the same `custom`
/// classification as an invocation and distinguished only by carrying `note` instead of `action`.
///
/// Every frame below is copied verbatim off the wire during a live voice call on
/// `touchpoint-voice-livesync`, in the order it arrived. Treating a note as a malformed invocation
/// produced one error per sentence the assistant spoke, which buried the real routing diagnostics.
@Suite("Note frames on the action socket")
struct LiveSyncNoteFrameTests {
    private func decode(_ json: String) throws -> LiveSyncInboundFrame {
        try LiveSyncInboundFrame.decode(from: Data(json.utf8))
    }

    @Test("An interim note is a note, not a malformed invocation")
    func interimNote() throws {
        let frame = try decode(
            """
            {"classification":"custom","conversationId":"b8f99792-9d28-4f6c-8aca-c1a6aceb63ad",\
            "note":"One moment.","metadata":{"streamed":true,"interim":true}}
            """
        )
        #expect(frame == .note("One moment."))
    }

    @Test("A final spoken line is a note too")
    func finalNote() throws {
        let frame = try decode(
            """
            {"classification":"custom","conversationId":"b8f99792-9d28-4f6c-8aca-c1a6aceb63ad",\
            "note":"I've opened your credit card and filtered for charges around two hundred and \
            forty dollars. Do you see the one you don't recognize?","metadata":{"streamed":true,"interim":false}}
            """
        )
        guard case .note(let text) = frame else { Issue.record("expected a note, got \(frame)"); return }
        #expect(text?.hasPrefix("I've opened your credit card") == true)
    }

    @Test("Notes do not stop the invocations interleaved with them being decoded")
    func invocationsStillDecode() throws {
        // The wire order from the live call: two invocations, then speech, then more invocations.
        let wire = [
            #"{"conversationId":"b8f99792","classification":"custom","action":"open_account","payload":{"accountType":"credit_card"}}"#,
            #"{"conversationId":"b8f99792","classification":"custom","action":"filter_transactions","payload":{"amount":240}}"#,
            #"{"classification":"custom","conversationId":"b8f99792","note":"One moment.","metadata":{"interim":true}}"#,
            #"{"conversationId":"b8f99792","classification":"custom","action":"select_transaction","payload":{}}"#,
            #"{"conversationId":"b8f99792","classification":"custom","action":"start_dispute","payload":{}}"#,
            #"{"conversationId":"b8f99792","classification":"custom","action":"set_dispute_details","payload":{"reason":"not_recognized"}}"#,
        ]

        var actions: [String] = []
        var notes = 0
        for line in wire {
            switch try decode(line) {
            case .custom(let invocation): actions.append(invocation.action)
            case .note: notes += 1
            default: Issue.record("unexpected frame for \(line)")
            }
        }

        #expect(notes == 1)
        #expect(actions == ["open_account", "filter_transactions", "select_transaction",
                            "start_dispute", "set_dispute_details"])
    }

    @Test("A custom frame with neither an action nor a note is still malformed")
    func stillMalformed() throws {
        #expect(throws: LiveSyncError.self) {
            _ = try decode(#"{"classification":"custom","conversationId":"b8f99792"}"#)
        }
    }

    @Test("The overlay separates a talking engine from a silent one")
    @MainActor
    func trafficLine() {
        // Notes climbing with unrouted invocations: the engine is acting, the app is not routing.
        #expect(TouchpointLiveSyncOverlay.trafficLine(notes: 7, unrouted: 5, lastAction: "open_account")
                == "7 notes · 5 UNROUTED · last: open_account")
        // Nothing inbound at all reads differently, and never claims an unrouted count of zero.
        #expect(TouchpointLiveSyncOverlay.trafficLine(notes: 0, unrouted: 0, lastAction: nil)
                == "0 notes · last: —")
    }
}
