import Foundation

// MARK: - Events

/// Message identifier as the server assigns it. Increment-1 chat uses the Connect message id.
public struct MessageID: Hashable, Sendable, Codable, RawRepresentable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { self.rawValue = raw }
}

/// Whether Live Sync is allowed to dispatch invocations into the host right now.
public enum DispatchState: Sendable, Equatable {
    case enabled
    case suspended
}

/// Why dispatch changed. Surfaced, never silent.
public enum DispatchChangeReason: Sendable, Equatable {
    /// A participant with the `agent` role joined the contact.
    case humanAgentJoined
    /// The last human agent left.
    case humanAgentLeft
    /// Before reconciliation: resumed from the store, or reconnecting after a dropped connection.
    /// Dispatch stays off until the server transcript confirms who is on the contact.
    case resumedUnreconciled
    /// Reconciliation after resume found no human agent on the contact; the safe default lifts.
    case transcriptReconciled
}

/// New messages from the other side of the live contact, for
/// ``TouchpointSession/onIncomingMessages``. What to do with them — a local notification, an in-app
/// banner, a badge, nothing — is the host's decision; the SDK posts no notifications.
public struct IncomingMessages: Sendable {
    public enum Origin: Sendable, Equatable {
        /// Arrived on the live connection. Always exactly one message.
        case live
        /// Missed while the connection was down — the app suspended or the network dropped — and
        /// recovered when the transcript was reconciled after a reconnect or resume. Normally one
        /// call per reconciliation, carrying every new inbound message it found.
        case catchUp
    }

    /// The contact the messages belong to.
    public let contactID: String
    /// Oldest first. Every inbound role (agent, supervisor, assistant, system): filter on
    /// ``Message/participantRole`` if only some should be announced.
    public let messages: [Message]
    public let origin: Origin

    public init(contactID: String, messages: [Message], origin: Origin) {
        self.contactID = contactID
        self.messages = messages
        self.origin = origin
    }
}

/// One normalised stream over dissimilar transports. Cases for voice and Live Sync are declared
/// now so the enum is complete at publication; Core emits the chat and lifecycle ones.
public enum ContactEvent: Sendable {
    case stateChanged(ContactState)
    case messageReceived(Message)
    /// One of *our* messages moved along `sending → sent → delivered → read` (or to `failed`).
    /// Keyed on the client id `send()` returned, which is what a UI already holds. One event covers
    /// every transition; the design's `messageDelivered(MessageID)` could not express `read`.
    ///
    /// The server's id and ordering ride along on the `sent` transition that assigns them, so a UI
    /// holding the optimistic echo can move it out of the unsequenced tail into transcript order
    /// without re-reading the store.
    case deliveryStateChanged(DeliveryUpdate)
    /// The transcript settled after a reconnect or resume. Carries no counts on purpose.
    case transcriptReconciled
    case participantsChanged(ParticipantSet)
    /// The other side is working on a reply: an agent typing, or the flow's own interim message
    /// ("One moment…"). Momentary — never replayed to a late subscriber — and never stored, so a
    /// reloaded conversation does not resurrect it.
    case remoteActivity(RemoteActivity)
    /// A line the transcript shows between messages: an agent joining or leaving, or the connection
    /// dropping. Live only — a resume reconciles who is on the contact silently, as web has no
    /// reload to replay one from. Replayed to a late subscriber, like the messages around it.
    case notice(TranscriptNotice)
    /// The sign-in card changed (the flow's "Authenticate Customer" block). Replayed to a late
    /// subscriber, and the current card is synthesised when the replay lost it.
    case authenticationChanged(AuthenticationCard)
    case liveSyncDispatchChanged(DispatchState, reason: DispatchChangeReason)
    case permissionRequired(Permission)
    case failed(TouchpointError)
    case contactEnded(reason: EndReason)
}

// MARK: - Transport seam

