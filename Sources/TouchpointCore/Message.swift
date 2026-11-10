import Foundation

/// The public message type. Part of the immutable surface from the first release:
/// its **shape is locked in v1**, while the rendering of the richer fields lands in increment 2.
/// Adding a field later would be a breaking change; adding a renderer for a field that already
/// exists is additive.
///
/// `Message` is a value **projected from the store**, never the stored entity. The transcript a
/// host sees is always a projection of persisted state, which is what makes resume and
/// reconciliation observable rather than magical.
///
/// Two caveats recorded while they are cheap:
/// - **Choice identifiers are display titles, not stable opaque ids.** For Connect-native quick
///   replies and list pickers the upstream client derives the id from the element's title, falling
///   back to a positional index. Nothing may assume choice ids are stable across renders or safe to
///   persist as keys.
/// - **Markdown support is an inclusion list.** Assistant messages render inline emphasis,
///   strikethrough, links, bulleted and numbered lists (including nested), headings, fenced code,
///   thematic breaks and tables. Not rendered: images (alt text shows), task-list checkboxes, and
///   HTML (tags are dropped, their text kept). Parsing is Foundation's
///   `AttributedString(markdown:)` at `.full`; block layout is the SDK's own. User messages are
///   plain text, as web's are.
public struct Message: Sendable, Equatable, Identifiable {
    /// The `Identifiable` key: our client id, which is **stable for the row's whole life** — a list
    /// keyed on it does not delete-and-reinsert the bubble when the server acknowledges a send.
    public var id: UUID { clientMessageID }
    /// Our idempotency key; stable across retries.
    public let clientMessageID: UUID
    /// The server's id once assigned; `nil` for a local echo the server has not acknowledged.
    public let serverMessageID: MessageID?
    public let direction: Direction
    public let participantRole: ParticipantRole
    /// Connect `ParticipantId` of the sender, when the wire carried one. Lets a transcript with two
    /// agents, or an agent and a supervisor, attribute each message.
    public let participantID: String?
    /// Raw text as received. Markdown is rendered by the UI layer, never pre-processed here.
    public let body: String
    /// Server ordering authority: the server's `AbsoluteTime` in milliseconds since 1970 — Connect
    /// has no ordinal, and device clocks are never trusted for ordering. `nil` until reconciled;
    /// local echoes pin to the tail.
    public let sequence: Int?
    /// Display formatting only, never ordering.
    public let createdAt: Date
    public let deliveryState: DeliveryState

    // Locked in v1, rendered in increment 2.
    public let interactive: InteractiveContent?
    public let citations: [Citation]
    public let isStreaming: Bool // True until the final chunk arrives

    /// Projection from the stored row. Increment-2 blobs that fail to decode project as empty
    /// rather than failing the message: the text is what the user needs, and the server copy is
    /// authoritative.
    public init(_ stored: StoredMessage) {
        clientMessageID = stored.clientMessageID
        serverMessageID = stored.serverMessageID.map { MessageID(rawValue: $0) }
        direction = stored.direction
        participantRole = stored.participantRole
        participantID = stored.participantID
        body = stored.body
        sequence = stored.sequence
        createdAt = stored.createdAt
        deliveryState = stored.deliveryState
        interactive = stored.interactiveJSON.flatMap { try? JSONDecoder().decode(InteractiveContent.self, from: $0) }
        citations = stored.citationsJSON.flatMap { try? JSONDecoder().decode([Citation].self, from: $0) } ?? []
        isStreaming = stored.isStreaming
    }
}

/// Interactive message content: choice sets, list and time pickers. v1 carries the template
/// type and the raw Connect payload; increment 2 adds typed decoding and rendering on top without
/// changing this shape.
public struct InteractiveContent: Sendable, Equatable, Codable {
    /// Connect template type, e.g. `ListPicker`, `QuickReply`, `TimePicker`, `Panel`, `Carousel`.
    /// Two values are the SDK's own rather than Connect's: ``touchpointModalityTemplateType``, the
    /// envelope web's Touchpoint uses in both directions, and ``jsonTemplateType``, for an
    /// `application/json` message, which has no template of its own.
    public let templateType: String
    /// The `application/vnd.amazonaws.connect.message.interactive` payload, verbatim.
    public let rawJSON: Data

