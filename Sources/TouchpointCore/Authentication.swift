import Foundation

// Connect customer authentication — the flow's "Authenticate Customer" block. Web's
// `Authentication.tsx` card and `conversation.ts` state machine; the transport owns the protocol,
// Core only names the states and forwards.

/// Where one sign-in stands (web's `AuthenticationStatus`).
public enum AuthenticationStatus: String, Sendable, Equatable, Hashable, Codable {
    /// The flow asked the customer to sign in: Authenticate, or continue without.
    case prompt
    /// The sign-in sheet is open, or its result is on its way to Connect.
    case inProgress
    case success
    case failed
    /// Connect's window lapsed (its `timeout` or `expired` event, or 60 s without a start).
    case expired
    /// The customer continued without signing in, or closed the sheet.
    case cancelled

    /// Prompt and in progress hold the composer: web locks the input until the card resolves.
    public var isPending: Bool { self == .prompt || self == .inProgress }
}

/// The transcript's sign-in card: one per `authentication.initiated`, updated in place.
public struct AuthenticationCard: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let status: AuthenticationStatus
    /// The newest message when the flow asked; the card is drawn after it, like a notice.
    public let after: UUID?

    public init(id: UUID, status: AuthenticationStatus, after: UUID?) {
        self.id = id
        self.status = status
        self.after = after
    }
}

/// How the system sign-in sheet recognises the redirect coming back from Connect.
///
/// A custom scheme (`.scheme`) is matched by `ASWebAuthenticationSession` on any OS version; an
/// https universal link (`.https`) is matched by host and path and needs iOS 17.4's
/// `ASWebAuthenticationSession.Callback.https` (so the SDK offers it only when the OS supports it —
/// see ``AuthenticationRequest``). The host must own the associated domain for an https redirect.
public enum AuthenticationCallback: Sendable, Equatable {
    /// A custom URL scheme the app registered (e.g. `acmebank-touchpoint`).
    case scheme(String)
    /// An https universal-link callback: the host owns the associated domain, and the redirect is
    /// recognised by this exact host and path.
    case https(host: String, path: String)
}

/// What the system sign-in sheet opens, and how its redirect is recognised on the way back.
public struct AuthenticationRequest: Sendable, Equatable, CustomStringConvertible {
    public let url: URL
    public let callback: AuthenticationCallback

    public init(url: URL, callback: AuthenticationCallback) {
        self.url = url
        self.callback = callback
    }

    /// Convenience for the custom-scheme form, which is all v1 originally supported.
    public init(url: URL, callbackScheme: String) {
        self.init(url: url, callback: .scheme(callbackScheme))
    }

    /// The custom scheme the redirect comes back on, or `nil` for an https universal-link callback.
    public var callbackScheme: String? {
        if case .scheme(let scheme) = callback { scheme } else { nil }
    }

    /// The URL carries Connect's `state` and `nonce`; only the callback shape is printed.
    public var description: String {
        switch callback {
        case .scheme(let scheme): "AuthenticationRequest(host: \(url.host ?? "?"), callbackScheme: \(scheme))"
        case .https(let host, let path): "AuthenticationRequest(host: \(url.host ?? "?"), callbackHost: \(host), callbackPath: \(path))"
        }
    }
}

/// What the sign-in redirect carried, for the host's backend to hand to Connect with
/// `UpdateParticipantAuthentication` — an IAM API the device cannot call. Web posts the same fields
/// to its `authenticationEndpoint` (`conversation.ts:1851-1866`); the instance id stays on the
/// backend here.
public struct AuthenticationCompletion: Sendable, Equatable, Codable, CustomStringConvertible {
    public let code: String?
    public let state: String
    public let error: String?
    public let errorDescription: String?

    public init(code: String?, state: String, error: String? = nil, errorDescription: String? = nil) {
        self.code = code
        self.state = state
        self.error = error
        self.errorDescription = errorDescription
    }

    /// The code is a one-time credential.
    public var description: String { "AuthenticationCompletion(code: \(code == nil ? "nil" : "<redacted>"), error: \(error ?? "nil"))" }
}

/// The host's relay of a sign-in to its backend. A separate protocol rather than a
/// `TouchpointBackend` requirement: a throwing default would let a backend that was never wired for
/// sign-in look configured.
public protocol AuthenticationRelaying: Sendable {
    func completeAuthentication(_ completion: AuthenticationCompletion) async throws
}
