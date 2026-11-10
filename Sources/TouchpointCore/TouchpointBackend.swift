import Foundation

// MARK: - The integration contract

/// The one genuinely permanent decision in the SDK: how credentials reach it.
///
/// The host implements this against a backend it operates. Every method is `async throws` and
/// there is no overload accepting a literal API key for production use. `DevelopmentBackend`
/// exists only in debug builds.
public protocol TouchpointBackend: Sendable {
    /// Host backend calls `StartChatContact` and returns the participant token.
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials

    /// Host backend calls `StartWebRTCContact` and returns the Chime meeting configuration.
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials

    /// Host backend returns Live Sync deployment credentials, ideally short-lived.
    func liveSyncCredentials() async throws -> LiveSyncCredentials
}

// MARK: - Request DTOs

/// What the SDK tells the host backend when starting a chat. The backend adds the instance and
/// flow identifiers — the SDK never holds them.
public struct ChatContactRequest: Sendable, Equatable, Codable {
    /// Shown to the agent in the CCP.
    public var displayName: String
    /// Contact attributes forwarded to `StartChatContact`. Must not carry secrets.
    public var attributes: [String: String]

    public init(displayName: String, attributes: [String: String] = [:]) {
        self.displayName = displayName
        self.attributes = attributes
    }
}

/// What the SDK tells the host backend when starting an outbound voice contact.
public struct VoiceContactRequest: Sendable, Equatable, Codable {
    public var displayName: String
    public var attributes: [String: String]
    /// The customer may share this app's screen with the agent. The host backend passes it to
    /// `StartWebRTCContact` as `AllowedCapabilities.Customer.ScreenShare = "SEND"`. Encoded only
    /// when `true`, so a host that did not opt in sends exactly the body it always has.
    public var screenShare: Bool
    /// Idempotency key, mirroring ``OutboundMessage/clientMessageID`` for the outbox: a client that
    /// times out at its gateway and retries `/voice/start` must not start a second WebRTC contact.
    /// The host backend forwards it to `StartWebRTCContact` as `ClientToken`. Minted once per
    /// request so a retry of the *same* request carries the *same* token; always encoded (an absent
    /// token would let the backend treat every retry as unique, which is the bug). A UUID string
    /// satisfies a typical `[A-Za-z0-9_-]{8,128}` token rule. (DM-1)
    public var clientToken: String

    public init(displayName: String, attributes: [String: String] = [:], screenShare: Bool = false,
                clientToken: String = UUID().uuidString) {
        self.displayName = displayName
        self.attributes = attributes
        self.screenShare = screenShare
        self.clientToken = clientToken
    }

    private enum CodingKeys: String, CodingKey { case displayName, attributes, screenShare, clientToken }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try c.decode(String.self, forKey: .displayName)
        attributes = try c.decodeIfPresent([String: String].self, forKey: .attributes) ?? [:]
        screenShare = try c.decodeIfPresent(Bool.self, forKey: .screenShare) ?? false
        // A body from before clientToken existed decodes to a fresh unique key rather than failing.
        clientToken = try c.decodeIfPresent(String.self, forKey: .clientToken) ?? UUID().uuidString
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(displayName, forKey: .displayName)
        try c.encode(attributes, forKey: .attributes)
        if screenShare { try c.encode(true, forKey: .screenShare) }
        try c.encode(clientToken, forKey: .clientToken)
    }
}

/// A message the customer composed. `clientMessageID` is the idempotency key for the outbox.
public struct OutboundMessage: Sendable, Equatable, Codable {
    public var clientMessageID: UUID
    public var body: String
    /// Set when the message answers a choice: the interactive response to put on the wire instead
    /// of `body`, which stays the customer-readable text the transcript shows. See
    /// ``InteractiveContent/choiceResponse(_:)``. A transport that has no structured channel sends
    /// `body`.
    public var interactiveResponse: InteractiveContent?

    public init(clientMessageID: UUID = UUID(), body: String, interactiveResponse: InteractiveContent? = nil) {
        self.clientMessageID = clientMessageID
        self.body = body
        self.interactiveResponse = interactiveResponse
    }
}

// MARK: - Credentials

/// Anything the broker can decide to refresh.
public protocol ExpiringCredentials: Sendable {
    /// `nil` means the credential does not expire on a schedule the SDK knows about.
    var expiresAt: Date? { get }
}

