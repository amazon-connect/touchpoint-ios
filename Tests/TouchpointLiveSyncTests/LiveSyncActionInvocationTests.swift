import Foundation
import Testing

@testable import TouchpointLiveSync

@Suite("Invocation decoding")
struct LiveSyncActionInvocationTests {
    private func decode(_ json: String) throws -> LiveSyncActionInvocation? {
        try LiveSyncActionInvocation.decode(from: Data(json.utf8))
    }

    @Test("Action frame with a payload")
    func actionWithPayload() throws {
        let invocation = try decode(
            """
            {"conversationId":"ea03d952-de13-4107-b461-3ace4465e563","classification":"custom",\
            "action":"set_contact_info","payload":{"fullName":"sterly","email":"sterly@example.com"}}
            """
        )

        #expect(
            invocation
                == LiveSyncActionInvocation(
                    action: "set_contact_info",
                    payload: ["fullName": "sterly", "email": "sterly@example.com"]
                )
        )
    }

    @Test("Action frame without a payload")
    func actionWithoutPayload() throws {
        let invocation = try decode(#"{"classification":"custom","action":"search_flights"}"#)
        #expect(
            invocation == LiveSyncActionInvocation(action: "search_flights", payload: .object([:]))
        )
    }

    @Test("An action frame without a name is rejected")
    func actionWithoutName() throws {
        #expect(throws: LiveSyncError.self) {
            _ = try decode(#"{"classification":"custom","payload":{}}"#)
        }
    }

    @Test("Frames that are not action invocations are ignored")
    func unrelatedFrames() throws {
        #expect(try decode(#"{"classification":"something-else"}"#) == nil)
        #expect(try decode(#"{"conversationId":"abc"}"#) == nil)
    }

    @Test("Malformed JSON surfaces as a Live Sync error")
    func malformedJSON() throws {
        #expect(throws: LiveSyncError.self) {
            _ = try decode("not json")
        }
    }
}
