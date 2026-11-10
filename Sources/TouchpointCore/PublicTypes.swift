import Foundation

/// The conversation channel a contact uses. There is no umbrella enum of UI modes — each product
/// exposes its own entry point — but the coordinator still needs to name which
/// transport a contact runs on.
public enum Modality: String, Sendable, CaseIterable, Codable {
    case chat
    case voice
}

/// Why a contact ended. Terminal; a new contact after any of these is a new session.
public enum EndReason: Sendable, Equatable, Hashable, Codable {
    /// The customer ended it through the SDK (`end()`).
    case customerEnded
    /// The agent or the contact flow disconnected the participant.
    case agentEnded
    /// Bounded reconnection reached its attempt or time ceiling.
    case connectionLost
    /// A mid-session credential refresh failed and the modality cannot continue (voice).
    case credentialVendingFailed
    /// The SDK or host ended it for another reason (resume failure, teardown).
    case systemEnded
}

/// A permission the host must obtain before a feature can work. Denial is a product state, never
/// an error; the SDK never requests one without host opt-in.
public enum Permission: String, Sendable, CaseIterable, Codable {
    case microphone
}

/// Lifecycle of the single active contact in a `TouchpointSession`.
public enum ContactState: Sendable, Equatable, Hashable {
    case idle
    case connecting
    case connected
    case reconnecting(attempt: Int)
    /// Backgrounded. Reserved: no transport reports it today — a suspended app's chat connection
    /// simply stops, and the next connection reconciles what was missed.
    case suspended
    case ended(EndReason)
}

/// The error taxonomy. Thrown from calls the host made; delivered through
/// `ContactEvent.failed` for failures with no caller to throw to.
public enum TouchpointError: Error, Sendable, Equatable, Hashable {
    case invalidConfiguration(String)
    case credentialVendingFailed(underlying: String)
    /// Most often a stale contact ID.
    case contactNotFound
    case transportFailure(String)
    /// The response body is carried because it is frequently the only authoritative explanation.
    case httpFailure(statusCode: Int, responseBody: String?)
    case malformedPayload(String)
    case actionHandlerFailed(action: String, description: String)
    case permissionDenied(Permission)
    case consentNotGranted
    case persistenceFailure(String)
}

// MARK: - Redaction
// The default `String(describing:)` of an enum prints associated values verbatim, which for
// `httpFailure` would leak the response body. Redact it to a length, matching Android's `toString`.
extension TouchpointError: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let s): "invalidConfiguration(\(s))"
        case .credentialVendingFailed(let s): "credentialVendingFailed(\(s))"
        case .contactNotFound: "contactNotFound"
        case .transportFailure(let s): "transportFailure(\(s))"
        case .httpFailure(let status, let body): "httpFailure(statusCode: \(status), responseBody: \(body.map { "<\($0.count) chars>" } ?? "nil"))"
        case .malformedPayload(let s): "malformedPayload(\(s))"
        case .actionHandlerFailed(let action, let d): "actionHandlerFailed(action: \(action), description: \(d))"
        case .permissionDenied(let p): "permissionDenied(\(p))"
        case .consentNotGranted: "consentNotGranted"
        case .persistenceFailure(let s): "persistenceFailure(\(s))"
        }
    }
    public var debugDescription: String { description }
}