/// Result of `StartChatContact` as the host backend relays it.
// Deliberately NOT Codable: a synthesized encoder would serialise the token in clear text.
public struct ChatContactCredentials: ExpiringCredentials, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contactID: String
    public let participantID: String
    /// `nil` when the host routes every Participant Service call through its own backend with a
    /// custom chat client (web's `customChatClient`), so the token never reaches the device.
    public let participantToken: String?
    public let expiresAt: Date?

    public init(contactID: String, participantID: String, participantToken: String?, expiresAt: Date?) {
        self.contactID = contactID
        self.participantID = participantID
        self.participantToken = participantToken
        self.expiresAt = expiresAt
    }

    // A credential must never reach a log through string interpolation.
    public var description: String { "ChatContactCredentials(contactID: \(contactID), participantToken: <redacted>)" }
    public var debugDescription: String { description }
}

/// Result of `StartWebRTCContact` as the host backend relays it. Meeting and attendee payloads
/// are carried opaquely so Core never imports Chime.
// Deliberately NOT Codable, for the same reason as `ChatContactCredentials`.
public struct VoiceContactCredentials: ExpiringCredentials, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
    public let contactID: String
    public let participantID: String
    public let participantToken: String
    public let meetingJSON: Data
    public let attendeeJSON: Data
    public let expiresAt: Date?

    public init(contactID: String, participantID: String, participantToken: String, meetingJSON: Data, attendeeJSON: Data, expiresAt: Date?) {
        self.contactID = contactID
        self.participantID = participantID
        self.participantToken = participantToken
        self.meetingJSON = meetingJSON
        self.attendeeJSON = attendeeJSON
        self.expiresAt = expiresAt
    }

    public var description: String { "VoiceContactCredentials(contactID: \(contactID), participantToken: <redacted>, meeting: <redacted>)" }
    public var debugDescription: String { description }

    /// Builds credentials from a JSON object a host backend returned, re-serialising the
    /// `meeting` and `attendee` objects (Connect's `ConnectionData.Meeting`/`.Attendee`, passed
    /// through verbatim) into the opaque blobs `TouchpointVoice` decodes. For hosts whose backend
    /// forwards the `StartWebRTCContact` response; one implementation for the SDK's own two demo
    /// clients, so neither drifts.
    ///
    /// - Throws: `TouchpointError.malformedPayload` naming the missing field; never its value.
    public init(fromBackendReply object: [String: Any], contactIDKey: String = "contactId", participantIDKey: String = "participantId",
                tokenKey: String = "participantToken", meetingKey: String = "meeting", attendeeKey: String = "attendee") throws {
        func string(_ k: String) throws -> String {
            guard let v = object[k] as? String, !v.isEmpty else { throw TouchpointError.malformedPayload("startVoiceContact reply: \(k)") }
            return v
        }
        func blob(_ k: String) throws -> Data {
            guard let v = object[k] as? [String: Any], JSONSerialization.isValidJSONObject(v) else {
                throw TouchpointError.malformedPayload("startVoiceContact reply: \(k)")
            }
            return try JSONSerialization.data(withJSONObject: v)
        }
        let expires = (object["expiresAt"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        self.init(contactID: try string(contactIDKey), participantID: try string(participantIDKey), participantToken: try string(tokenKey),
                  meetingJSON: try blob(meetingKey), attendeeJSON: try blob(attendeeKey), expiresAt: expires)
    }
}

/// Live Sync deployment credentials. The API key travels in the socket URL, so rotation takes
/// effect on the next connect.
public struct LiveSyncCredentials: ExpiringCredentials, Equatable, Codable, CustomStringConvertible, CustomDebugStringConvertible {
    public let deploymentKey: String
    public let apiKey: String
    public let expiresAt: Date?

    public init(deploymentKey: String, apiKey: String, expiresAt: Date?) {
        self.deploymentKey = deploymentKey
        self.apiKey = apiKey
        self.expiresAt = expiresAt
    }

    public var description: String { "LiveSyncCredentials(deploymentKey: \(deploymentKey), apiKey: <redacted>)" }
    public var debugDescription: String { description }
}

// MARK: - Redaction

extension ChatContactRequest: CustomStringConvertible, CustomDebugStringConvertible {
    // The display name is PII and attribute values may carry secrets; only the keys are loggable.
    public var description: String {
        "ChatContactRequest(displayName: <redacted>, attributeKeys: \(attributes.keys.sorted()))"
    }
    public var debugDescription: String { description }
}

extension VoiceContactRequest: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "VoiceContactRequest(displayName: <redacted>, attributeKeys: \(attributes.keys.sorted()), screenShare: \(screenShare))" }
    public var debugDescription: String { description }
}

extension OutboundMessage: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OutboundMessage(clientMessageID: \(clientMessageID), body: <redacted>, interactiveResponse: \(interactiveResponse == nil ? "nil" : "<redacted>"))"
    }
    public var debugDescription: String { description }
}
