import Foundation
import SwiftUI
import Testing
import TouchpointCore
import TouchpointLiveSync
@testable import AcmeBank

// MARK: - The dispute flow's handlers, the no-submit property, contract conformance, a11y

@MainActor
private func makeModel() -> (AppModel, Capture<[String]>) {
    let model = AppModel()
    let announced = Capture<[String]>([])
    model.assistantFeedback = { announced.value.append($0) }
    model.signIn()
    return (model, announced)
}

@MainActor
final class Capture<Value> {
    var value: Value
    init(_ v: Value) { value = v }
}

/// The declarations exactly as the screens make them, so handler tests exercise the same typed
/// routing the view tree does. (The screens themselves need a rendered tree; the set they declare
/// does not.)
@MainActor
private func declarations(for scope: String, model: AppModel) -> TouchpointActionSet {
    switch scope {
    case "accounts":
        return TouchpointActionSet([
            TouchpointActionDeclaration(DisputeActions.openAccount, description: "d", scope: scope) { (p: OpenAccount) in model.openAccount(p) },
        ])
    case "transactions":
        return TouchpointActionSet([
            TouchpointActionDeclaration(DisputeActions.filterTransactions, description: "d", scope: scope) { (p: FilterTransactions) in model.filterTransactions(p) },
            TouchpointActionDeclaration(DisputeActions.selectTransaction, description: "d", scope: scope) { (p: SelectTransaction) in model.selectTransaction(p) },
        ])
    case "dispute":
        return TouchpointActionSet([
            TouchpointActionDeclaration(DisputeActions.startDispute, description: "d", scope: scope) { (p: StartDispute) in model.startDispute(p) },
            TouchpointActionDeclaration(DisputeActions.setDisputeDetails, description: "d", scope: scope) { (p: SetDisputeDetails) in model.setDisputeDetails(p) },
        ])
    default:
        return TouchpointActionSet()
    }
}

@MainActor
private func route(_ action: String, _ payload: JSONValue, scope: String, model: AppModel) throws {
    let agg = TouchpointActionAggregator(post: { _ in })
    agg.update(declarations(for: scope, model: model)); agg.flushNow()
    try agg.route(LiveSyncActionInvocation(action: action, payload: payload))
}

@Suite("Dispute flow handlers")
@MainActor
struct DisputeHandlerTests {
    @Test("open_account by type lands on the credit card and clears any filter")
    func openAccount() throws {
        let (model, announced) = makeModel()
        model.transactionFilter = TransactionFilter(amount: 1, date: nil, merchant: nil)
        try route("open_account", ["accountType": "credit_card"], scope: "accounts", model: model)
        #expect(model.path.count == 1)
        #expect(model.transactionFilter == nil)
        #expect(announced.value.count == 1)
    }

    @Test("filter_transactions is progressive: amount alone, then a date adds to it; an empty call clears")
    func filterProgressive() throws {
        let (model, _) = makeModel()
        try route("filter_transactions", ["amount": 240], scope: "transactions", model: model)
        #expect(model.transactionFilter?.amount == 240)
        #expect(model.transactionFilter?.date == nil)
        try route("filter_transactions", ["date": "2026-10-06"], scope: "transactions", model: model)
        #expect(model.transactionFilter?.amount == 240)
        #expect(model.transactionFilter?.date == "2026-10-06")
        try route("filter_transactions", .object([:]), scope: "transactions", model: model)
        #expect(model.transactionFilter == nil)
    }

    @Test("filter_transactions tolerates the amount as a string, as a model sometimes sends it")
    func filterStringAmount() throws {
        let (model, _) = makeModel()
        try route("filter_transactions", ["amount": "$240.00"], scope: "transactions", model: model)
        #expect(model.transactionFilter?.amount == 240)
    }

    @Test("select_transaction with no id picks the first filtered match on the visible account")
    func selectFiltered() throws {
        let (model, _) = makeModel()
        let card = model.account(ofKind: "credit_card")!
        model.visibleAccount = card
        let target = card.transactions.first { $0.amount < 0 }!
        model.transactionFilter = TransactionFilter(amount: -target.amount, date: nil, merchant: target.merchant)
        try route("select_transaction", .object([:]), scope: "transactions", model: model)
        #expect(model.path.count == 2)
    }

