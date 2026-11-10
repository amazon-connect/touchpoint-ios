import Foundation

/// An action the voice assistant may invoke on the app.
///
/// An action is a pure declaration: a name, a description and a JSON Schema for its parameters, all
/// uploaded by ``LiveSyncClient/sendContext(_:)``. What the app *does* when the action arrives is
/// decided in one place — ``LiveSyncClient/onAction`` — so the declaration stays free of behaviour
/// and can be built anywhere, including off the main actor.
///
/// ```swift
/// LiveSyncAction(
///     "set_contact_info",
///     description: "Set the customer's name and email",
///     schema: [
///         "type": "object",
///         "properties": [
///             "fullName": ["type": "string"],
///             "email": ["type": "string"],
///         ],
///     ]
/// )
/// ```
public struct LiveSyncAction: Sendable, Equatable {
    /// Wire name of the action. Must be unique within a context and descriptive to the model.
    ///
    /// This is the name that arrives as ``LiveSyncActionInvocation/action``, so it is what
    /// ``LiveSyncClient/onAction`` switches on.
    public let name: String

    /// Short description of what the action does, used by the conversation engine to decide when to
    /// invoke it.
    public let description: String

    /// JSON Schema for the action's payload. The model reasons over it, and the client checks every
    /// payload against it on the device before ``LiveSyncClient/onAction`` runs (the engine does not
    /// validate against it). `nil` for actions that take no parameters: their payload must be empty.
    public let schema: JSONValue?

    /// Extra data to give the model additional context, e.g. the current value of a field.
    public let input: JSONValue?

    public init(
        _ name: String,
        description: String,
        schema: JSONValue? = nil,
        input: JSONValue? = nil
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.input = input
    }

    /// The JSON the conversation engine is told about.
    var advertisedDefinition: JSONValue {
        var object: [String: JSONValue] = [
            "action": .string(name),
            "description": .string(description),
        ]
        if let schema { object["schema"] = schema }
        if let input { object["input"] = input }
        return .object(object)
    }
}