    public init(templateType: String, rawJSON: Data) {
        self.templateType = templateType
        self.rawJSON = rawJSON
    }

    /// The envelope web's Touchpoint sends and receives (`connect/conversation.ts:252`).
    public static let touchpointModalityTemplateType = "TouchpointModality"
    /// Marks content that arrived as `application/json` rather than as an interactive template.
    public static let jsonTemplateType = "application/json"

    /// The replies this message offers, in the order the flow gave them. Empty for a template that
    /// carries none, and for a payload that cannot be read — a malformed payload is a message
    /// without choices, never a crash.
    ///
    /// Decoded the way web decodes them (`connect/conversation.ts`), shape by shape:
    /// - **QuickReply / ListPicker**: `data.content.elements`, or `replies`, each element's `title`
    ///   serving as both id and text (`:1146-1155`). See the caveat on ``Message`` — these ids are
    ///   display titles, not stable keys.
    /// - **TouchpointModality** of `type: "message"`: `data.content.modalityPayload.choices`
    ///   (`:1090-1093`).
    /// - **`application/json`**: the choices of the **last** entry in `messages` that has any —
    ///   the one web offers (`App.tsx:612`) — read leniently: `choiceId` or `id`, `choiceText`,
    ///   `text` or `label` (`:1031-1035`).
    ///
    /// An element with no title is web's "Option N", with id `choice-<index>` (CV-7), and at most
    /// ``maximumChoices`` are read (CV-4), as Android caps them.
    public var choices: [InteractiveChoice] { Array(allChoices.prefix(Self.maximumChoices)) }

    /// Android's cap: a payload is not a reason to lay out a thousand buttons.
    public static let maximumChoices = 100

    private var allChoices: [InteractiveChoice] {
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else { return [] }
        let content = (root["data"] as? [String: Any])?["content"] as? [String: Any]
        switch templateType {
        case "QuickReply", "ListPicker":
            let elements = (content?["elements"] as? [Any]) ?? (content?["replies"] as? [Any]) ?? []
            return elements.enumerated().map { index, element in
                guard let title = (element as? [String: Any])?["title"] as? String, !title.isEmpty else {
                    return InteractiveChoice(id: "choice-\(index)", text: TouchpointStrings.untitledChoice(index + 1))
                }
                return InteractiveChoice(id: title, text: title)
            }
        case Self.touchpointModalityTemplateType:
            guard let payload = content?["modalityPayload"] as? [String: Any],
                  (payload["type"] as? String) == "message" else { return [] }
            return Self.lenientChoices(payload["choices"])
        case Self.jsonTemplateType:
            let messages = root["messages"] as? [Any] ?? []
            for message in messages.reversed() {
                let choices = Self.lenientChoices((message as? [String: Any])?["choices"])
                if !choices.isEmpty { return choices }
            }
            return []
        default:
            return []
        }
    }

    /// Whether the payload carries something drawn as a card rather than as text: a modality, or a
    /// Connect View. Web takes the welcome screen down for either (`App.tsx:630-664`); a message
    /// that only offers replies keeps it.
    package var carriesCard: Bool {
        if templateType == "ViewResource" { return true }
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else { return false }
        let content = (root["data"] as? [String: Any])?["content"] as? [String: Any]
        let modalities = templateType == Self.jsonTemplateType
            ? root["modalities"]
            : (content?["modalityPayload"] as? [String: Any])?["modalities"]
        return ((modalities as? [String: Any])?.isEmpty == false)
    }

