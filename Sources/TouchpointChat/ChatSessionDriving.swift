import Foundation
import TouchpointCore

// The seam between `ConnectChatTransport` and the upstream `amazon-connect-chat-ios` SDK.
//
// The SDK is linked on iOS only (Package.swift), so the adapter's logic — normalisation, receipts,
// error mapping, buffering — lives behind this small protocol and is tested on macOS against a
// fake. The one real conformance, `ConnectChatSessionDriver`, is compiled only where the SDK can be
// imported.

/// What the transport needs from a chat session. Deliberately smaller than `ChatSessionProtocol`.
protocol ChatSessionDriving: Sendable {
    func setHandlers(_ handlers: ChatDriverHandlers) async
    func connect(contactID: String, participantID: String, participantToken: String?) async throws
    func disconnect() async throws
    /// Stop the SDK's connection but leave the participant on the contact, so it can be resumed
    ///. The vendor's `ChatSession.reset` closes only the websocket, whereas `disconnect`
    /// additionally calls `DisconnectParticipant` and ends the participant server-side.
    func release() async throws
    /// Must return the **server** id of the accepted message. Never implemented via the SDK's
    /// `resendFailedMessage`, which re-issues under a new id. `contentType` is a
    /// ``ConnectContentType`` value: plain text, or an interactive response answering a choice.
    func sendMessage(_ body: String, contentType: String) async throws -> SentMessageAck
    func sendReceipt(_ kind: ReceiptKind, messageID: String) async throws
    /// A customer typing event (`application/vnd.amazonaws.connect.event.typing`).
    func sendTyping() async throws
    /// Older items first within the page; `nextToken` is the token for the page before this one.
    func fetchTranscript(nextToken: String?, maxResults: Int) async throws -> RawTranscriptPage
    /// Uploads a file the driver may read after returning control to the SDK (start → upload →
    /// complete). Returns once Connect has it.
    func sendAttachment(file: URL) async throws
    /// A fresh signed download link for an attachment.
    func attachmentDownloadURL(id: String) async throws -> URL
    /// `DescribeView`: resolve a `viewToken` into its view definition.
    func describeView(viewToken: String) async throws -> ConnectViewDefinition
    /// Start hearing Connect's sign-in events, which the vendor SDK drops. Called once,
    /// before `connect`, only when the host configured sign-in.
    func enableAuthenticationEvents() async
    /// `GetAuthenticationUrl` for the prompt's session.
    func authenticationURL(sessionID: String, redirectURI: URL) async throws -> URL
    /// `CancelParticipantAuthentication`: the flow takes its opted-out branch.
    func cancelAuthentication(sessionID: String) async throws
}

/// Callbacks a driver raises. All `@Sendable`; the transport hops onto its own actor.
struct ChatDriverHandlers: Sendable {
    var onConnected: @Sendable () -> Void
    /// The vendor's socket came back on its own (`onConnectionReEstablished`), not from a connect
    /// the transport asked for.
    var onReestablished: @Sendable () -> Void = {}
    var onConnectionBroken: @Sendable () -> Void
    var onChatEnded: @Sendable () -> Void
    var onItem: @Sendable (RawTranscriptItem) -> Void
    var onReceipt: @Sendable (ReceiptKind, String) -> Void
    /// Someone is typing; the argument is their Connect wire role (`CUSTOMER`, `AGENT`, …).
    var onTyping: @Sendable (String) -> Void
    /// A sign-in event: its content type, its `Content` (the `SessionId` JSON for `initiated`), and
    /// its `AbsoluteTime` when it came from the catch-up read rather than live.
    var onAuthenticationEvent: @Sendable (_ contentType: String, _ content: String?, _ absoluteTime: String?) -> Void = { _, _, _ in }
}

struct SentMessageAck: Sendable, Equatable {
    var serverMessageID: String
    /// Server `AbsoluteTime`, ISO-8601 with fractional seconds. The ordering authority.
    var absoluteTime: String
}

/// One websocket frame or transcript row, before any SDK-specific type is involved.
struct RawTranscriptItem: Sendable, Equatable {
    enum Kind: Sendable { case message, event }
    var kind: Kind
    var id: String
    var absoluteTime: String
    var contentType: String
    /// Connect wire role: `CUSTOMER`, `AGENT`, `SYSTEM`, `SUPERVISOR`, `CUSTOM_BOT`.
    var participantRole: String
    /// Connect `ParticipantId`. The upstream typed model drops it; the iOS driver recovers it from
    /// the raw frame. `nil` when the frame did not carry one (system messages).
    var participantID: String?
    var displayName: String
    var text: String?
    /// `true` for the server echo of a message *this* participant sent.
    var isOutgoing: Bool
    /// Set for a Connect `ATTACHMENT` item; `text` is then its file name.
    var attachment: MessageAttachment? = nil
}

struct RawTranscriptPage: Sendable, Equatable {
    var items: [RawTranscriptItem]
    /// Empty string from the service means "no more"; the transport normalises to `nil`.
    var nextToken: String?
}

/// Connect content types the adapter understands. Anything else is carried as plain text so an
/// unknown type degrades to "a message we cannot render" rather than a dropped frame.
enum ConnectContentType {
    static let plainText = "text/plain"
    static let markdown = "text/markdown"
    static let json = "application/json"
    static let interactive = "application/vnd.amazonaws.connect.message.interactive"
    static let interactiveResponse = "application/vnd.amazonaws.connect.message.interactive.response"
    static let joined = "application/vnd.amazonaws.connect.event.participant.joined"
    static let left = "application/vnd.amazonaws.connect.event.participant.left"
    static let ended = "application/vnd.amazonaws.connect.event.chat.ended"
    static let delivered = "application/vnd.amazonaws.connect.event.message.delivered"
    static let read = "application/vnd.amazonaws.connect.event.message.read"
    static let typing = "application/vnd.amazonaws.connect.event.typing"
}
