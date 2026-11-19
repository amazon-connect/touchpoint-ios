import Foundation
import TouchpointLiveSync

// The five Acme Bank actions, typed. Each payload's `schema` is the JSON Schema the assistant
// reasons over *and* what the handler decodes, so a field name cannot drift between the two — the
// `stillHaveCard`/`cardPossession` mismatch the live test found is now a compile-time absence.
// `ContractConformanceTests` asserts these schemas equal the bundled fixture files byte for byte in
// meaning, so the ACXD node (built from the same files) and the app agree.
//
// Every field is optional: the assistant sends only what the customer actually said. There is
// deliberately **no** payload and no action that submits the dispute; `NoSubmitActionTests` keeps
// it that way.

/// A payload whose *structure* is written in Swift (what the handler decodes) and whose advertised
/// schema is the bundled contract file when present — the same structure plus the per-field prose
/// the model reasons over. `ContractConformanceTests` asserts structure and file agree.
protocol ContractAction: TouchpointActionPayload {
    static var actionName: String { get }
    static var structure: JSONValue { get }
}

extension ContractAction {
    static var schema: JSONValue { ActionContractBundle.schema(actionName) ?? structure }
}

enum DisputeActions {
    static let openAccount = "open_account"
    static let filterTransactions = "filter_transactions"
    static let selectTransaction = "select_transaction"
    static let startDispute = "start_dispute"
    static let setDisputeDetails = "set_dispute_details"

    /// The complete catalogue, in the scope that declares each. The conformance test compares this
    /// to the fixture directory so an action added in one place must be added in the other.
    static let catalogue: [String: (scope: String, structure: JSONValue)] = [
        openAccount: ("accounts", OpenAccount.structure),
        filterTransactions: ("transactions", FilterTransactions.structure),
        selectTransaction: ("transactions", SelectTransaction.structure),
        startDispute: ("dispute", StartDispute.structure),
        setDisputeDetails: ("dispute", SetDisputeDetails.structure),
    ]

    /// Descriptions are what the model chooses on; they live with the schema in the fixture so
    /// one place tunes them. Loaded from the bundle, falling back to the name.
    static func description(of action: String) -> String {
        ActionContractBundle.description(of: action) ?? action
    }
}

struct OpenAccount: TouchpointActionPayload, Equatable, ContractAction {
    static let actionName = DisputeActions.openAccount
    var accountId: String?
    var accountType: String?
    static let structure: JSONValue = .object([
        "type": "object", "additionalProperties": false, "properties": [
            "accountId": ["type": "string"],
            "accountType": ["type": "string", "enum": ["credit_card", "checking", "savings"]],
        ],
    ])
}

struct FilterTransactions: TouchpointActionPayload, Equatable, ContractAction {
    static let actionName = DisputeActions.filterTransactions
    /// `number` in the contract. A model could send "240" or "$240.00", but the SDK rejects a string
    /// against `type: number` on the device before this decoder runs; the tolerance below is only
    /// defence in depth for a host that routes invocations by hand.
    var amount: Decimal?
    var date: String?
    var merchant: String?

    init(amount: Decimal? = nil, date: String? = nil, merchant: String? = nil) {
        self.amount = amount; self.date = date; self.merchant = merchant
    }

    private enum Keys: String, CodingKey { case amount, date, merchant }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        date = try c.decodeIfPresent(String.self, forKey: .date)
        merchant = try c.decodeIfPresent(String.self, forKey: .merchant)
        if let d = try? c.decodeIfPresent(Double.self, forKey: .amount) {
            amount = Decimal(d)
        } else if let s = try? c.decodeIfPresent(String.self, forKey: .amount) {
            amount = Decimal(string: s.filter { "0123456789.".contains($0) })
        }
    }

    var isEmpty: Bool { amount == nil && date == nil && merchant == nil }

    static let structure: JSONValue = .object([
        "type": "object", "additionalProperties": false, "properties": [
            "amount": ["type": "number"],
            "date": ["type": "string", "format": "date"],
            "merchant": ["type": "string"],
        ],
    ])
}

struct SelectTransaction: TouchpointActionPayload, Equatable, ContractAction {
    static let actionName = DisputeActions.selectTransaction
    var transactionId: String?
    static let structure: JSONValue = .object([
        "type": "object", "additionalProperties": false, "properties": ["transactionId": ["type": "string"]],
    ])
}

struct StartDispute: TouchpointActionPayload, Equatable, ContractAction {
    static let actionName = DisputeActions.startDispute
    var transactionId: String?
    static let structure: JSONValue = .object([
        "type": "object", "additionalProperties": false, "properties": ["transactionId": ["type": "string"]],
    ])
}

struct SetDisputeDetails: TouchpointActionPayload, Equatable, ContractAction {
    static let actionName = DisputeActions.setDisputeDetails
    var reason: String?
    var cardPossession: String?
    var authorized: Bool?
    var additionalDetails: String?
    static let structure: JSONValue = .object([
        "type": "object", "additionalProperties": false, "properties": [
            "reason": ["type": "string", "enum": ["not_recognized", "duplicate", "incorrect_amount", "cancelled_service", "not_received", "other"]],
            "cardPossession": ["type": "string", "enum": ["have_card", "lost", "stolen"]],
            "authorized": ["type": "boolean"],
            "additionalDetails": ["type": "string"],
        ],
    ])
}

/// The bundled `*.schema.json` files (Resources/ActionContract, the same source the ACXD node is
/// built from). The Swift schemas above are what is advertised; the files are the *contract*, and
/// `ContractConformanceTests` asserts the two agree. Descriptions are read from here so a tuning pass
/// tunes them in one place.
enum ActionContractBundle {
    static let files: [String: JSONValue] = {
        guard let urls = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) else { return [:] }
        var out: [String: JSONValue] = [:]
        for url in urls where url.lastPathComponent.hasSuffix(".schema.json") {
            guard let data = try? Data(contentsOf: url), let v = try? JSONDecoder().decode(JSONValue.self, from: data),
                  let title = v["title"]?.stringValue else { continue }
            out[title] = v
        }
        return out
    }()

    static func schema(_ action: String) -> JSONValue? {
        guard var bare = files[action]?.objectValue else { return nil }
        bare.removeValue(forKey: "$schema"); bare.removeValue(forKey: "title"); bare.removeValue(forKey: "description")
        return .object(bare)
    }

    static func description(of action: String) -> String? {
        files[action]?["description"]?.stringValue
    }
}
