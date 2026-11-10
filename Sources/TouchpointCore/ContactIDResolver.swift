import Foundation

/// Produces the Amazon Connect contact ID of the live call the app should bind Live Sync to
///.
///
/// A contact the SDK *started* (chat or outbound voice) needs no resolver: the backend call returns
/// its ID and the session exposes it. The resolver exists for the showcase case — a call placed
/// outside the app, from the device's dialler, that the app must find.
///
/// **Production recommendation: resolve through the host backend.** The host's backend knows which
/// authenticated customer is calling (ANI lookup, account-linked voice, an agent-side action) and
/// can hand the app the contact ID over its existing authenticated channel. That keeps the ID
/// bound to an identity the backend has verified.
///
/// `DeepLinkContactIDResolver` is shipped as the *reference*, with the caveat at its declaration.
public protocol TouchpointContactIDResolver: Sendable {
    /// Resolves the contact ID, or `nil` if none is available right now. Throwing is for failures
    /// the host should hear about (a backend call that failed), not for "nothing to bind to yet".
    func resolveContactID() async throws -> String?
}

/// A fixed contact ID — the resolver for a contact the SDK started, or for manual entry in a demo.
public struct StaticContactIDResolver: TouchpointContactIDResolver {
    public let contactID: String?
    public init(_ contactID: String?) { self.contactID = contactID }
    public func resolveContactID() async throws -> String? { contactID }
}

/// Resolves the contact ID from a deep link the app was opened with.
///
/// **An unauthenticated deep link is a bearer credential for the conversation.** Whoever holds the
/// URL can bind an app to that call and receive every action the assistant issues for it. The
/// backend that mints such links must bind them to the authenticated customer (and expire them);
/// an app that accepts them must be sure the URL arrived through a channel only that customer
/// receives. For a bank, host-backend resolution is the recommendation and this
/// resolver is a reference implementation for development and the showcase.
///
/// Accepted shapes, exact-match on scheme and host, both configured by the host:
///
/// - `<scheme>://<host>/<path>/<contactID>` — the ID as the last path component
/// - `<scheme>://<host>/<path>?contactId=<contactID>` — or as a query item (`contactId`,
///   `contact_id` or `contactID`)
///
/// A contact ID must look like one — a UUID — so a hostile URL cannot smuggle arbitrary text into
/// the socket query. Anything else is rejected as `nil`; nothing is logged.
public struct DeepLinkContactIDResolver: TouchpointContactIDResolver {
    public let scheme: String
    public let host: String
    /// Path prefix that must precede the ID (e.g. `/livesync`). `nil` accepts any path.
    public let pathPrefix: String?
    private let url: URL?

    public init(url: URL?, scheme: String, host: String, pathPrefix: String? = nil) {
        self.url = url
        self.scheme = scheme.lowercased()
        self.host = host.lowercased()
        self.pathPrefix = pathPrefix
    }

    public func resolveContactID() async throws -> String? {
        guard let url else { return nil }
        return Self.contactID(from: url, scheme: scheme, host: host, pathPrefix: pathPrefix)
    }

    /// The parse, pure and testable. Returns `nil` for anything that is not an exact scheme/host
    /// match carrying a well-formed contact ID.
    public static func contactID(from url: URL, scheme: String, host: String, pathPrefix: String? = nil) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme.lowercased(),
              components.host?.lowercased() == host.lowercased(),
              components.user == nil, components.password == nil, components.port == nil
        else { return nil }

        let path = components.percentEncodedPath
        // No relative segments: a URL that needs normalising to match was not minted by our backend.
        guard !url.pathComponents.contains(where: { $0 == ".." || $0 == "." }) else { return nil }
        if let pathPrefix {
            let normalised = pathPrefix.hasPrefix("/") ? pathPrefix : "/" + pathPrefix
            guard path == normalised || path.hasPrefix(normalised + "/") else { return nil }
        }

        // Query first: an explicit `contactId=` beats a positional guess.
        let queryKeys: Set<String> = ["contactid", "contact_id"]
        if let item = components.queryItems?.first(where: { queryKeys.contains($0.name.lowercased()) }) {
            return validated(item.value)
        }
        // Then the last path component, which must be the ID itself.
        let last = url.pathComponents.last ?? ""
        guard last != "/" else { return nil }
        return validated(last)
    }

    /// Amazon Connect contact IDs are UUIDs. Anything else is refused.
    static func validated(_ candidate: String?) -> String? {
        guard let candidate, let uuid = UUID(uuidString: candidate) else { return nil }
        return uuid.uuidString.lowercased()
    }
}
