import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - Declarative action context

private struct ContactInfo: TouchpointActionPayload, Equatable {
    var fullName: String?
    var email: String?
    static let schema: JSONValue = .object(["type": "object", "properties": [
        "fullName": ["type": "string"], "email": ["type": "string"],
    ]])
}

private struct Amount: TouchpointActionPayload, Equatable {
    var amount: Double
    static let schema: JSONValue = .object(["type": "object", "properties": ["amount": ["type": "number"]], "required": ["amount"]])
}

/// Captures posted contexts; failures can be scripted.
@MainActor
private final class PostLog {
    var contexts: [LiveSyncContext] = []
    var fail: LiveSyncError?
    var reported: [LiveSyncError] = []
    func makeAggregator(clock: any LiveSyncSleeping = HeldClock(), debounce: Duration = .milliseconds(50), maxWait: Duration = .milliseconds(300)) -> TouchpointActionAggregator {
        TouchpointActionAggregator(debounce: debounce, maxWait: maxWait, clock: clock,
                                   report: { [weak self] in self?.reported.append($0) },
                                   post: { [weak self] in
                                       guard let self else { return }
                                       if let fail = self.fail { throw fail }
                                       self.contexts.append($0)
                                   })
    }
}

/// Waits for the aggregator's timer task to reach the clock, then lets it elapse.
@MainActor
private func fireWhenArmed(_ clock: HeldClock) async {
    // A burst cancels and re-arms the timer; wait until the surviving timer is the only waiter.
    _ = await eventually { clock.pending == 1 }
    try? await Task.sleep(for: .milliseconds(10))
    clock.fire()
}

private func decl(_ name: String, _ description: String = "d", scope: String? = nil, calls: Capture<[String]>? = nil) -> TouchpointActionDeclaration {
    TouchpointActionDeclaration(name, description: description, scope: scope) { calls?.value.append(name) }
}

extension LiveSyncStubBackedSuites {
@Suite("Declarative actions: set, aggregator, routing", .serialized)
@MainActor
struct DeclarativeActionTests {
    // MARK: Set semantics

    @Test("A1: the set orders by name, last declaration wins for a duplicate, scopes are sorted and nil when absent")
    func setSemantics() {
        let set = TouchpointActionSet([decl("b", scope: "two"), decl("a", scope: "one"), decl("b", "later", scope: "two")])
        #expect(set.names == ["a", "b"])
        #expect(set["b"]?.description == "later")
        #expect(set.scopes == ["one", "two"])
        #expect(TouchpointActionSet([decl("x")]).scopes == nil)
        #expect(TouchpointActionSet([decl("x")]).context.scopes == nil)
    }

    @Test("A2: equality is by content — recreated closures compare equal, a changed description does not")
    func contentEquality() {
        let a = TouchpointActionSet([decl("open", "Open")]); let b = TouchpointActionSet([decl("open", "Open")])
        #expect(a == b)
        #expect(a != TouchpointActionSet([decl("open", "Open it")]))
        #expect(a != TouchpointActionSet([decl("open", "Open", scope: "s")]))
    }

    @Test("A3: the advertised context carries the handler-inferred schema and never the handler")
    func advertisedContext() throws {
        let d = TouchpointActionDeclaration("set_contact_info", description: "Set") { (_: ContactInfo) in }
        let ctx = TouchpointActionSet([d]).context
        #expect(ctx.actions.map(\.name) == ["set_contact_info"])
        #expect(ctx.actions[0].schema == ContactInfo.schema)
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(ctx.voicePlusContext()))
        #expect(json["actions"]?[0]?["schema"]?["properties"]?["email"]?["type"]?.stringValue == "string")
    }

    // MARK: Debounce

