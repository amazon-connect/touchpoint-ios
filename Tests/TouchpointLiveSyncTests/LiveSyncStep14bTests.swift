import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - Navigation decode, teardown model, zombie guard, LiveSyncControl, agent gate

extension LiveSyncStubBackedSuites {
    @Suite("Inbound frames: navigation decoded, input counted", .serialized)
    @MainActor
    struct LiveSyncInboundFrameTests {
        @Test("N1: the interactive shape — navigation fields at top level")
        func navigationTopLevel() throws {
            let frame = try LiveSyncInboundFrame.decode(from: Data(#"{"classification":"navigation","action":"page_next"}"#.utf8))
            #expect(frame == .navigation(LiveSyncNavigation(kind: .pageNext, destination: nil)))
        }

        @Test("N2: the agentic shape — navigation fields nested under payload")
        func navigationNested() throws {
            let frame = try LiveSyncInboundFrame.decode(from: Data(#"{"classification":"navigation","payload":{"action":"page_custom","destination":"disputes"}}"#.utf8))
            #expect(frame == .navigation(LiveSyncNavigation(kind: .pageCustom, destination: "disputes")))
        }

        @Test("N3: page_next / page_previous / page_unknown arrive with nothing advertised and reach onNavigation")
        func navigationReachesHandler() throws {
            let client = try makeTestClient()
            let seen = Capture<[LiveSyncNavigation.Kind]>([])
            client.onNavigation = { seen.value.append($0.kind) }
            client.ingest(#"{"classification":"navigation","action":"page_next"}"#)
            client.ingest(#"{"classification":"navigation","payload":{"action":"page_previous"}}"#)
            client.ingest(#"{"classification":"navigation","action":"page_unknown"}"#)
            client.ingest(#"{"classification":"navigation","action":"page_sideways"}"#)
            #expect(seen.value == [.pageNext, .pagePrevious, .pageUnknown, .other("page_sideways")])
            #expect(client.diagnostics.unhandledNavigationFrames == 0)
        }

        @Test("N4: with no onNavigation the frame is counted, not an error")
        func navigationCountedWhenUnhandled() throws {
            let client = try makeTestClient()
            let errors = Capture(0); client.onError = { _ in errors.value += 1 }
            client.ingest(#"{"classification":"navigation","action":"page_next"}"#)
            #expect(client.diagnostics.unhandledNavigationFrames == 1)
            #expect(errors.value == 0)
        }

        @Test("N5: a navigation frame without an action is malformed")
        func navigationWithoutAction() {
            #expect(throws: LiveSyncError.self) {
                _ = try LiveSyncInboundFrame.decode(from: Data(#"{"classification":"navigation","payload":{}}"#.utf8))
            }
        }

        @Test("I1: input frames are dropped with a counter, both shapes")
        func inputCounted() throws {
            let client = try makeTestClient()
            let actions = Capture(0); client.onAction = { _ in actions.value += 1 }
            client.ingest(#"{"classification":"input","fields":[{"id":"a","value":"1"}]}"#)
            client.ingest(#"{"classification":"input","payload":{"fields":[{"id":"a","value":"1"}]}}"#)
            #expect(client.diagnostics.droppedInputFrames == 2)
            #expect(actions.value == 0)
        }

        @Test("U1: an unknown classification is ignored silently; the action decoder still returns nil for it")
        func unknownIgnored() throws {
            #expect(try LiveSyncInboundFrame.decode(from: Data(#"{"classification":"telemetry"}"#.utf8)) == .unknown("telemetry"))
            #expect(try LiveSyncActionInvocation.decode(from: Data(#"{"classification":"navigation","action":"page_next"}"#.utf8)) == nil)
        }
    }

    @Suite("Dispatch gate", .serialized)
    @MainActor
    struct LiveSyncDispatchGateTests {
        @Test("G1: suspended → invocations are counted, not dispatched; resumed → they flow again; both are announced")
        func suspendAndResume() async throws {
            let client = try makeTestClient()
            client.advertiseForTesting("open_account")
            let seen = Capture<[String]>([]); client.onAction = { seen.value.append($0.action) }
            let changes = Capture<[DispatchState]>([]); client.onDispatchStateChange = { s, _ in changes.value.append(s) }
            await client.suspendDispatch(reason: .humanAgentJoined)
            client.ingest(#"{"classification":"custom","action":"open_account"}"#)
            #expect(seen.value.isEmpty)
            #expect(client.diagnostics.suppressedInvocations == 1)
            await client.resumeDispatch()
            client.ingest(#"{"classification":"custom","action":"open_account"}"#)
            #expect(seen.value == ["open_account"])
            #expect(changes.value == [.suspended, .enabled])
        }

        @Test("G2: the observation stream is gated too")
        func streamGated() async throws {
            let client = try makeTestClient()
            client.advertiseForTesting("dropped", "kept")
            var it = client.invocations().makeAsyncIterator()
            await client.suspendDispatch(reason: .humanAgentJoined)
            client.ingest(#"{"classification":"custom","action":"dropped"}"#)
            await client.resumeDispatch()
            client.ingest(#"{"classification":"custom","action":"kept"}"#)
            #expect(await it.next()?.action == "kept")
        }

        @Test("G3: an invocation already inside onAction completes when suspension lands during it")
        func inFlightCompletes() async throws {
            let client = try makeTestClient()
            client.advertiseForTesting("a", "b")
            let steps = Capture<[String]>([])
            client.onAction = { inv in
                steps.value.append("begin \(inv.action)")
                Task { await client.suspendDispatch(reason: .humanAgentJoined) }
                steps.value.append("end \(inv.action)")
            }
            client.ingest(#"{"classification":"custom","action":"a"}"#)
            #expect(await eventually { client.dispatchState == .suspended })
            client.ingest(#"{"classification":"custom","action":"b"}"#)
            #expect(steps.value == ["begin a", "end a"])
        }

        @Test("G4: navigation is gated with dispatch")
        func navigationGated() async throws {
            let client = try makeTestClient()
            let seen = Capture(0); client.onNavigation = { _ in seen.value += 1 }
            await client.suspendDispatch(reason: .humanAgentJoined)
            client.ingest(#"{"classification":"navigation","action":"page_next"}"#)
            #expect(seen.value == 0)
            #expect(client.diagnostics.unhandledNavigationFrames == 1)
        }

        @Test("G5: a client attached to a session whose gate is already suspended starts suspended (cold-resume guard)")
        func attachAdoptsSuspended() async throws {
            let transport = StubContactTransport()
            let session = try await makeCoreSession(transport: transport)
            try await session.startChat(ChatContactRequest(displayName: "a"))
            #expect(await eventually { session.state == .connected })
            await transport.push(.participantJoined(Participant(id: "agent-1", role: .agent, displayName: "A")))
            #expect(await eventually { session.dispatchState == .suspended })

            let client = try makeTestClient()
            client.attach(to: session)
            #expect(session.isLiveSyncRegistered)
            #expect(client.dispatchState == .suspended)
        }

        @Test("G6: through the session — agent joins → client suspends; agent leaves → client resumes; contact ends → teardown")
        func sessionDrivesClient() async throws {
            let transport = StubContactTransport()
            let session = try await makeCoreSession(transport: transport)
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.advertiseForTesting("after_agent", "while_agent")
            client.attach(to: session)
            let seen = Capture<[String]>([]); client.onAction = { seen.value.append($0.action) }
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()

            try await session.startChat(ChatContactRequest(displayName: "a"))
            #expect(await eventually { session.state == .connected })
            await transport.push(.participantJoined(Participant(id: "agent-1", role: .agent, displayName: "A")))
            #expect(await eventually { client.dispatchState == .suspended })
            t.frame(#"{"classification":"custom","action":"while_agent"}"#)
            await transport.push(.participantLeft(id: "agent-1"))
            #expect(await eventually { client.dispatchState == .enabled })
            t.frame(#"{"classification":"custom","action":"after_agent"}"#)
            #expect(await eventually { seen.value == ["after_agent"] })
            #expect(client.diagnostics.suppressedInvocations == 1)

            await transport.push(.contactEnded(.agentEnded))
            #expect(await eventually { client.isTornDown })
            #expect(t.closed)
            client.connect()                                 // after teardown: no-op
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transports.count == 1)
        }
    }

    @Suite("Teardown model", .serialized)
    @MainActor
    struct LiveSyncTeardownTests {
        @Test("L1: background is a resumable disconnect; foreground reconnects and replays the held context")
        func backgroundForeground() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t1 = try #require(await transports.waitFor(1)); t1.opened()
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })

            client.enterBackground()
            #expect(t1.closed)
            #expect(client.connectionState == .disconnected)
            #expect(client.hasPendingContext)

            client.enterForeground()
            let t2 = try #require(await transports.waitFor(2)); t2.opened()
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 2 })
        }

        @Test("L2: foreground does nothing for a client that was not running when it went to the background")
        func foregroundWithoutBackgroundRun() async throws {
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.enterBackground()
            client.enterForeground()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transports.count == 0)
        }

        @Test("L3: teardown closes the socket, clears context and handlers, and connect() afterwards is a no-op")
        func teardownIsFinal() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.onAction = { _ in }
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            var it = client.invocations().makeAsyncIterator()
            await client.teardown()
            #expect(t.closed)
            #expect(client.isTornDown)
            #expect(!client.hasPendingContext)
            #expect(client.onAction == nil)
            #expect(await it.next() == nil)                       // observers are finished
            client.connect(); client.enterForeground()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transports.count == 1)
            #expect(client.connectionState == .disconnected)
        }

        @Test("L4: deallocation closes the socket and the idle guard")
        func deallocation() async throws {
            let transports = FakeTransportFactory()
            let idle = HeldClock()
            var client: LiveSyncClient? = try makeTestClient(transports: transports, idleClock: idle, idleReconnectThreshold: .seconds(240))
            client?.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { idle.pending == 1 })
            client = nil
            #expect(await eventually { t.closed })
            #expect(await eventually { idle.pending == 0 })
        }
    }

    @Suite("Idle guard (the zombie socket)", .serialized)
    @MainActor
    struct LiveSyncIdleGuardTests {
        @Test("Z1: a socket silent past the threshold is closed and reopened at once, with no backoff")
        func idleReconnects() async throws {
            let transports = FakeTransportFactory()
            let idle = HeldClock(); let clock = ManualClock()
            let client = try makeTestClient(transports: transports, clock: clock, idleClock: idle, idleReconnectThreshold: .seconds(240))
            let errors = Capture(0); client.onError = { _ in errors.value += 1 }
            client.connect()
            let t1 = try #require(await transports.waitFor(1)); t1.opened()
            #expect(await eventually { idle.pending == 1 })
            #expect(idle.requested == [.seconds(240)])
            idle.fire()
            let t2 = try #require(await transports.waitFor(2))
            #expect(t1.closed)
            #expect(t2 !== t1)
            #expect(clock.slept.isEmpty, "an idle reconnect is deliberate, not a failure to back off from")
            #expect(errors.value == 0)
            #expect(client.diagnostics.idleReconnects == 1)
        }

        @Test("Z2: every received frame re-arms the guard")
        func framesRearm() async throws {
            let transports = FakeTransportFactory()
            let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, idleReconnectThreshold: .seconds(240))
            client.advertiseForTesting("a")
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { idle.requested.count == 1 })
            t.frame(#"{"classification":"custom","action":"a"}"#)
            #expect(await eventually { idle.requested.count == 2 })
            #expect(idle.pending == 1)
            #expect(!t.closed)
        }

        @Test("Z3: the guard is disarmed by disconnect and never fires on a closed socket")
        func disarmedOnDisconnect() async throws {
            let transports = FakeTransportFactory()
            let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, idleReconnectThreshold: .seconds(240))
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { idle.pending == 1 })
            client.disconnect()
            #expect(await eventually { idle.pending == 0 })
            idle.fire()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(transports.count == 1)
            #expect(client.diagnostics.idleReconnects == 0)
        }

        @Test("Z4: nil threshold disables the guard")
        func disabled() async throws {
            let transports = FakeTransportFactory()
            let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, idleReconnectThreshold: nil)
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(idle.requested.isEmpty)
        }
    }
}

// MARK: - Core session scaffolding for the seam tests

/// Minimal `ContactTransport`: connects on demand, lets the test push events.
actor StubContactTransport: ContactTransport {
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var buffered: [TransportEvent] = []

    nonisolated var events: AsyncStream<TransportEvent> {
        AsyncStream { cont in Task { await self.attach(cont) } }
    }
    private func attach(_ cont: AsyncStream<TransportEvent>.Continuation) {
        continuation?.finish()
        continuation = cont
        for e in buffered { cont.yield(e) }
        buffered.removeAll()
    }
    func connect(credentials: any ExpiringCredentials) async throws { push(.connected) }
    func send(_ message: OutboundMessage) async throws {}
    func disconnect() async { continuation?.finish(); continuation = nil }
    func push(_ e: TransportEvent) {
        if let continuation { continuation.yield(e) } else { buffered.append(e) }
    }
}

struct StubBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        ChatContactCredentials(contactID: "c-\(UUID().uuidString.prefix(8))", participantID: "p", participantToken: "t", expiresAt: nil)
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        throw TouchpointError.invalidConfiguration("no voice")
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        LiveSyncCredentials(deploymentKey: "d", apiKey: "k", expiresAt: nil)
    }
}

@MainActor
func makeCoreSession(transport: StubContactTransport) async throws -> TouchpointSession {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-ls-sess-\(UUID().uuidString)")
    let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
    let broker = CredentialBroker(backend: StubBackend(), keychain: InMemoryKeychainStore())
    return TouchpointSession(broker: broker, store: store, transports: [.chat: transport],
                             reconnection: .init(maxAttempts: 2, totalBudget: .seconds(5), initialDelay: .milliseconds(10), maxDelay: .milliseconds(20), jitterFactor: 0))
}