    @Test("start_dispute opens the form; set_dispute_details fills only the fields given, across turns")
    func disputeFill() throws {
        let (model, announced) = makeModel()
        try route("start_dispute", .object([:]), scope: "dispute", model: model)
        #expect(model.disputeOpen)
        try route("set_dispute_details", ["reason": "not_recognized"], scope: "dispute", model: model)
        #expect(model.disputeReason == "not_recognized")
        #expect(model.disputeCardPossession == nil)
        try route("set_dispute_details", ["cardPossession": "have_card", "authorized": false], scope: "dispute", model: model)
        #expect(model.disputeReason == "not_recognized", "an earlier turn's field survives a later partial one")
        #expect(model.disputeCardPossession == "have_card")
        #expect(model.disputeAuthorized == false)
        #expect(announced.value.count == 3)
    }

    @Test("a payload field the contract does not declare is a decode of nothing, never a crash")
    func unknownField() throws {
        let (model, _) = makeModel()
        try route("set_dispute_details", ["stillHaveCard": true], scope: "dispute", model: model)   // the drift the live test found
        #expect(model.disputeCardPossession == nil)
    }

    @Test("every assistant-driven change announces for VoiceOver")
    func announcements() throws {
        let (model, announced) = makeModel()
        try route("open_account", .object([:]), scope: "accounts", model: model)
        model.visibleAccount = model.account(ofKind: "credit_card")
        try route("filter_transactions", ["merchant": "Riverside"], scope: "transactions", model: model)
        try route("start_dispute", .object([:]), scope: "dispute", model: model)
        try route("set_dispute_details", ["reason": "duplicate"], scope: "dispute", model: model)
        #expect(announced.value.count == 4)
        #expect(announced.value.allSatisfy { !$0.isEmpty })
        #expect(announced.value.allSatisfy { !$0.contains("_") }, "announcements are human words, never action names")
    }
}

@Suite("Scope transitions")
@MainActor
struct ScopeTransitionTests {
    @Test("each screen declares exactly its contract actions, in its scope, and nothing from another screen")
    func perScreen() {
        let (model, _) = makeModel()
        #expect(declarations(for: "accounts", model: model).names == ["open_account"])
        #expect(declarations(for: "accounts", model: model).scopes == ["accounts"])
        #expect(declarations(for: "transactions", model: model).names == ["filter_transactions", "select_transaction"])
        #expect(declarations(for: "dispute", model: model).names == ["set_dispute_details", "start_dispute"])
        #expect(declarations(for: "dispute", model: model).scopes == ["dispute"])
    }

