import Foundation
import Testing
@testable import TouchpointCore

// MARK: - DM-1: VoiceContactRequest idempotency key
//
// A client that times out at its gateway and retries /voice/start must not start a second WebRTC
// contact. The request carries a clientToken the host backend forwards as StartWebRTCContact's
// ClientToken, mirroring the outbox's clientMessageID.

@Suite("VoiceContactRequest client token")
struct VoiceContactRequestTests {
    /// A typical backend accepts `[A-Za-z0-9_-]{8,128}`; the default token must satisfy it.
    private static let tokenRule = try! NSRegularExpression(pattern: "^[A-Za-z0-9_-]{8,128}$")
    private func matchesBackendRule(_ s: String) -> Bool {
        Self.tokenRule.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    @Test("A default request mints a token that satisfies the backend's token rule")
    func defaultTokenIsValid() {
        let r = VoiceContactRequest(displayName: "Ana")
        #expect(matchesBackendRule(r.clientToken), "default clientToken \(r.clientToken) must match [A-Za-z0-9_-]{8,128}")
    }

    @Test("Two fresh requests get distinct tokens; a retry of the same request keeps its token")
    func distinctPerRequestStablePerValue() throws {
        let a = VoiceContactRequest(displayName: "Ana")
        let b = VoiceContactRequest(displayName: "Ana")
        #expect(a.clientToken != b.clientToken, "each request is a distinct contact attempt")
        // The "same request retried" is the same value: re-encoding it sends the same token.
        let again = try JSONDecoder().decode(VoiceContactRequest.self, from: JSONEncoder().encode(a))
        #expect(again.clientToken == a.clientToken)
    }

    @Test("clientToken is always on the wire, so the backend can key idempotency on it")
    func alwaysEncoded() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceContactRequest(displayName: "Ana"))) as? [String: Any]
        #expect(object?["clientToken"] as? String != nil)
        // An explicit token round-trips verbatim.
        let fixed = VoiceContactRequest(displayName: "Ana", clientToken: "retry-key-0001")
        let wire = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixed)) as? [String: Any]
        #expect(wire?["clientToken"] as? String == "retry-key-0001")
    }

    @Test("A body from before clientToken existed decodes to a fresh valid token, not a failure")
    func backwardCompatibleDecode() throws {
        let decoded = try JSONDecoder().decode(VoiceContactRequest.self, from: Data(#"{"displayName":"Ana","attributes":{}}"#.utf8))
        #expect(matchesBackendRule(decoded.clientToken))
        #expect(decoded.screenShare == false)
    }
}