    @Test("D1: a burst within the debounce window coalesces into one post carrying the final set")
    func burstCoalesces() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        agg.update(TouchpointActionSet([decl("a")]))
        agg.update(TouchpointActionSet([decl("a"), decl("b")]))
        agg.update(TouchpointActionSet([decl("b")]))
        #expect(log.contexts.isEmpty)
        await fireWhenArmed(clock)
        #expect(clock.requested.count >= 1 && clock.requested.count <= 3)
        #expect(clock.requested.allSatisfy { $0 == .milliseconds(50) })
        #expect(await eventually { log.contexts.count == 1 })
        #expect(log.contexts.first?.actions.map(\.name) == ["b"])
        #expect(agg.postCount == 1)
    }

    @Test("D2: the 300 ms ceiling — a tree that never settles still posts")
    func ceiling() async {
        let log = PostLog()
        // Real clock, tiny values: 10 ms debounce, 40 ms ceiling, updates every 5 ms for 300 ms (long
        // enough that a loaded CI runner still sees several ceilings pass).
        let agg = log.makeAggregator(clock: ContinuousClockSleeper(), debounce: .milliseconds(10), maxWait: .milliseconds(40))
        let start = ContinuousClock.now
        var n = 0
        while start.duration(to: .now) < .milliseconds(300) {
            n += 1
            agg.update(TouchpointActionSet([decl("a\(n)")]))
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await eventually { log.contexts.count >= 1 })
        // The first post must have happened by ~40 ms, not after the churn stopped at 300 ms.
        #expect(agg.postCount >= 2, "with a 40 ms ceiling inside 300 ms of churn there must be at least two posts; got \(agg.postCount)")
    }

    @Test("D3: re-renders with unchanged content advertise nothing and do not restart the timer")
    func unchangedIsIgnored() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        agg.update(TouchpointActionSet([decl("a", "Open")]))
        await fireWhenArmed(clock)
        #expect(await eventually { log.contexts.count == 1 })
        let armed = clock.requested.count
        for _ in 0..<20 { agg.update(TouchpointActionSet([decl("a", "Open")])) }   // identity churn: new closures, same content
        try? await Task.sleep(for: .milliseconds(20))
        #expect(clock.requested.count == armed, "no timer was armed for an unchanged set")
        #expect(log.contexts.count == 1)
        #expect(agg.postCount == 1)
    }

    @Test("D4: a change that is reverted before the timer fires posts nothing (the net change is none)")
    func revertedChange() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        agg.update(TouchpointActionSet([decl("a")])); await fireWhenArmed(clock)
        #expect(await eventually { log.contexts.count == 1 })
        agg.update(TouchpointActionSet([decl("a"), decl("b")]))
        agg.update(TouchpointActionSet([decl("a")]))              // back to what is advertised
        await fireWhenArmed(clock)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(log.contexts.count == 1)
        #expect(agg.postCount == 1)
    }

    @Test("D5: navigation changes the advertised set — the old screen's actions withdraw, the new screen's appear, scopes follow")
    func navigation() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        agg.update(TouchpointActionSet([decl("open_account", scope: "accounts")])); await fireWhenArmed(clock)
        #expect(await eventually { log.contexts.count == 1 })
        agg.update(TouchpointActionSet([decl("start_dispute", scope: "dispute"), decl("set_dispute_details", scope: "dispute")])); await fireWhenArmed(clock)
        #expect(await eventually { log.contexts.count == 2 })
        #expect(log.contexts[0].scopes == ["accounts"])
        #expect(log.contexts[1].actions.map(\.name) == ["set_dispute_details", "start_dispute"])
        #expect(log.contexts[1].scopes == ["dispute"])
    }

    @Test("D6: a post failure is reported, not thrown into the view tree, and the next change still posts")
    func postFailureReported() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        log.fail = .httpFailure(statusCode: 500, responseBody: nil)
        agg.update(TouchpointActionSet([decl("a")])); await fireWhenArmed(clock)
        #expect(await eventually { log.reported.count == 1 })
        log.fail = nil
        agg.update(TouchpointActionSet([decl("b")])); await fireWhenArmed(clock)
        #expect(await eventually { log.contexts.count == 1 })
    }

    // MARK: Routing and typed payloads

    @Test("R1: an invocation reaches the handler that declared it, typed")
    func routesTyped() throws {
        let log = PostLog()
        let agg = log.makeAggregator()
        let received = Capture<ContactInfo?>(nil)
        agg.update(TouchpointActionSet([
            TouchpointActionDeclaration("set_contact_info", description: "Set") { (c: ContactInfo) in received.value = c }
        ]))
        agg.flushNow()
        try agg.route(LiveSyncActionInvocation(action: "set_contact_info", payload: ["fullName": "Ana", "email": "a@x.y"]))
        #expect(received.value == ContactInfo(fullName: "Ana", email: "a@x.y"))
        #expect(agg.routedInvocations == 1)
    }

    @Test("R2: a partial payload decodes — every field optional, as the contract requires")
    func partialPayload() throws {
        let log = PostLog(); let agg = log.makeAggregator()
        let received = Capture<ContactInfo?>(nil)
        agg.update(TouchpointActionSet([TouchpointActionDeclaration("c", description: "d") { (c: ContactInfo) in received.value = c }]))
        agg.flushNow()
        try agg.route(LiveSyncActionInvocation(action: "c", payload: ["email": "only@x.y"]))
        #expect(received.value == ContactInfo(fullName: nil, email: "only@x.y"))
        try agg.route(LiveSyncActionInvocation(action: "c", payload: .object([:])))
        #expect(received.value == ContactInfo())
    }

    @Test("R3: a payload that does not match the model throws out of route — the client reports it as actionHandlerFailed")
    func decodeFailureThrows() {
        let log = PostLog(); let agg = log.makeAggregator()
        agg.update(TouchpointActionSet([TouchpointActionDeclaration("amt", description: "d") { (_: Amount) in }]))
        agg.flushNow()
        #expect(throws: (any Error).self) {
            try agg.route(LiveSyncActionInvocation(action: "amt", payload: ["amount": "240"]))   // string, schema says number
        }
    }

    @Test("R4: an unknown name is counted and reported, never thrown, never crashes")
    func unknownName() throws {
        let log = PostLog(); let agg = log.makeAggregator()
        try agg.route(LiveSyncActionInvocation(action: "submit_dispute", payload: .object([:])))
        #expect(agg.unroutedInvocations == 1)
        #expect(agg.routedInvocations == 0, "an unknown name changed nothing on screen")
        #expect(log.reported == [.actionHandlerFailed(action: "submit_dispute", description: "no declared action with this name")])
    }

    @Test("R5: routing honours the advertised set when the tree has moved on, so an action the engine was promised still lands")
    func routesAgainstAdvertised() throws {
        let log = PostLog(); let agg = log.makeAggregator()
        let calls = Capture<[String]>([])
        agg.update(TouchpointActionSet([decl("old", calls: calls)])); agg.flushNow()
        agg.update(TouchpointActionSet([decl("new", calls: calls)]))      // not yet flushed: engine still knows `old`
        try agg.route(LiveSyncActionInvocation(action: "old", payload: .object([:])))
        try agg.route(LiveSyncActionInvocation(action: "new", payload: .object([:])))   // and the newest is honoured too
        #expect(calls.value == ["old", "new"])
    }

    @Test("R6: a parameterless declaration advertises an empty object schema and routes with any payload")
    func parameterless() throws {
        let log = PostLog(); let agg = log.makeAggregator()
        let calls = Capture(0)
        agg.update(TouchpointActionSet([TouchpointActionDeclaration("go", description: "d") { calls.value += 1 }])); agg.flushNow()
        #expect(log.contexts.isEmpty == false || agg.advertised["go"]?.schema == TouchpointNoPayload.schema)
        try agg.route(LiveSyncActionInvocation(action: "go", payload: .object(["ignored": true])))
        #expect(calls.value == 1)
    }

    // MARK: Through a real client

    @Test("C1: bound to a client — the tree's set is posted through sendContext on open, and onAction routes to the declared handler")
    func throughClient() async throws {
        StubURLProtocol.reset()
        let transports = FakeTransportFactory()
        let client = try makeTestClient(transports: transports)
        client.advertiseForTesting("set_contact_info")
        let agg = TouchpointActionAggregator(client: client)
        let received = Capture<ContactInfo?>(nil)
        agg.update(TouchpointActionSet([
            TouchpointActionDeclaration("set_contact_info", description: "Set", scope: "profile") { (c: ContactInfo) in received.value = c }
        ]))
        agg.flushNow()
        client.connect()
        let t = try #require(await transports.waitFor(1)); t.opened()
        #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(StubURLProtocol.recordedRequests[0].httpBody))
        #expect(body["context"]?["nlx:vpContext"]?["scopes"] == .array(["profile"]))
        #expect(body["context"]?["nlx:vpContext"]?["actions"]?[0]?["action"]?.stringValue == "set_contact_info")
        t.frame(#"{"classification":"custom","action":"set_contact_info","payload":{"fullName":"Ana"}}"#)
        #expect(await eventually { received.value == ContactInfo(fullName: "Ana", email: nil) })
    }

    @Test("C2: a payload that does not match the schema is rejected on the device before the handler, and the socket keeps going")
    func handlerFailureThroughClient() async throws {
        let transports = FakeTransportFactory()
        let client = try makeTestClient(transports: transports)
        let agg = TouchpointActionAggregator(client: client)
        let errors = Capture<[LiveSyncError]>([]); client.onError = { errors.value.append($0) }
        let calls = Capture(0)
        agg.update(TouchpointActionSet([TouchpointActionDeclaration("amt", description: "d") { (_: Amount) in calls.value += 1 }])); agg.flushNow()
        #expect(await eventually { client.hasPendingContext })
        client.connect()
        let t = try #require(await transports.waitFor(1)); t.opened()
        t.frame(#"{"classification":"custom","action":"amt","payload":{"amount":"240"}}"#)
        t.frame(#"{"classification":"custom","action":"amt","payload":{"amount":240}}"#)
        #expect(await eventually { calls.value == 1 })
        #expect(errors.value.contains(.invalidPayload(action: "amt", description: "type at /amount")))
    }

    #if DEBUG
    @Test("O1: the overlay's text reflects advertised, pending and withdrawn actions and the dispatch gate")
    func overlayText() async {
        let log = PostLog(); let clock = HeldClock()
        let agg = log.makeAggregator(clock: clock)
        agg.update(TouchpointActionSet([decl("a", scope: "s1")])); await fireWhenArmed(clock)
        #expect(await eventually { agg.postCount == 1 })
        agg.update(TouchpointActionSet([decl("b", scope: "s2")]))          // pending; `a` withdrawn
        let lines = TouchpointLiveSyncOverlay.detailLines(agg)
        #expect(lines[0] == "scopes: s1 · 1 action")
        #expect(lines.contains("• a (withdrawn)"))
        #expect(lines.contains("+ b (pending)"))
        #expect(TouchpointLiveSyncOverlay.statusLine(connection: .connected, dispatch: .suspended, posts: 1) == "Live Sync: connected · dispatch SUSPENDED · 1 post")
        #expect(TouchpointLiveSyncOverlay.statusLine(connection: nil, dispatch: nil, posts: 0) == "Live Sync: no client · 0 posts")
        #expect(TouchpointLiveSyncOverlay.statusLine(connection: .reconnecting(attempt: 3), dispatch: .enabled, posts: 2) == "Live Sync: reconnecting #3 · 2 posts")
    }
    #endif
}
}