    private static func lenientChoices(_ value: Any?) -> [InteractiveChoice] {
        (value as? [Any] ?? []).enumerated().compactMap { index, raw in
            guard let choice = raw as? [String: Any] else { return nil }
            let id = (choice["choiceId"] ?? choice["id"]) as? String ?? "choice-\(index)"
            // Web's `c.choiceText ?? c.text ?? c.label ?? "Option N"` (`conversation.ts:1031-1035`).
            let text = ((choice["choiceText"] ?? choice["text"] ?? choice["label"]) as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? TouchpointStrings.untitledChoice(index + 1)
            return InteractiveChoice(id: id, text: text)
        }
    }

    /// The modalities this message carries, in the order the flow wrote them — web renders each
    /// `[name, data]` of `modalityPayload.modalities` in turn (`Messages.tsx:754-775`). Read from a
    /// `TouchpointModality` message's `data.content.modalityPayload.modalities`, or an
    /// `application/json` message's top-level `modalities`. Empty for anything else, and for a
    /// payload that cannot be read.
    public var modalities: [TouchpointModality] {
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else { return [] }
        let content = (root["data"] as? [String: Any])?["content"] as? [String: Any]
        let raw: Any?
        switch templateType {
        case Self.touchpointModalityTemplateType: raw = (content?["modalityPayload"] as? [String: Any])?["modalities"]
        case Self.jsonTemplateType: raw = root["modalities"]
        default: raw = nil
        }
        guard let object = raw as? [String: Any], !object.isEmpty else { return [] }
        // JSONSerialization forgets key order, which is the order web draws them in. Recover it from
        // where each name first appears after the `modalities` key in the raw text; a name that
        // somehow cannot be found sorts last, alphabetically.
        let text = String(decoding: rawJSON, as: UTF8.self)
        let anchor = text.range(of: "\"modalities\"")?.upperBound ?? text.startIndex
        func position(_ name: String) -> Int {
            guard let r = text.range(of: "\"\(name)\"", range: anchor..<text.endIndex) else { return .max }
            return text.distance(from: text.startIndex, to: r.lowerBound)
        }
        return object.keys
            .sorted { (position($0), $0) < (position($1), $1) }
            .compactMap { name in
                guard let value = object[name], JSONSerialization.isValidJSONObject(["v": value]),
                      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) else { return nil }
                return TouchpointModality(name: name, json: data)
            }
    }

    /// A Connect View (`ShowView`, `templateType: ViewResource`): the ids the guide card needs to
    /// resolve and open the view (`viewId`, `viewToken`, runtime `viewData`) plus the heading and
    /// subheading web shows before it is opened (`GuideCard.tsx:109-116`). `nil` for any other
    /// template, or a payload that cannot be read.
    package var viewReference: ConnectViewReference? {
        guard templateType == "ViewResource",
              let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else { return nil }
        let content = (root["data"] as? [String: Any])?["content"] as? [String: Any]
        // `viewData` arrives as an object or a JSON string (web parses the string, `:1120-1127`).
        var viewData = content?["viewData"] as? [String: Any]
        if viewData == nil, let string = content?["viewData"] as? String {
            viewData = (try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]
        }
        let viewDataJSON = viewData.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        return ConnectViewReference(
            viewId: content?["viewId"] as? String,
            viewToken: content?["viewToken"] as? String,
            viewData: viewDataJSON,
            heading: viewData?["Heading"] as? String,
            subheading: viewData?["SubHeading"] as? String)
    }

    /// What web's guide card shows before it is opened — the view data's `Heading` and
    /// `SubHeading`. `nil` for any non-View template. Derived from ``viewReference``.
    package var viewSummary: (heading: String?, subheading: String?)? {
        guard let reference = viewReference else { return nil }
        return (reference.heading, reference.subheading)
    }
}

/// One modality a message carries: its name — `DefaultCard`, `DefaultCarousel`,
/// `DefaultDateInput`, `DefaultVideo`, or a host's own — and its data as the flow resolved it.
/// The SDK draws the four defaults; a host draws its own (`touchpointModality(_:render:)`).
public struct TouchpointModality: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    /// The modality's value, as JSON. Decode it with `JSONDecoder` into the host's own type.
    public let json: Data

    public init(name: String, json: Data) {
        self.name = name
        self.json = json
    }
}

/// Where a modality saves what the customer picks — web's `$saveAs` (`shared.ts:34-53`).
public struct TouchpointModalitySaveTarget: Sendable, Equatable, Decodable {
    public enum Kind: String, Sendable, Decodable { case slot, context, choiceId }
    public let type: Kind
    public let id: String

    public init(type: Kind, id: String) {
        self.type = type
        self.id = id
    }
}