/// What a transport tells the coordinator. Deliberately small: the coordinator normalises these
/// into `ContactEvent` and owns every state decision.
public enum TransportEvent: Sendable, Equatable {
    case connected
    /// The transport's connection came back on its own — the vendor's socket re-established
    /// without a reconnect from the session. Treated as a reconnect: whatever arrived meanwhile may
    /// be missing, so the session reconciles before Live Sync may dispatch again (CV-9).
    case reestablished
    case disconnected(error: String?)
    /// An inbound message, or the server echo of one of ours (same `serverMessageID`; the store
    /// deduplicates). Inbound rows arrive as `.delivered`: the transport has already acknowledged
    /// them on the wire by the time the coordinator sees them.
    case messageReceived(StoredMessage)
    /// The server accepted our send: `sending → sent`, with the id and ordering it assigned.
    case messageDelivered(clientMessageID: UUID, serverMessageID: String, sequence: Int?)
    /// The other side acknowledged one of our messages.
    case receipt(serverMessageID: String, kind: ReceiptKind)
    case participantJoined(Participant)
    case participantLeft(id: String)
    /// Someone other than the customer is composing — see ``RemoteActivity``.
    case remoteActivity(RemoteActivity)
    /// The sign-in card `id` moved to `status`. A new id is a new card (a fresh `initiated`).
    case authenticationChanged(id: UUID, status: AuthenticationStatus)
    /// A security-relevant request the transport refused — a sign-in redirect whose scheme/host/path
    /// or `state` did not match. **Non-terminal**: the contact continues. The coordinator surfaces it
    /// to the host as ``ContactEvent/failed(_:)`` so a host security log can record it (I6, BSC40).
    /// Carries only a non-sensitive reason: never a URL with a query string, never a token.
    case securityRejection(TouchpointError)
    case contactEnded(EndReason)
}

/// One of web's transcript notices (`connect/conversation.ts:820-855, 944-952`), positioned by the
/// message it followed so a surface that loads history first still draws it in the right place.
public struct TranscriptNotice: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// A participant with the agent role joined. Web announces AGENT only — not a supervisor.
        case agentJoined
        case agentLeft
        /// The connection dropped mid-contact (web's `Failure` response). Reconnection is automatic;
        /// the notice says it happened.
        case connectionLost
    }
    public let id: UUID
    public let kind: Kind
    /// The newest message when it happened; `nil` when the conversation had none. Draw it after.
    public let after: UUID?

    public init(id: UUID = UUID(), kind: Kind, after: UUID?) {
        self.id = id
        self.kind = kind
        self.after = after
    }
}

/// What the other side of a contact is doing between messages (web: `setInterimMessage`,
/// `connect/conversation.ts:954-967, 1108-1109`).
public enum RemoteActivity: Sendable, Equatable {
    /// An agent (or anyone but the customer) is typing. Connect typing events expire, so a surface
    /// should let this lapse on its own after a few seconds; web clears it after 5.
    case typing
    /// A flow's interim message — words meant as a status line, not a transcript row.
    case interim(String)
}

/// One of our messages moved along the delivery states. A payload rather than bare associated
/// values so the server's ordering can ride along without every `case` pattern changing again.
public struct DeliveryUpdate: Sendable, Equatable {
    /// The id `send()` returned — what a UI already holds.
    public let clientMessageID: UUID
    public let state: DeliveryState
    /// The server's id for the message. First known on the `sent` transition, and carried on the
    /// later `delivered`/`read` transitions too (receipts arrive keyed on it); `nil` only for
    /// `sending` and for a `failed` that never reached the server.
    public let serverMessageID: MessageID?
    /// The server's ordering, on the transition that assigns it. Lets a UI move the optimistic echo
    /// out of the unsequenced tail into transcript order without re-reading the store.
    public let sequence: Int?

    public init(clientMessageID: UUID, state: DeliveryState, serverMessageID: MessageID? = nil, sequence: Int? = nil) {
        self.clientMessageID = clientMessageID
        self.state = state
        self.serverMessageID = serverMessageID
        self.sequence = sequence
    }
}

