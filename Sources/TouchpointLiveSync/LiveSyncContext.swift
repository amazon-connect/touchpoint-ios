import Foundation

/// The app state advertised to the conversation engine.
///
/// A context is a complete snapshot, not a patch: each call to ``LiveSyncClient/sendContext(_:)``
/// replaces whatever was advertised before. Scopes describe the actions they are sent with, so the
/// two travel together — send both every time the app's capabilities change, and pass an empty
/// `actions` array to advertise nothing.
public struct LiveSyncContext: Sendable {
    /// Actions the assistant may invoke. Only the declarations travel; handling lives in
    /// ``LiveSyncClient/onAction``.
    public var actions: [LiveSyncAction]

    /// Scope tags describing where the customer is in the journey, so the engine can narrow the
    /// available actions down to the ones relevant here. Omitted when `nil`.
    public var scopes: [String]?

    public init(actions: [LiveSyncAction] = [], scopes: [String]? = nil) {
        self.actions = actions
        self.scopes = scopes
    }

    /// The `nlx:vpContext` object as sent to the context API.
    func voicePlusContext() -> JSONValue {
        var object: [String: JSONValue] = [
            "actions": .array(actions.map(\.advertisedDefinition))
        ]
        if let scopes {
            object["scopes"] = .array(scopes.map(JSONValue.string))
        }
        return .object(object)
    }
}
