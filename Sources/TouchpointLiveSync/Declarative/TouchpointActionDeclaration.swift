import Foundation

/// A payload type a declared action decodes into. Conform your model and the schema, the decoding,
/// and the handler signature come from one declaration — the schema and the model cannot drift
/// ("infer payload type from the handler signature so schema and decoding cannot
/// diverge"; the live test's `stillHaveCard` vs `cardPossession` mismatch is the failure this
/// removes).
///
/// ```swift
/// struct DisputeDetails: TouchpointActionPayload {
///     var reason: String?
///     var authorized: Bool?
///     var amount: Double?
///     static let schema: JSONValue = .object(["type": "object", "properties": [
///         "reason": ["type": "string", "enum": ["unrecognized", "duplicate"]],
///         "authorized": ["type": "boolean"],
///         "amount": ["type": "number"],
///     ]])
/// }
/// ```
///
/// Every field should be optional: the engine sends only what the customer actually stated (plan
//). The SDK checks each payload against this schema **on the device** before the handler
/// runs — the engine does not validate against it — and rejects it otherwise
/// (``LiveSyncError/invalidPayload(action:description:)``). Keep the schema inside the supported
/// subset (see the security guide) and check business rules in the handler.
public protocol TouchpointActionPayload: Decodable, Sendable {
    /// JSON Schema the model reasons over and the SDK validates payloads against on the device.
    /// Advertised verbatim.
    static var schema: JSONValue { get }
}

/// An action with no parameters. Use it when the handler takes nothing.
public struct TouchpointNoPayload: TouchpointActionPayload, Equatable {
    public init() {}
    public init(from decoder: any Decoder) throws {}
    public static let schema: JSONValue = .object(["type": "object", "additionalProperties": false, "properties": .object([:])])
}

/// One declared action, as collected from the view tree. The handler is type-erased here; the
/// typed signature lives at the declaration site.
public struct TouchpointActionDeclaration: Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let description: String
    public let schema: JSONValue
    /// The scope tag the action is in, derived from the nearest enclosing `.touchpointScope`.
    public let scope: String?
    /// Whether an invocation of this action is held for the user to confirm before its handler runs
    ///. Use it on a reversible action the customer should see coming. It does not make an
    /// irreversible one (a payment, a transfer, a submission) safe to declare: declare only what the
    /// customer can undo, and leave the final step to the customer's own tap.
    public let confirmationRequired: Bool
    /// A host-supplied prompt body for the confirmation. When `nil` the prompt falls back to
    /// ``description``. Ignored unless ``confirmationRequired`` is `true`.
    public let confirmationMessage: String?
    /// Decodes and runs. Errors are reported by the client as `actionHandlerFailed`.
    let handler: @MainActor @Sendable (JSONValue) throws -> Void

    /// What the engine is told: name, description, schema. The handler stays on the device.
    public var advertised: LiveSyncAction {
        LiveSyncAction(name, description: description, schema: schema)
    }

    /// Equality by *content* — what would change the advertised context. Handler identity is
    /// deliberately excluded: a re-render that recreates closures must not re-post (
    /// "re-renders with unchanged content advertise nothing").
    /// Equality by *content* — what would change the advertised context. Handler identity is
    /// deliberately excluded: a re-render that recreates closures must not re-post (
    /// "re-renders with unchanged content advertise nothing"). The confirmation fields are included
    /// so flipping `confirmationRequired` (or changing the message) propagates through SwiftUI's
    /// `onPreferenceChange` — it gates dispatch even though it does not change the advertised wire
    /// action.
    public struct Fingerprint: Hashable, Sendable {
        public let name: String
        public let description: String
        public let schema: JSONValue
        public let scope: String?
        public let confirmationRequired: Bool
        public let confirmationMessage: String?
    }
    public var fingerprint: Fingerprint {
        .init(name: name, description: description, schema: schema, scope: scope,
              confirmationRequired: confirmationRequired, confirmationMessage: confirmationMessage)
    }
}