public enum ReceiptKind: Sendable, Equatable, Codable {
    case delivered
    case read

    public var deliveryState: DeliveryState {
        switch self { case .delivered: .delivered; case .read: .read }
    }
}

/// One page of the *local* transcript, oldest-first, with whether anything older remains.
public struct TranscriptSlice: Sendable, Equatable {
    public var messages: [StoredMessage]
    public var hasMore: Bool

    public init(messages: [StoredMessage], hasMore: Bool) {
        self.messages = messages
        self.hasMore = hasMore
    }
}

/// One page of server transcript, oldest first. Participant joins and leaves are returned as the
/// events they are so the coordinator can apply them to its **set** in server order.
/// One line of the server's transcript, as web's Download transcript writes it (`App.tsx:64-85`):
/// Connect's own time and display name, and the words a person reads.
public struct TranscriptEntry: Sendable, Equatable, CustomStringConvertible {
    /// Connect's `AbsoluteTime`, verbatim.
    public let absoluteTime: String
    /// Connect's `DisplayName`, or the participant role when it has none.
    public let name: String
    public let role: ParticipantRole
    public let text: String

    public init(absoluteTime: String, name: String, role: ParticipantRole, text: String) {
        self.absoluteTime = absoluteTime
        self.name = name
        self.role = role
        self.text = text
    }

    /// Conversation content stays out of logs.
    public var description: String { "TranscriptEntry(absoluteTime: \(absoluteTime), role: \(role), name: <redacted>, text: <redacted>)" }
}

public struct TranscriptPage: Sendable, Equatable {
    public var messages: [StoredMessage]
    public var participantEvents: [TransportEvent]
    /// Opaque token for the page *before* this one; `nil` when the transcript is exhausted.
    public var nextToken: String?

    public init(messages: [StoredMessage], participantEvents: [TransportEvent], nextToken: String?) {
        self.messages = messages
        self.participantEvents = participantEvents
        self.nextToken = nextToken
    }
}

/// A modality transport. Production implementations wrap the chat SDK's `ChatSession` and
/// Chime; the tests drive the coordinator through stubs.
///
/// **Ordering contract.** The coordinator subscribes to `events` *before* calling `connect`, and a
/// transport must either emit `.connected` only after that subscription is live or buffer events
/// until the first subscriber attaches. Dropping pre-subscription events leaves the session stuck in
/// `.connecting`; test adapters against a non-buffering consumer.
public protocol ContactTransport: Sendable {
    /// Connect using credentials the broker vended. Must emit `.connected` on success.
    func connect(credentials: any ExpiringCredentials) async throws
    func send(_ message: OutboundMessage) async throws
    func disconnect() async
    /// Drop the connection but **leave the server-side participant alive**, so the contact can be
    /// resumed — the right teardown for a connection that was *lost* rather than a contact that was
    /// *ended*. Default: `disconnect`, which is correct for a transport whose contact
    /// cannot be resumed on new credentials anyway (voice: a dead Chime meeting).
    func release() async
    var events: AsyncStream<TransportEvent> { get }

