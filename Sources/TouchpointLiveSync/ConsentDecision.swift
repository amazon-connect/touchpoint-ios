import Foundation

/// Whether the customer has agreed to Live Sync sharing what the app is doing.
///
/// **No context POST happens before `.granted`** — not the first advertisement, not a replay on
/// reconnect. The default is `.held`: nothing has been decided, no context is sent. `.denied` leaves
/// chat and voice fully functional and Live Sync silent. The consent sheet adds the copy; the
/// gate itself lives here, where the context path is built, so no step in between can establish a
/// post-freely pattern.
///
/// The decision covers sharing, not the actions: as on Touchpoint for the web, an action the caller
/// asks for runs through what the current screen declares. A host that wants no action before the
/// grant keeps the socket closed until then (`autoConnect: false`).
public enum ConsentDecision: Sendable, Equatable {
    /// Not yet decided. Context is held, not posted.
    case held
    case granted
    case denied

    /// What a client starts with when nothing is specified: held.
    public static let `default`: ConsentDecision = .held

    #if DEBUG
    /// A development convenience so the declarative layer is not blocked on consent UI that does not exist
    /// yet. Debug builds only — there is deliberately no release spelling of this.
    public static let development: ConsentDecision = .granted
    #endif
}