    @Test("navigating accounts → transactions → dispute changes the advertised context each time, with no imperative call")
    func navigationAdvertises() async {
        let (model, _) = makeModel()
        let posted = Capture<[LiveSyncContext]>([])
        let agg = TouchpointActionAggregator(post: { posted.value.append($0) })
        for scope in ["accounts", "transactions", "dispute"] {
            agg.update(declarations(for: scope, model: model)); agg.flushNow()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(posted.value.map(\.scopes) == [["accounts"], ["transactions"], ["dispute"]])
        #expect(posted.value.last?.actions.map(\.name) == ["set_dispute_details", "start_dispute"])
    }
}

@Suite("No action can submit the dispute")
@MainActor
struct NoSubmitActionTests {
    @Test("the catalogue contains no submit-like action, and no payload carries a submit-like field")
    func noSubmit() {
        let forbidden = ["submit", "confirm", "file", "send_dispute", "finalize", "finalise", "complete"]
        for name in DisputeActions.catalogue.keys {
            for f in forbidden { #expect(!name.lowercased().contains(f), "action \(name) looks like it submits") }
        }
        for (name, entry) in DisputeActions.catalogue {
            let props = entry.structure["properties"]?.objectValue?.keys.map { $0.lowercased() } ?? []
            for f in forbidden { #expect(!props.contains { $0.contains(f) }, "\(name) has a submit-like field") }
        }
    }

    @Test("driving every action through the model leaves the form unsubmitted — only the customer's tap does that")
    func modelCannotSubmit() throws {
        let (model, _) = makeModel()
        try route("start_dispute", .object([:]), scope: "dispute", model: model)
        try route("set_dispute_details", ["reason": "not_recognized", "cardPossession": "have_card", "authorized": false, "additionalDetails": "x"], scope: "dispute", model: model)
        // The model has no submitted state at all: submission is local to DisputeFormView's button.
        let mirror = Mirror(reflecting: model)
        #expect(!mirror.children.contains { ($0.label ?? "").lowercased().contains("submit") })
    }
}

@Suite("Contract conformance")
struct ContractConformanceTests {
    @Test("the app's typed schemas equal the bundled contract files, action for action — the ACXD node is built from the same files")
    func schemasMatchFixtures() {
        let files = ActionContractBundle.files
        #expect(Set(files.keys) == Set(DisputeActions.catalogue.keys), "an action exists on one side only: \(Set(files.keys).symmetricDifference(DisputeActions.catalogue.keys))")
        for (name, entry) in DisputeActions.catalogue {
            guard let fileSchema = ActionContractBundle.schema(name) else { Issue.record("no fixture for \(name)"); continue }
            #expect(entry.structure == Self.stripDescriptions(fileSchema), "\(name) drifted from its contract file")
        }
    }

    @Test("every contract field is optional — the assistant sends only what the customer said")
    func allOptional() {
        for (name, entry) in DisputeActions.catalogue {
            #expect(entry.structure["required"] == nil, "\(name) requires a field")
            #expect(entry.structure["additionalProperties"] == .bool(false), "\(name) must reject fields it does not declare")
        }
    }

    @Test("the advertised schema is the contract file itself (structure plus the prose the model reads)")
    func advertisedIsFile() {
        #expect(SetDisputeDetails.schema == ActionContractBundle.schema(DisputeActions.setDisputeDetails))
        #expect(SetDisputeDetails.schema["properties"]?["cardPossession"]?["description"]?.stringValue?.isEmpty == false)
    }

    @Test("every action has a description for the model to choose on")
    func descriptions() {
        for name in DisputeActions.catalogue.keys {
            #expect(!(ActionContractBundle.description(of: name) ?? "").isEmpty, "\(name) has no description")
        }
    }

    /// The SDK validates every payload on the device against the advertised schema and rejects any
    /// action whose schema strays outside its supported subset. Advertising the whole
    /// contract must therefore report nothing — or an action would be dead in a live call.
    @Test("every contract schema is inside the SDK's on-device validation subset")
    @MainActor
    func contractIsValidatable() async throws {
        struct NoKeys: LiveSyncCredentialSource {
            func liveSyncCredentials() async throws -> LiveSyncCredentials { .init(deploymentKey: "d", apiKey: "k", expiresAt: nil) }
            func invalidateLiveSyncCredentials() async {}
        }
        let client = LiveSyncClient(
            configuration: try LiveSyncConfiguration(region: "ca-central-1", conversationId: "00000000-0000-0000-0000-000000000000",
                                                     channel: LiveSyncChannel(locale: Locale(identifier: "en_US"))),
            credentials: NoKeys(), consent: .held, autoConnect: false)
        var reported: [LiveSyncError] = []
        client.onError = { reported.append($0) }
        let actions = DisputeActions.catalogue.keys.sorted().compactMap { name in
            ActionContractBundle.schema(name).map { LiveSyncAction(name, description: name, schema: $0) }
        }
        #expect(actions.count == DisputeActions.catalogue.count)
        try await client.sendContext(LiveSyncContext(actions: actions))   // held consent: recorded, not posted
        #expect(reported.isEmpty, "unsupported or engine-rewritten schema: \(reported)")
    }

    /// Property-level `description`s are prose for the model; the Swift schemas carry structure only.
    private static func stripDescriptions(_ v: JSONValue) -> JSONValue {
        switch v {
        case .object(let o):
            var out: [String: JSONValue] = [:]
            for (k, val) in o where k != "description" { out[k] = stripDescriptions(val) }
            return .object(out)
        case .array(let a): return .array(a.map(stripDescriptions))
        default: return v
        }
    }
}
