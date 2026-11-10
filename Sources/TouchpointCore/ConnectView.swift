import Foundation

// MARK: - Connect Views / step-by-step Guides

/// A reference to an Amazon Connect View / step-by-step Guide, as it arrives on the transcript in a
/// `ViewResource` interactive message. The definition is **not** inlined — only referenced
/// (web's `connect/conversation.ts:1116-1139`): a `viewId` (managed or custom view ARN), an
/// encrypted `viewToken`, and runtime `viewData`. The real `Template`/`InputSchema` are resolved
/// from the `viewToken` through ``TouchpointSession/describeView(viewToken:)``.
public struct ConnectViewReference: Sendable, Equatable {
    /// The managed- or custom-view id, when the message carried one.
    public let viewId: String?
    /// The encrypted token `describeView` resolves. **Never** placed into the renderer page.
    public let viewToken: String?
    /// Runtime input the flow attached (web's `InputData`), as a JSON object; `nil` when absent.
    public let viewData: Data?
    /// What the card shows before it is opened — the view data's `Heading` (`GuideCard.tsx:109-116`).
    public let heading: String?
    /// The view data's `SubHeading`.
    public let subheading: String?

    public init(viewId: String?, viewToken: String?, viewData: Data?, heading: String?, subheading: String?) {
        self.viewId = viewId
        self.viewToken = viewToken
        self.viewData = viewData
        self.heading = heading
        self.subheading = subheading
    }
}

/// A Connect View definition resolved from a `viewToken` through `DescribeView` — web's
/// `ResolvedView` (`connect/conversation.ts:355-370`). The service returns `Template` and
/// `InputSchema` as **stringified** JSON, which ``resolve(id:name:version:content:)`` parses so the
/// renderer can be handed the real objects. Both are kept as canonical JSON (`Data`) so the type
/// stays `Sendable`/`Equatable` across the transport boundary.
public struct ConnectViewDefinition: Sendable, Equatable {
    public let id: String?
    public let name: String?
    public let version: Int?
    /// The component-tree template describing what to render, as JSON.
    public let template: Data
    /// The schema for the view's expected input data, as JSON; `nil` when the view declares none.
    public let inputSchema: Data?
    /// Action names the view can emit, e.g. `["Submit", "Next"]`.
    public let actions: [String]

    public init(id: String?, name: String?, version: Int?, template: Data, inputSchema: Data?, actions: [String]) {
        self.id = id
        self.name = name
        self.version = version
        self.template = template
        self.inputSchema = inputSchema
        self.actions = actions
    }

    /// Map a `DescribeView` result into a definition, exactly as web's `describeView` does
    /// (`conversation.ts:1660-1680`): `Content.{Template, InputSchema, Actions}`, each of
    /// `Template`/`InputSchema` parsed from stringified JSON (and left as-is when it is already an
    /// object or does not parse). Pure and platform-neutral, so it is unit-tested on macOS without
    /// the vendor SDK; the iOS driver feeds it the `DescribeView` response's fields.
    public static func resolve(id: String?, name: String?, version: Int?, content: [String: Any]?) -> ConnectViewDefinition {
        let actions = (content?["Actions"] as? [Any])?.compactMap { $0 as? String } ?? []
        let template = canonicalJSON(parseMaybeString(content?["Template"])) ?? Data("{}".utf8)
        let inputSchema = canonicalJSON(parseMaybeString(content?["InputSchema"]))
        return ConnectViewDefinition(id: id, name: name, version: version,
                                     template: template, inputSchema: inputSchema, actions: actions)
    }

    /// Web's `parse`: a stringified JSON value becomes the parsed object; a string that is not JSON
    /// is kept as the string; a value that is already an object is returned unchanged.
    static func parseMaybeString(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if let string = value as? String {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(string.utf8), options: [.fragmentsAllowed]) {
                return parsed
            }
            return string
        }
        return value
    }

    /// Canonical (sorted-key) JSON for a parsed value, or `nil` when it cannot be serialised.
    static func canonicalJSON(_ value: Any?) -> Data? {
        guard let value, JSONSerialization.isValidJSONObject(value) || value is String || value is NSNumber else { return nil }
        return try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys])
    }
}
