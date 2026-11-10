import Foundation

/// Who is on the contact. Mirrors Connect's participant roles plus `assistant` for an Agentic CX Designer application.
public enum ParticipantRole: String, Sendable, Codable, CaseIterable, Hashable {
    case customer
    case agent
    /// A supervisor who barged in or is monitoring. Human, so it gates Live Sync dispatch.
    case supervisor
    case assistant
    case system
    /// A role this SDK version does not recognise. **Counts as human** (`isHuman`), so Live Sync
    /// dispatch suspends while such a party is on the contact: the cost of a wrong guess is a
    /// paused assistant, not the failure of dispatching into a session a person is handling.
    case unknown

    /// A person on the agent side — or a party we cannot rule out. The dispatch gate keys
    /// off this, not off `== .agent`.
    public var isHuman: Bool { self == .agent || self == .supervisor || self == .unknown }

    /// Maps Connect's `ParticipantRole` wire strings. Unrecognised values become `.unknown`.
    public init(connectRole: String) {
        switch connectRole.uppercased() {
        case "AGENT": self = .agent
        case "CUSTOMER": self = .customer
        case "SUPERVISOR": self = .supervisor
        case "CUSTOM_BOT": self = .assistant
        case "SYSTEM": self = .system
        default: self = .unknown
        }
    }
}

/// One participant on a contact, keyed on Connect's `ParticipantId`.
public struct Participant: Sendable, Codable, Hashable, Identifiable {
    public let id: String
    public var role: ParticipantRole
    public var displayName: String

    public init(id: String, role: ParticipantRole, displayName: String) {
        self.id = id
        self.role = role
        self.displayName = displayName
    }
}

/// The participant set. **A set keyed on id, never an event-history fold.**
///
/// A leave arriving after a join for the same id — which happens on transfer — must not report
/// "no agent" while one is handling the contact. That is a live defect in the web SDK and the
/// reason this type exists; `humanAgentPresent` is derived from membership, not from the last event.
public struct ParticipantSet: Sendable, Codable, Equatable {
    private var byID: [String: Participant] = [:]

    public init() {}

    public mutating func join(_ participant: Participant) {
        byID[participant.id] = participant
    }

    public mutating func leave(_ id: String) {
        byID[id] = nil
    }

    public var participants: [Participant] { byID.values.sorted { $0.id < $1.id } }
    public var count: Int { byID.count }
    public func contains(_ id: String) -> Bool { byID[id] != nil }

    /// `true` while any human agent-side participant is present. Drives dispatch gating.
    public var humanAgentPresent: Bool { byID.values.contains { $0.role.isHuman } }
}

/// Direction of a message relative to the customer.
public enum Direction: String, Sendable, Codable, Hashable {
    case outbound
    case inbound
}

/// Five states, not four: `failed` is reachable only from `sending`.
public enum DeliveryState: String, Sendable, Codable, CaseIterable, Hashable {
    case sending
    case sent
    case delivered
    case read
    case failed

    /// Localised, non-empty for every case: VoiceOver reads this instead of a tick glyph, which is
    /// what makes delivery state perceivable rather than purely visual (WCAG 1.1.1).
    public var accessibilityDescription: String {
        switch self {
        case .sending: TouchpointStrings.statusSending
        case .sent: TouchpointStrings.statusSent
        case .delivered: TouchpointStrings.statusDelivered
        case .read: TouchpointStrings.statusRead
        case .failed: TouchpointStrings.statusFailed
        }
    }

    public func canTransition(to next: DeliveryState) -> Bool {
        switch (self, next) {
        case (.sending, .sent), (.sending, .failed),
             (.sent, .delivered), (.sent, .read),
             (.delivered, .read):
            true
        default:
            false
        }
    }
}

/// The storage-facing message value: what transports hand the coordinator and what the store
/// persists. Hosts see `Message`, the projection; this type is public only because the transport
/// seam is.
public struct StoredMessage: Sendable, Equatable, Identifiable {
    public var id: UUID { clientMessageID }
    public let clientMessageID: UUID
    public var serverMessageID: String?
    public var body: String
    public var direction: Direction
    public var participantRole: ParticipantRole
    /// Connect `ParticipantId` of the sender, when known.
    public var participantID: String?
    /// Server ordering authority; `nil` until reconciled. Local echoes pin to the tail.
    public var sequence: Int?
    /// Display formatting only, never ordering.
    public var createdAt: Date
    public var deliveryState: DeliveryState
    // Locked in schema v1, rendered in increment 2.
    public var interactiveJSON: Data?
    public var citationsJSON: Data?
    public var isStreaming: Bool

    public init(
        clientMessageID: UUID,
        serverMessageID: String? = nil,
        body: String,
        direction: Direction,
        participantRole: ParticipantRole,
        participantID: String? = nil,
        sequence: Int? = nil,
        createdAt: Date = Date(),
        deliveryState: DeliveryState,
        interactiveJSON: Data? = nil,
        citationsJSON: Data? = nil,
        isStreaming: Bool = false
    ) {
        self.clientMessageID = clientMessageID
        self.serverMessageID = serverMessageID
        self.body = body
        self.direction = direction
        self.participantRole = participantRole
        self.participantID = participantID
        self.sequence = sequence
        self.createdAt = createdAt
        self.deliveryState = deliveryState
        self.interactiveJSON = interactiveJSON
        self.citationsJSON = citationsJSON
        self.isStreaming = isStreaming
    }
}

/// Read-side view of a persisted conversation.
public struct ConversationRecord: Sendable, Equatable {
    public let contactID: String
    public let modality: Modality
    public let lastSequence: Int
    public let participants: ParticipantSet
    public let humanAgentPresent: Bool
    public let lastActivity: Date
}

// MARK: - Redaction
// The default reflection-based `String(describing:)` / `String(reflecting:)` would print every
// stored field, including message bodies, display names and participant ids. These conformances
// keep conversation content and PII out of any log, matching the Android SDK's `toString` list.

extension Participant: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "Participant(role: \(role), id: <redacted>, displayName: <redacted>)" }
    public var debugDescription: String { description }
}

extension ParticipantSet: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "ParticipantSet(count: \(count), humanAgentPresent: \(humanAgentPresent))" }
    public var debugDescription: String { description }
}

extension StoredMessage: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "StoredMessage(clientMessageID: \(clientMessageID), serverMessageID: \(serverMessageID ?? "nil"), "
            + "direction: \(direction), participantRole: \(participantRole), sequence: \(sequence.map(String.init) ?? "nil"), "
            + "deliveryState: \(deliveryState), body: <redacted>)"
    }
    public var debugDescription: String { description }
}