/// One reply a message offers. Taking it sends ``text`` as the customer's answer.
public struct InteractiveChoice: Sendable, Equatable, Hashable, Codable {
    /// The flow's identifier for the choice. For Connect's own templates this is the display title.
    public let id: String
    /// What the button says, and what the transcript echoes as the customer's message.
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// A knowledge-base source attached to an assistant message.
public struct Citation: Sendable, Equatable, Codable {
    public let title: String
    public let url: URL?
    public let snippet: String?

    public init(title: String, url: URL? = nil, snippet: String? = nil) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public extension InteractiveContent {
    /// Longest `action` Amazon Connect accepts on an interactive response.
    static let maxResponseActionLength = 200
    /// Largest interactive response Connect accepts when it is addressed to a conversational bot.
    static let maxResponseBytes = 16_384

    /// The interactive response that answers a choice, exactly as web builds it
    /// (`connect/conversation.ts:1263-1300`): a `TouchpointModality` envelope at version 1.0, the
    /// choice's text as both `action` and `data.content.title` — Connect rejects a response without
    /// an `action`, and the agent portal reads the title — and the choice id as the structured
    /// request. `content` is a sibling of `modalityPayload`, never inside it: the contact flow
    /// rejects any key in `modalityPayload` beyond `request` and `context`.
    ///
    /// Throws `invalidConfiguration` past Connect's 16 KB limit. Web logs and drops the send; here
    /// the caller is told, so nothing appears to have gone that did not.
    static func choiceResponse(_ choice: InteractiveChoice) throws -> InteractiveContent {
        let trimmed = choice.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Web's fallback when the choice has no copy of its own (`describeModalityRequest`).
        let action = String((trimmed.isEmpty ? "Selected an option" : trimmed).prefix(maxResponseActionLength))
        let envelope: [String: Any] = [
            "templateType": touchpointModalityTemplateType,
            "version": "1.0",
            "action": action,
            "data": [
                "content": ["title": action],
                // Web's empty context beside the request (CV-5), as Android sends it.
                "modalityPayload": ["request": ["structured": ["choiceId": choice.id]], "context": [String: Any]()],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard data.count <= maxResponseBytes else {
            throw TouchpointError.invalidConfiguration("choice response is \(data.count) bytes; Connect accepts at most \(maxResponseBytes)")
        }
        return InteractiveContent(templateType: touchpointModalityTemplateType, rawJSON: data)
    }

    /// The interactive response that fills a slot from a modality — a carousel card tapped, a date
    /// picked — exactly as web's `sendSlots` builds it (`connect/conversation.ts:1261-1305,
    /// 1449-1460`): `structured.slots`, and an `action` that describes them ("Charge: harbour"),
    /// capped like a choice's.
    static func slotResponse(id: String, value: String) throws -> InteractiveContent {
        let action = String("\(id): \(value)".prefix(maxResponseActionLength))
        let envelope: [String: Any] = [
            "templateType": touchpointModalityTemplateType,
            "version": "1.0",
            "action": action,
            "data": [
                "content": ["title": action],
                "modalityPayload": ["request": ["structured": ["slots": [["slotId": id, "value": value]]]]],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard data.count <= maxResponseBytes else {
            throw TouchpointError.invalidConfiguration("slot response is \(data.count) bytes; Connect accepts at most \(maxResponseBytes)")
        }
        return InteractiveContent(templateType: touchpointModalityTemplateType, rawJSON: data)
    }

    /// Whether this is a response that fills slots rather than answering a choice. Web draws no
    /// customer bubble for one (`Messages.tsx:597-640` renders only text and choice responses).
    package var isSlotResponse: Bool {
        guard let root = try? JSONSerialization.jsonObject(with: rawJSON) as? [String: Any] else { return false }
        let structured = (((root["data"] as? [String: Any])?["modalityPayload"] as? [String: Any])?["request"] as? [String: Any])?["structured"] as? [String: Any]
        return structured?["slots"] != nil
    }

    /// The SDK's envelope for a Connect View response. Web's `submitView` tags it `ViewResource`
    /// (`conversation.ts:1690-1703`) and sends it as an `interactive.response`; Connect routes it
    /// like any other interactive response.
    static let viewResourceResponseTemplateType = "ViewResource"

    /// The interactive response that answers a Connect View action, byte-for-byte as web's
    /// `submitView` builds it (`connect/conversation.ts:1690-1703`):
    /// `{templateType:"ViewResource", version:"1.0", viewName?, action, data}`. `dataJSON` is the
    /// renderer's `Output`/`Data` as a JSON object; anything that is not an object (or is empty)
    /// becomes `{}`, exactly as web's `data ?? {}`.
    ///
    /// **Deviation:** unlike ``choiceResponse(_:)`` the `action` is not capped — web does not cap
    /// it and a View's action is a short protocol name ("Submit", "Next") — but the whole envelope
    /// is still held to Connect's 16 KB interactive-response limit, past which this throws so a
    /// submit that cannot go out is reported rather than silently dropped (web logs and drops it).
    static func viewResponse(viewName: String?, action: String, dataJSON: Data) throws -> InteractiveContent {
        let data = (try? JSONSerialization.jsonObject(with: dataJSON)) as? [String: Any] ?? [String: Any]()
        var envelope: [String: Any] = [
            "templateType": viewResourceResponseTemplateType,
            "version": "1.0",
            "action": action,
            "data": data,
        ]
        if let viewName { envelope["viewName"] = viewName }
        let encoded = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard encoded.count <= maxResponseBytes else {
            throw TouchpointError.invalidConfiguration("view response is \(encoded.count) bytes; Connect accepts at most \(maxResponseBytes)")
        }
        return InteractiveContent(templateType: viewResourceResponseTemplateType, rawJSON: encoded)
    }
}

// MARK: - Attachments

/// A file in the conversation: one the agent sent, or one the customer uploaded. Its bytes stay
/// with Amazon Connect; fetch a short-lived link with ``TouchpointSession/attachmentURL(id:)``.
public struct MessageAttachment: Sendable, Equatable, Hashable, Codable {
    /// Connect's `AttachmentId`.
    public let id: String
    /// The file name as uploaded.
    public let name: String
    /// MIME type, e.g. `application/pdf`.
    public let contentType: String

    public init(id: String, name: String, contentType: String) {
        self.id = id
        self.name = name
        self.contentType = contentType
    }
}

public extension InteractiveContent {
    /// The SDK's own template for an attachment. An attachment rides in the message's interactive
    /// slot so it persists through the store's existing column — the store needs no migration —
    /// and no Connect template uses this name.
    static let attachmentTemplateType = "TouchpointAttachment"

    static func attachment(_ attachment: MessageAttachment) -> InteractiveContent {
        // Encoding three strings cannot fail; an empty payload would read back as no attachment.
        InteractiveContent(templateType: attachmentTemplateType, rawJSON: (try? JSONEncoder().encode(attachment)) ?? Data())
    }

    /// The attachment this carries, or `nil` for any other template or an unreadable payload.
    var attachment: MessageAttachment? {
        guard templateType == Self.attachmentTemplateType else { return nil }
        return try? JSONDecoder().decode(MessageAttachment.self, from: rawJSON)
    }
}

public extension Message {
    /// The file this message carries, if it is an attachment. Its ``body`` is then empty.
    var attachment: MessageAttachment? { interactive?.attachment }
}

// MARK: - Redaction

extension Message: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "Message(clientMessageID: \(clientMessageID), serverMessageID: \(serverMessageID.map(\.rawValue) ?? "nil"), "
            + "direction: \(direction), participantRole: \(participantRole), sequence: \(sequence.map(String.init) ?? "nil"), "
            + "deliveryState: \(deliveryState), body: <redacted>)"
    }
    public var debugDescription: String { description }
}

extension InteractiveContent: CustomStringConvertible, CustomDebugStringConvertible {
    // The raw payload carries the message's words and choices; only its size is loggable.
    public var description: String { "InteractiveContent(templateType: \(templateType), rawJSON: <\(rawJSON.count) bytes>)" }
    public var debugDescription: String { description }
}

extension MessageAttachment: CustomStringConvertible, CustomDebugStringConvertible {
    // A file's name is content.
    public var description: String { "MessageAttachment(id: \(id), name: <redacted>, contentType: \(contentType))" }
    public var debugDescription: String { description }
}
