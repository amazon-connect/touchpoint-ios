import Foundation
import Testing
@testable import TouchpointCore

@Suite("Public types")
struct PublicTypesTests {
    @Test("Modality has exactly chat and voice")
    func modality() {
        #expect(Modality.allCases == [.chat, .voice])
    }

    @Test("EndReason is Equatable and covers the design's terminal reasons")
    func endReason() {
        let all: [EndReason] = [.customerEnded, .agentEnded, .connectionLost, .credentialVendingFailed, .systemEnded]
        #expect(Set(all).count == all.count)
    }

    @Test("Permission covers the microphone only: the SDK posts no notifications, so it never needs that permission")
    func permission() {
        #expect(Permission.allCases == [.microphone])
    }

    @Test("ContactState equality distinguishes reconnect attempts and end reasons")
    func contactState() {
        #expect(ContactState.reconnecting(attempt: 1) != .reconnecting(attempt: 2))
        #expect(ContactState.ended(.customerEnded) != .ended(.connectionLost))
        #expect(ContactState.idle == .idle)
    }

    @Test("TouchpointError cases are Equatable and carry their diagnostics")
    func touchpointError() {
        let a = TouchpointError.httpFailure(statusCode: 403, responseBody: "denied")
        let b = TouchpointError.httpFailure(statusCode: 403, responseBody: "denied")
        #expect(a == b)
        #expect(a != .httpFailure(statusCode: 403, responseBody: nil))
        #expect(TouchpointError.credentialVendingFailed(underlying: "x") != .contactNotFound)
    }

    @Test("Request DTOs are Sendable value types with stable fields")
    func dtos() {
        let chat = ChatContactRequest(displayName: "Alex", attributes: ["tier": "gold"])
        #expect(chat.displayName == "Alex")
        #expect(chat.attributes["tier"] == "gold")
        let voice = VoiceContactRequest(displayName: "Alex", attributes: [:])
        #expect(voice.displayName == "Alex")
        let out = OutboundMessage(clientMessageID: UUID(), body: "hi")
        #expect(out.body == "hi")
    }

    @Test("Credentials expose an expiry the broker can reason about")
    func credentialsExpiry() {
        let now = Date()
        let chat = ChatContactCredentials(contactID: "c", participantID: "p", participantToken: "t", expiresAt: now.addingTimeInterval(600))
        #expect(chat.expiresAt.map { $0 > now } == true)
        let ls = LiveSyncCredentials(deploymentKey: "d", apiKey: "k", expiresAt: nil)
        #expect(ls.expiresAt == nil)
    }
}

@Suite("VoiceContactCredentials from a backend reply")
struct VoiceCredentialsReplyTests {
    private let good: [String: Any] = [
        "contactId": "c", "participantId": "p", "participantToken": "t", "expiresAt": "2026-10-12T20:00:00Z",
        "meeting": ["MeetingId": "m", "MediaPlacement": ["AudioHostUrl": "h"]],
        "attendee": ["AttendeeId": "a", "JoinToken": "jt"],
    ]

    @Test("The two ConnectionData objects are carried as opaque JSON, byte-exact in meaning")
    func roundTrip() throws {
        let c = try VoiceContactCredentials(fromBackendReply: good)
        #expect(c.contactID == "c")
        #expect(c.expiresAt != nil)
        let m = try JSONSerialization.jsonObject(with: c.meetingJSON) as? [String: Any]
        #expect((m?["MediaPlacement"] as? [String: Any])?["AudioHostUrl"] as? String == "h")
        let a = try JSONSerialization.jsonObject(with: c.attendeeJSON) as? [String: Any]
        #expect(a?["JoinToken"] as? String == "jt")
    }

    @Test("A null or missing meeting (no ConnectionData) is a typed malformedPayload naming the key, never the token")
    func missing() {
        var bad = good; bad["meeting"] = NSNull()
        #expect(throws: TouchpointError.malformedPayload("startVoiceContact reply: meeting")) { _ = try VoiceContactCredentials(fromBackendReply: bad) }
        bad = good; bad.removeValue(forKey: "attendee")
        #expect(throws: TouchpointError.malformedPayload("startVoiceContact reply: attendee")) { _ = try VoiceContactCredentials(fromBackendReply: bad) }
        bad = good; bad["participantToken"] = ""
        #expect(throws: TouchpointError.malformedPayload("startVoiceContact reply: participantToken")) { _ = try VoiceContactCredentials(fromBackendReply: bad) }
    }
}