extension TouchpointActionDeclaration {
    /// A typed declaration. `Payload` is inferred from the handler.
    public init<Payload: TouchpointActionPayload>(
        _ name: String,
        description: String,
        scope: String? = nil,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        handler: @escaping @MainActor @Sendable (Payload) throws -> Void
    ) {
        self.name = name
        self.description = description
        self.schema = Payload.schema
        self.scope = scope
        self.confirmationRequired = confirmationRequired
        self.confirmationMessage = confirmationMessage
        self.handler = { json in
            try handler(try json.decode(Payload.self))
        }
    }

    /// A parameterless declaration.
    public init(
        _ name: String,
        description: String,
        scope: String? = nil,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        handler: @escaping @MainActor @Sendable () throws -> Void
    ) {
        self.init(name, description: description, scope: scope, confirmationRequired: confirmationRequired,
                  confirmationMessage: confirmationMessage) { (_: TouchpointNoPayload) in try handler() }
    }

    /// An untyped declaration: the schema is given by hand and the handler sees raw JSON. The
    /// escape hatch for a schema file shared with the backend (an action contract kept in one file for both sides).
    public init(
        _ name: String,
        description: String,
        schema: JSONValue,
        scope: String? = nil,
        confirmationRequired: Bool = false,
        confirmationMessage: String? = nil,
        rawHandler: @escaping @MainActor @Sendable (JSONValue) throws -> Void
    ) {
        self.name = name
        self.description = description
        self.schema = schema
        self.scope = scope
        self.confirmationRequired = confirmationRequired
        self.confirmationMessage = confirmationMessage
        self.handler = rawHandler
    }
}

/// The complete set of actions the visible view tree declares right now. Order is by name so two
/// trees declaring the same things produce the same context regardless of layout order.
public struct TouchpointActionSet: Sendable, Equatable {
    public private(set) var declarations: [TouchpointActionDeclaration]

    /// Content equality: SwiftUI's `onPreferenceChange` fires only when this changes, so identity
    /// churn that rebuilds handler closures never reaches the aggregator at all.
    public static func == (a: TouchpointActionSet, b: TouchpointActionSet) -> Bool { a.fingerprint == b.fingerprint }

    public init(_ declarations: [TouchpointActionDeclaration] = []) {
        // Last declaration wins for a duplicated name: the innermost view is the most specific.
        var byName: [String: TouchpointActionDeclaration] = [:]
        for d in declarations { byName[d.name] = d }
        self.declarations = byName.values.sorted { $0.name < $1.name }
    }

    public var isEmpty: Bool { declarations.isEmpty }
    public var names: [String] { declarations.map(\.name) }

    /// The scopes present, sorted, or `nil` when no declaration carries one — so a tree that never
    /// uses scopes advertises no `scopes` key at all, the same as the imperative call.
    public var scopes: [String]? {
        let s = Set(declarations.compactMap(\.scope))
        return s.isEmpty ? nil : s.sorted()
    }

    /// The content fingerprint. Equal fingerprints mean equal advertised contexts.
    public var fingerprint: Set<TouchpointActionDeclaration.Fingerprint> {
        Set(declarations.map(\.fingerprint))
    }

    /// The context to advertise.
    public var context: LiveSyncContext {
        LiveSyncContext(actions: declarations.map(\.advertised), scopes: scopes)
    }

    /// The confirmation requirements for the declarations that opt in, keyed by action name, ready
    /// to hand to ``LiveSyncClient/confirmationRequirements``. The declared `description` becomes the
    /// prompt body unless the declaration carried its own `confirmationMessage`.
    public var confirmationRequirements: [String: LiveSyncClient.ActionConfirmation] {
        var requirements: [String: LiveSyncClient.ActionConfirmation] = [:]
        for declaration in declarations where declaration.confirmationRequired {
            requirements[declaration.name] = LiveSyncClient.ActionConfirmation(
                actionDescription: declaration.description,
                message: declaration.confirmationMessage
            )
        }
        return requirements
    }

    public subscript(name: String) -> TouchpointActionDeclaration? {
        declarations.first { $0.name == name }
    }

    public mutating func merge(_ other: TouchpointActionSet) {
        self = TouchpointActionSet(declarations + other.declarations)
    }
}
