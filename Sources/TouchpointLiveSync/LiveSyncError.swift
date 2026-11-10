import Foundation

/// Errors surfaced by ``LiveSyncClient``.
///
/// Underlying `Error` values are flattened into their descriptions so the whole enum is `Sendable`
/// and can cross isolation boundaries freely.
public enum LiveSyncError: Error, Sendable, Equatable {
    /// A required configuration value was missing or malformed.
    case invalidConfiguration(String)

    /// The context request completed with a non-2xx status.
    case httpFailure(statusCode: Int, responseBody: String?)

    /// The context request could not be sent.
    case requestFailed(description: String)

    /// The action socket failed or closed unexpectedly.
    case socketFailure(description: String)

    /// A frame arrived that could not be parsed as an action invocation.
    case malformedInvocation(description: String)

    /// An action handler threw — a payload the model could not decode, or a check of the handler's
    /// own — or a held confirmation was declined.
    case actionHandlerFailed(action: String, description: String)

    /// An invocation was rejected on the device before any handler ran: the action is not in the
    /// context the app advertised, or its payload does not match the schema the app declared, or
    /// that schema uses a keyword outside the supported subset (see the security guide).
    /// `description` names the keyword and a JSON Pointer into the payload — never a value.
    case invalidPayload(action: String, description: String)

    /// The broker could not vend Live Sync credentials. The underlying description is type + code only.
    case credentialVendingFailed(description: String)

    /// Context was not posted because consent has not been granted. Reported once per
    /// decision, not per attempt.
    case consentNotGranted

    /// The socket connected and context was posted, yet nothing has arrived for `quietFor`. The
    /// most likely cause is a `conversationId` that names no live conversation — the backend
    /// accepts the subscription and delivers nothing, for ever. Reported once per
    /// connection; a frame arriving afterwards means the diagnosis was wrong and the client says so
    /// with `connectionState` alone. The worst failure mode, made observable.
    case contactMayBeStale(quietFor: Duration)
}

extension LiveSyncError {
    /// Reduces an arbitrary error to something safe to surface. A `URLError`'s `localizedDescription`
    /// and `userInfo` can carry the failing URL, and the Live Sync socket URL carries the API key in its
    /// query — so only the error's type and code are kept, the same rule the credential broker
    /// applies.
    static func describe(_ error: any Error) -> String {
        let ns = error as NSError
        return "\(type(of: error))(\(ns.domain) \(ns.code))"
    }
}

// MARK: - Redaction
// `String(describing:)` of the enum would print the context response body verbatim; redact it to a
// length. `errorDescription` (LocalizedError) is the deliberate user-facing message and is separate.
extension LiveSyncError: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        switch self {
        case .invalidConfiguration(let s): "invalidConfiguration(\(s))"
        case .httpFailure(let status, let body): "httpFailure(statusCode: \(status), responseBody: \(body.map { "<\($0.count) chars>" } ?? "nil"))"
        case .requestFailed(let d): "requestFailed(\(d))"
        case .socketFailure(let d): "socketFailure(\(d))"
        case .malformedInvocation(let d): "malformedInvocation(\(d))"
        case .actionHandlerFailed(let action, let d): "actionHandlerFailed(action: \(action), description: \(d))"
        case .invalidPayload(let action, let d): "invalidPayload(action: \(action), description: \(d))"
        case .credentialVendingFailed(let d): "credentialVendingFailed(\(d))"
        case .consentNotGranted: "consentNotGranted"
        case .contactMayBeStale(let q): "contactMayBeStale(quietFor: \(q))"
        }
    }
    public var debugDescription: String { description }
}

extension LiveSyncError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Invalid Live Sync configuration: \(detail)"
        case .httpFailure(let statusCode, let body):
            let suffix = body.map { ": \($0)" } ?? ""
            return "Live Sync context request failed with status \(statusCode)\(suffix)"
        case .requestFailed(let detail):
            return "Live Sync context request failed: \(detail)"
        case .socketFailure(let detail):
            return "Live Sync action socket failed: \(detail)"
        case .malformedInvocation(let detail):
            return "Received a malformed Live Sync action invocation: \(detail)"
        case .actionHandlerFailed(let action, let detail):
            return "Handler for the `\(action)` action failed: \(detail)"
        case .invalidPayload(let action, let detail):
            return "Rejected the `\(action)` action before it ran: \(detail)"
        case .credentialVendingFailed(let detail):
            return "Live Sync credentials could not be vended: \(detail)"
        case .consentNotGranted:
            return "Live Sync context was not sent because consent has not been granted"
        case .contactMayBeStale(let quietFor):
            return "Live Sync is connected but has received nothing for \(quietFor): the contact ID may not name a live conversation"
        }
    }
}
