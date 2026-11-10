import Foundation

/// An action the conversation engine invoked, as pushed over the action socket.
///
/// ``LiveSyncClient`` hands every invocation to ``LiveSyncClient/onAction`` and publishes it on
/// ``LiveSyncClient/invocations()`` for observers that want the raw feed. Switch on ``action`` to
/// decide what to do, and read ``payload`` directly or via ``decode(_:using:)``:
///
/// ```swift
/// switch invocation.action {
/// case "set_contact_info":
///     let contact = try invocation.decode(ContactInfo.self)
///     model.apply(contact)
/// case "set_cabin_class":
///     model.cabin = invocation.payload["cabin"]?.stringValue ?? model.cabin
/// default:
///     break
/// }
/// ```
public struct LiveSyncActionInvocation: Sendable, Equatable {
    /// Name of the invoked action, matching ``LiveSyncAction/name``.
    public let action: String

    /// Arguments the engine produced. By the time ``LiveSyncClient/onAction`` sees them they have been
    /// checked on the device against the schema the app advertised for this action.
    ///
    /// An action declared without a schema arrives with an empty object rather than `nil`.
    public let payload: JSONValue

    public init(action: String, payload: JSONValue) {
        self.action = action
        self.payload = payload
    }

    /// Decodes ``payload`` into a model.
    ///
    /// Throwing out of ``LiveSyncClient/onAction`` is safe: the failure is reported through
    /// ``LiveSyncClient/onError`` as ``LiveSyncError/actionHandlerFailed(action:description:)``.
    public func decode<Payload: Decodable>(
        _ type: Payload.Type = Payload.self,
        using decoder: JSONDecoder = JSONDecoder()
    ) throws -> Payload {
        try payload.decode(type, using: decoder)
    }
}

extension LiveSyncActionInvocation {
    /// Parses a socket frame as an action invocation.
    ///
    /// Returns `nil` for frames that carry something else (navigation, input, unknown); the client
    /// decodes those through `LiveSyncInboundFrame`, which is the one parser for the wire.
    static func decode(from data: Data) throws -> LiveSyncActionInvocation? {
        if case .custom(let invocation) = try LiveSyncInboundFrame.decode(from: data) { return invocation }
        return nil
    }
}