    /// The server transcript, newest page first; `before` is the previous page's `nextToken`.
    /// Default: an empty page — a transport with no server-side history (voice) need not implement it.
    func fetchTranscript(before: String?, limit: Int) async throws -> TranscriptPage
    /// Send a `read` receipt for an inbound message. `read` is host-driven; `delivered` is
    /// the transport's own job. Default: no-op.
    func markRead(upTo serverMessageID: String) async throws
    /// Tell the other side the customer is typing. Best effort: a failure is not the customer's
    /// problem. The session throttles calls; a transport need not. Default: no-op (voice).
    func sendTyping() async
    /// Upload a file to the other side — Amazon Connect accepts one only while a human agent is in
    /// the chat. Returns once Connect has it; the transcript row arrives as the server's echo.
    /// Default: unsupported (voice).
    func sendAttachment(fileURL: URL) async throws
    /// The server's own transcript as readable lines, newest `limit`, oldest first. Default: none.
    func fetchTranscriptEntries(limit: Int) async throws -> [TranscriptEntry]
    /// Sign-in (Connect's "Authenticate Customer"): the sheet's URL for the current prompt, the
    /// redirect it came back with, and the customer continuing without. Default: unsupported.
    func beginAuthentication() async throws -> AuthenticationRequest
    func completeAuthentication(callbackURL: URL) async throws
    func cancelAuthentication() async
    /// A short-lived link to download an attachment. Fetch a fresh one each time: it expires.
    /// Default: unsupported.
    func attachmentURL(id: String) async throws -> URL
    /// Resolve a Connect View reference (its `viewToken`) into its definition — web's `describeView`
    /// (`conversation.ts:1655-1684`). Default: unsupported (a transport that carries no Views).
    func describeView(viewToken: String) async throws -> ConnectViewDefinition
}

public extension ContactTransport {
    func fetchTranscriptEntries(limit: Int) async throws -> [TranscriptEntry] { [] }
    func beginAuthentication() async throws -> AuthenticationRequest {
        throw TouchpointError.invalidConfiguration("this contact does not offer sign-in")
    }
    func completeAuthentication(callbackURL: URL) async throws {
        throw TouchpointError.invalidConfiguration("this contact does not offer sign-in")
    }
    func cancelAuthentication() async {}
    func sendAttachment(fileURL: URL) async throws {
        throw TouchpointError.invalidConfiguration("this contact does not carry attachments")
    }
    func attachmentURL(id: String) async throws -> URL {
        throw TouchpointError.invalidConfiguration("this contact does not carry attachments")
    }
    func describeView(viewToken: String) async throws -> ConnectViewDefinition {
        throw TouchpointError.invalidConfiguration("this contact does not offer Connect Views")
    }
    func fetchTranscript(before: String?, limit: Int) async throws -> TranscriptPage {
        TranscriptPage(messages: [], participantEvents: [], nextToken: nil)
    }
    func markRead(upTo serverMessageID: String) async throws {}
    func sendTyping() async {}
    func release() async { await disconnect() }
}

// MARK: - Cross-module control seam

/// Core declares it; `TouchpointLiveSync` conforms and registers. With nothing
/// registered the coordinator's calls are no-ops — correct for a chat-only consumer.
public protocol LiveSyncControl: AnyObject, Sendable {
    func suspendDispatch(reason: DispatchChangeReason) async
    func resumeDispatch() async
    /// Full teardown, not a resumable disconnect.
    func teardown() async
}

// MARK: - Reconnection policy: bounded, deliberately

public struct ReconnectionPolicy: Sendable, Equatable {
    public var maxAttempts: Int
    public var totalBudget: Duration
    public var initialDelay: Duration
    public var maxDelay: Duration
    /// Jitter is one-sided (0…+factor) so the delay can never collapse to zero — the absorbed
    /// implementation's symmetric jitter could.
    public var jitterFactor: Double

    public init(maxAttempts: Int = 6, totalBudget: Duration = .seconds(60), initialDelay: Duration = .milliseconds(500), maxDelay: Duration = .seconds(15), jitterFactor: Double = 0.25) {
        self.maxAttempts = maxAttempts
        self.totalBudget = totalBudget
        self.initialDelay = initialDelay
        self.maxDelay = maxDelay
        self.jitterFactor = jitterFactor
    }

    public static let `default` = ReconnectionPolicy()
    public static let disabled = ReconnectionPolicy(maxAttempts: 0, totalBudget: .zero)

    /// Delay before `attempt` (1-based). Exponential with a cap and positive-only jitter.
    public func delay(forAttempt attempt: Int, random: Double = Double.random(in: 0...1)) -> Duration {
        let base = initialDelay * Double(1 << max(0, min(attempt - 1, 20)))
        let capped = base > maxDelay ? maxDelay : base
        return capped * (1 + jitterFactor * random)
    }
}
