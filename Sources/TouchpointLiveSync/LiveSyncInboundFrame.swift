import Foundation

/// A navigation instruction from the conversation engine (classification `navigation`).
///
/// Arrives whether or not the app advertised `destinations`: the backend guards only `page_custom`,
/// and a knowledge-base document carrying destination metadata emits one with no check at all. The
/// SDK surfaces it rather than dropping it; what the app does with it is the app's decision.
public struct LiveSyncNavigation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case pageNext
        case pagePrevious
        /// A named destination; `destination` carries the name.
        case pageCustom
        /// The engine could not map the request to a page.
        case pageUnknown
        /// A value this SDK does not model, kept verbatim.
        case other(String)

        init(wire: String) {
            switch wire {
            case "page_next": self = .pageNext
            case "page_previous": self = .pagePrevious
            case "page_custom": self = .pageCustom
            case "page_unknown": self = .pageUnknown
            default: self = .other(wire)
            }
        }
    }

    public let kind: Kind
    public let destination: String?

    public init(kind: Kind, destination: String?) {
        self.kind = kind
        self.destination = destination
    }
}

/// Everything the socket can deliver, decoded from both envelope shapes the backend produces:
/// interactive mode places the fields at top level, agentic mode nests them under `payload`.
enum LiveSyncInboundFrame: Sendable, Equatable {
    case custom(LiveSyncActionInvocation)
    case navigation(LiveSyncNavigation)
    /// `input` frames cannot arrive while nothing advertises `fields` — the backend's filter degrades
    /// to an empty allowlist — so they are counted, not modelled.
    case input
    /// A line the assistant spoke, which the engine delivers on the same socket and with the same
    /// `custom` classification as an action — distinguished only by carrying `note` instead of
    /// `action`. Informational: nothing in the app acts on it, but it is emphatically not malformed.
    case note(String?)
    /// A classification this SDK does not know. Ignored, never an error.
    case unknown(String?)

    private struct Envelope: Decodable {
        var classification: String?
        var action: String?
        var destination: String?
        var payload: JSONValue?
        var note: String?
    }

    static func decode(from data: Data) throws -> LiveSyncInboundFrame {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw LiveSyncError.malformedInvocation(description: LiveSyncError.describe(error))
        }

        switch envelope.classification {
        case "custom":
            // Observed on the wire: the engine interleaves the assistant's own speech with action
            // invocations under one classification, e.g.
            //   {"classification":"custom","note":"One moment.","metadata":{"interim":true}}
            // alongside
            //   {"classification":"custom","action":"open_account","payload":{…}}
            // A note has no `action` and is not an invocation, so it must not be reported as a
            // malformed one — doing so produced an error for every sentence the assistant said.
            guard let action = envelope.action, !action.isEmpty else {
                if envelope.note != nil { return .note(envelope.note) }
                throw LiveSyncError.malformedInvocation(
                    description: "An action invocation arrived without an `action` name"
                )
            }
            return .custom(LiveSyncActionInvocation(action: action, payload: envelope.payload ?? .object([:])))

        case "navigation":
            // Agentic shape nests `action`/`destination` under `payload`; interactive puts them at top level.
            let nestedAction = envelope.payload?["action"]?.stringValue
            let nestedDestination = envelope.payload?["destination"]?.stringValue
            guard let action = nestedAction ?? envelope.action, !action.isEmpty else {
                throw LiveSyncError.malformedInvocation(
                    description: "A navigation frame arrived without an `action`"
                )
            }
            return .navigation(LiveSyncNavigation(
                kind: .init(wire: action),
                destination: nestedDestination ?? envelope.destination
            ))

        case "input":
            return .input

        case let other:
            return .unknown(other)
        }
    }
}
