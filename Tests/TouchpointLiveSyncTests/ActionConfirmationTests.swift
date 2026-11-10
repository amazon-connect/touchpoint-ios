import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - ConfirmationRequired on declarative Live Sync actions
//
// The confirmation UI is a SwiftUI `.confirmationDialog` that only materialises in a running app,
// so these exercise the gate the dialog drives — the client's dispatch path and the declarative
// wiring that feeds it — not the sheet itself.

private func customFrame(_ action: String, payload: String = "{}") -> String {
    #"{"classification":"custom","action":"\#(action)","payload":\#(payload)}"#
}

private struct ContactInfo: TouchpointActionPayload, Equatable {
    var fullName: String?
    static let schema: JSONValue = .object(["type": "object", "properties": ["fullName": ["type": "string"]]])
}

extension LiveSyncStubBackedSuites {
@Suite("Action confirmation", .serialized)
@MainActor
struct ActionConfirmationTests {

    // MARK: Client dispatch gate (imperative path)

    @Test("CF1: confirmationRequired=false path is unchanged — the handler runs immediately")
    func passthroughWhenNotRequired() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("delete_account")
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }

        client.ingest(customFrame("delete_account"))

        #expect(calls.value == ["delete_account"])
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 0)
    }

    @Test("CF2: a confirmation-required action is held — the handler does not run until confirm")
    func heldUntilConfirm() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500 to savings")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }
        let changes = Capture<[LiveSyncClient.PendingConfirmation?]>([])
        client.onPendingConfirmationChange = { changes.value.append($0) }

        client.ingest(customFrame("transfer_funds"))

        // Held: nothing ran, a prompt is pending with the declared description.
        #expect(calls.value.isEmpty)
        let pending = try #require(client.pendingConfirmation)
        #expect(pending.action == "transfer_funds")
        #expect(pending.actionDescription == "Move $500 to savings")
        #expect(changes.value.count == 1)

        client.confirmPendingAction()

        #expect(calls.value == ["transfer_funds"])
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 0)
        #expect(changes.value.last == .some(nil))   // cleared on confirm
    }

    @Test("CF3: cancel never runs the handler, reports a decline on the failure path, and counts it")
    func cancelDropsAndReports() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }
        let errors = Capture<[LiveSyncError]>([])
        client.onError = { errors.value.append($0) }

        client.ingest(customFrame("transfer_funds"))
        client.cancelPendingAction()

        #expect(calls.value.isEmpty)
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 1)
        // Reused failure-reply surface: the engine learns it did not happen, with a non-sensitive reason.
        #expect(errors.value == [.actionHandlerFailed(action: "transfer_funds", description: "declined by user")])
    }

    @Test("CF4: the contact ending while a confirmation is pending drops it without running, and counts it")
    func sessionEndDropsPending() async throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }
        let errors = Capture<[LiveSyncError]>([])
        client.onError = { errors.value.append($0) }

        client.ingest(customFrame("transfer_funds"))
        #expect(client.pendingConfirmation != nil)

        await client.teardown()

        #expect(calls.value.isEmpty)
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 1)
        #expect(errors.value == [.actionHandlerFailed(action: "transfer_funds", description: "declined by user")])
    }

    @Test("CF5: consent revoked while pending drops it (revocation is immediate), and counts it")
    func consentDenialDropsPending() async throws {
        let client = try makeTestClient(consent: .granted)
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }

        client.ingest(customFrame("transfer_funds"))
        #expect(client.pendingConfirmation != nil)

        await client.setConsent(.denied)

        #expect(calls.value.isEmpty)
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 1)
    }

    @Test("CF6: only one confirmation at a time — a second one while pending is declined, not queued")
    func secondPendingDeclined() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("close_account", "transfer_funds")
        client.confirmationRequirements = [
            "transfer_funds": .init(actionDescription: "Move $500"),
            "close_account": .init(actionDescription: "Close the account"),
        ]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }
        let errors = Capture<[LiveSyncError]>([])
        client.onError = { errors.value.append($0) }

        client.ingest(customFrame("transfer_funds"))   // held
        client.ingest(customFrame("close_account"))    // arrives while one is pending → declined

        #expect(client.pendingConfirmation?.action == "transfer_funds")
        #expect(client.diagnostics.declinedConfirmations == 1)
        #expect(errors.value == [.actionHandlerFailed(action: "close_account", description: "declined by user")])

        client.confirmPendingAction()
        #expect(calls.value == ["transfer_funds"], "the still-pending first action runs once on confirm")
    }

    @Test("CF7: a non-confirmation action still dispatches immediately while a confirmation is pending")
    func unrelatedActionNotBlocked() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("search_flights", "transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }

        client.ingest(customFrame("transfer_funds"))     // held
        client.ingest(customFrame("search_flights"))     // not gated → runs now

        #expect(calls.value == ["search_flights"])
        #expect(client.pendingConfirmation?.action == "transfer_funds")
    }

    @Test("CF8: the raw observation feed only sees a held invocation once it is confirmed")
    func observationStreamSeesOnConfirm() async throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        var iterator = client.invocations().makeAsyncIterator()

        client.ingest(customFrame("transfer_funds", payload: #"{"amount":500}"#))
        client.confirmPendingAction()

        let invocation = await iterator.next()
        #expect(invocation?.action == "transfer_funds")
        #expect(invocation?.payload["amount"]?.intValue == 500)
    }

    // MARK: Declarative wiring (aggregator / modifier path)

    @Test("CF9: a confirmationRequired declaration syncs the client's requirements on flush")
    func aggregatorSyncsRequirements() throws {
        let client = try makeTestClient()
        let aggregator = TouchpointActionAggregator(client: client)
        aggregator.update(TouchpointActionSet([
            TouchpointActionDeclaration("transfer_funds", description: "Move money", confirmationRequired: true) { },
            TouchpointActionDeclaration("view_balance", description: "Show balance") { },
        ]))
        aggregator.flushNow()

        #expect(client.confirmationRequirements.keys.sorted() == ["transfer_funds"])
        #expect(client.confirmationRequirements["transfer_funds"]?.actionDescription == "Move money")
    }

    @Test("CF10: through a client, a confirmationRequired frame is held and only routes to the declared handler on confirm")
    func heldThroughClient() async throws {
        StubURLProtocol.reset()
        let transports = FakeTransportFactory()
        let client = try makeTestClient(transports: transports)
        client.advertiseForTesting("set_contact_info")
        let aggregator = TouchpointActionAggregator(client: client)
        let received = Capture<ContactInfo?>(nil)
        aggregator.update(TouchpointActionSet([
            TouchpointActionDeclaration("set_contact_info", description: "Fill in your details",
                                        confirmationRequired: true) { (c: ContactInfo) in received.value = c }
        ]))
        aggregator.flushNow()
        client.connect()
        let transport = try #require(await transports.waitFor(1)); transport.opened()

        transport.frame(customFrame("set_contact_info", payload: #"{"fullName":"Ana"}"#))
        #expect(await eventually { client.pendingConfirmation?.action == "set_contact_info" })
        #expect(received.value == nil, "the handler must not run before confirmation")

        client.confirmPendingAction()
        #expect(received.value == ContactInfo(fullName: "Ana"))
        #expect(aggregator.routedInvocations == 1)
    }

    // MARK: Set / declaration plumbing

    @Test("CF11: TouchpointActionSet.confirmationRequirements covers only opted-in actions, with description as default body")
    func setRequirements() {
        let set = TouchpointActionSet([
            TouchpointActionDeclaration("a", description: "plain") { },
            TouchpointActionDeclaration("b", description: "sensitive", confirmationRequired: true) { },
            TouchpointActionDeclaration("c", description: "sensitive too", confirmationRequired: true,
                                        confirmationMessage: "Custom body") { },
        ])
        let requirements = set.confirmationRequirements
        #expect(requirements.keys.sorted() == ["b", "c"])
        #expect(requirements["b"]?.actionDescription == "sensitive")
        #expect(requirements["b"]?.message == nil)
        #expect(requirements["c"]?.message == "Custom body")
    }

    @Test("CF12: flipping confirmationRequired changes the content fingerprint so SwiftUI re-evaluates")
    func confirmationChangesFingerprint() {
        let plain = TouchpointActionSet([TouchpointActionDeclaration("a", description: "d") { }])
        let gated = TouchpointActionSet([TouchpointActionDeclaration("a", description: "d", confirmationRequired: true) { }])
        #expect(plain != gated)
    }
}
}

extension LiveSyncStubBackedSuites.ActionConfirmationTests {
    // MARK: A held action does not survive a suspension

    @Test("CF14: a human agent joining while a confirmation is pending declines it — Allow afterwards runs nothing", arguments: [
        DispatchChangeReason.humanAgentJoined, .resumedUnreconciled,
    ])
    func suspensionDeclinesHeld(reason: DispatchChangeReason) async throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }
        let events = Capture<[String]>([])
        client.onError = { events.value.append("error: \($0)") }
        client.onDispatchStateChange = { state, _ in events.value.append("dispatch: \(state)") }

        client.ingest(customFrame("transfer_funds"))
        #expect(client.pendingConfirmation != nil)
        await client.suspendDispatch(reason: reason)

        #expect(client.pendingConfirmation == nil, "the prompt is withdrawn")
        #expect(client.diagnostics.declinedConfirmations == 1)
        #expect(events.value == ["error: actionHandlerFailed(action: transfer_funds, description: declined by user)",
                                 "dispatch: suspended"], "declined before the host hears of the suspension")
        client.confirmPendingAction()
        await client.resumeDispatch()
        client.confirmPendingAction()
        #expect(calls.value.isEmpty, "nothing runs with a person on the contact, nor after they leave")
    }

    @Test("CF15: the held action leaving the declared requirements (its screen went) declines it")
    func requirementsDropDeclinesHeld() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }

        client.ingest(customFrame("transfer_funds"))
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]   // unchanged: kept
        #expect(client.pendingConfirmation != nil)
        client.confirmationRequirements = [:]
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.declinedConfirmations == 1)
        client.confirmPendingAction()
        #expect(calls.value.isEmpty)
    }

    @Test("CF16: Allow for an action no longer advertised is rejected rather than run (an imperative host that never updates requirements)")
    func confirmAfterUnadvertisedDeclines() throws {
        let client = try makeTestClient()
        client.advertiseForTesting("transfer_funds")
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move $500")]
        let calls = Capture<[String]>([])
        client.onAction = { calls.value.append($0.action) }

        client.ingest(customFrame("transfer_funds"))
        client.advertiseForTesting("view_balance")      // the screen moved on
        client.confirmPendingAction()

        #expect(calls.value.isEmpty)
        #expect(client.pendingConfirmation == nil)
        #expect(client.diagnostics.rejectedInvocations == 1)
    }

    @Test("CF17: an invalid payload for a gated action is rejected before any prompt, and not counted as a decline")
    func invalidPayloadNeverPrompts() throws {
        let client = try makeTestClient()
        client.adoptAdvertisedContext(LiveSyncContext(actions: [LiveSyncAction("transfer_funds", description: "Move money", schema: [
            "type": "object", "additionalProperties": false, "properties": ["amount": ["type": "number"]],
        ])]))
        client.confirmationRequirements = ["transfer_funds": .init(actionDescription: "Move money")]
        let errors = Capture<[LiveSyncError]>([])
        client.onError = { errors.value.append($0) }

        client.ingest(customFrame("transfer_funds", payload: #"{"amount":"all of it"}"#))

        #expect(client.pendingConfirmation == nil, "no prompt for a payload that cannot run")
        #expect(client.diagnostics.rejectedInvocations == 1)
        #expect(client.diagnostics.declinedConfirmations == 0)
        #expect(errors.value == [.invalidPayload(action: "transfer_funds", description: "type at /amount")])
    }

    @Test("CF13: the client-less aggregator hands confirmation requirements to its host on flush")
    func clientLessAggregatorForwardsRequirements() throws {
        let client = try makeTestClient()
        let aggregator = TouchpointActionAggregator(
            confirmations: { [weak client] in client?.confirmationRequirements = $0 },
            post: { _ in })
        aggregator.update(TouchpointActionSet([
            TouchpointActionDeclaration("transfer_funds", description: "Move money", confirmationRequired: true) { },
            TouchpointActionDeclaration("view_balance", description: "Show balance") { },
        ]))
        aggregator.flushNow()
        #expect(client.confirmationRequirements.keys.sorted() == ["transfer_funds"])
    }
}
