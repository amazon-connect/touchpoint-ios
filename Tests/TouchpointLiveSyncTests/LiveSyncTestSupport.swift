import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

/// Every suite that records into the process-wide `StubURLProtocol` is nested under this one
/// serialised parent (as extensions, across files), so Swift Testing runs them one at a time. Two
/// separate `.serialized` parents would still run in parallel with each other.
@Suite("Live Sync (shared URL stub)", .serialized)
struct LiveSyncStubBackedSuites {}

/// Scripted socket. One `FakeTransport` per `open`; the factory records them so a test can drive the
/// n-th connection and assert how many were made.
final class FakeTransport: LiveSyncTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<LiveSyncTransportEvent>.Continuation?
    private var _request: URLRequest?
    private var _closed = false
    private var _terminationError: LiveSyncError?

    var request: URLRequest? { lock.withLock { _request } }
    var closed: Bool { lock.withLock { _closed } }
    var terminationError: LiveSyncError? { lock.withLock { _terminationError } }

    func open(request: URLRequest) -> AsyncStream<LiveSyncTransportEvent> {
        let (stream, c) = AsyncStream<LiveSyncTransportEvent>.makeStream(bufferingPolicy: .unbounded)
        lock.withLock { _request = request; continuation = c }
        return stream
    }

    func close() {
        let c: AsyncStream<LiveSyncTransportEvent>.Continuation? = lock.withLock { _closed = true; defer { continuation = nil }; return continuation }
        c?.finish()
    }

    // Scripting
    func opened() { lock.withLock { continuation }?.yield(.opened) }
    func frame(_ text: String) { lock.withLock { continuation }?.yield(.text(text)) }
    /// The socket ends on its own — the server closed it, or it failed.
    func end(error: LiveSyncError? = nil) {
        let c: AsyncStream<LiveSyncTransportEvent>.Continuation? = lock.withLock { _terminationError = error; defer { continuation = nil }; return continuation }
        c?.finish()
    }
}

final class FakeTransportFactory: LiveSyncTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [FakeTransport] = []
    var made: [FakeTransport] { lock.withLock { _made } }
    var count: Int { made.count }
    var latest: FakeTransport? { made.last }

    func makeTransport() -> any LiveSyncTransport {
        let t = FakeTransport()
        lock.withLock { _made.append(t) }
        return t
    }

    /// Waits for the n-th connection attempt (1-based) to have been opened.
    @MainActor
    func waitFor(_ n: Int, timeout: Duration = .seconds(2)) async -> FakeTransport? {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let m = made
            if m.count >= n, m[n - 1].request != nil { return m[n - 1] }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }
}

/// Vends whatever it is told, counts invalidations, and can fail.
actor FakeCredentialSource: LiveSyncCredentialSource {
    var queue: [LiveSyncCredentials]
    var current: LiveSyncCredentials
    var vends = 0
    var invalidations = 0
    var failure: TouchpointError?

    init(deploymentKey: String = "deployment-key", apiKey: String = "test-api-key-placeholder") {
        current = LiveSyncCredentials(deploymentKey: deploymentKey, apiKey: apiKey, expiresAt: nil)
        queue = []
    }

    var delay: Duration = .zero
    func delayNextVend(_ d: Duration) { delay = d }

    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        vends += 1
        if delay > .zero { let d = delay; delay = .zero; try? await Task.sleep(for: d) }   // not cancellation-aware, like the broker
        if let failure { throw failure }
        if !queue.isEmpty { current = queue.removeFirst() }
        return current
    }

    func invalidateLiveSyncCredentials() async { invalidations += 1 }

    func rotate(to apiKey: String) { queue.append(LiveSyncCredentials(deploymentKey: current.deploymentKey, apiKey: apiKey, expiresAt: nil)) }
    func setDeploymentKey(_ k: String) {
        current = LiveSyncCredentials(deploymentKey: k, apiKey: current.apiKey, expiresAt: nil)
        queue = queue.map { LiveSyncCredentials(deploymentKey: k, apiKey: $0.apiKey, expiresAt: nil) }
    }
    func fail(_ e: TouchpointError?) { failure = e }
}

/// A clock the backoff sleeps on, so tests never wait real time.
final class ManualClock: LiveSyncSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var _slept: [Duration] = []
    var slept: [Duration] { lock.withLock { _slept } }
    func sleep(for duration: Duration) async throws {
        lock.withLock { _slept.append(duration) }
        try Task.checkCancellation()
    }
}

/// A sleeper that suspends until cancelled or explicitly fired. The idle guard sleeps on this so a
/// test decides when "four minutes of silence" have passed.
final class HeldClock: LiveSyncSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var _requested: [Duration] = []
    var requested: [Duration] { lock.withLock { _requested } }
    var pending: Int { lock.withLock { waiters.count } }

    func sleep(for duration: Duration) async throws {
        lock.withLock { _requested.append(duration) }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.withLock { waiters[id] = c }
            }
        } onCancel: {
            // Only this sleep. Cancelling every waiter tore down a *newer* timer the aggregator had
            // just armed, and the debounce never fired (D1 flake).
            let w = lock.withLock { waiters.removeValue(forKey: id) }
            w?.resume(throwing: CancellationError())
        }
    }

    /// Lets every pending sleep elapse.
    func fire() {
        let ws = lock.withLock { let w = Array(waiters.values); waiters = [:]; return w }
        for w in ws { w.resume() }
    }
}

@MainActor
func makeTestClient(
    credentials: FakeCredentialSource = FakeCredentialSource(),
    transports: FakeTransportFactory = FakeTransportFactory(),
    consent: ConsentDecision = .granted,
    reconnection: ReconnectionPolicy = .default,
    session: URLSession = StubURLProtocol.makeSession(),
    clock: any LiveSyncSleeping = ManualClock(),
    idleClock: any LiveSyncSleeping = HeldClock(),
    idleReconnectThreshold: Duration? = nil,
    staleContactThreshold: Duration? = nil,
    configuration: LiveSyncConfiguration? = nil
) throws -> LiveSyncClient {
    let config = try configuration ?? LiveSyncConfiguration(
        region: "us-west-2",
        conversationId: "4411ca47-96d8-4bc8-88d8-1b7a6a1dcd98",
        channel: LiveSyncChannel(locale: Locale(identifier: "en_US")))
    return LiveSyncClient(configuration: config, credentials: credentials, consent: consent,
                          reconnection: reconnection, autoConnect: false,
                          urlSession: session, transports: transports, clock: clock,
                          idleClock: idleClock, idleReconnectThreshold: idleReconnectThreshold,
                          staleContactThreshold: staleContactThreshold)
}

@MainActor
func eventually(_ timeout: Duration = .seconds(2), _ cond: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

/// Mutable capture box for assertions made from `@MainActor` handlers.
@MainActor
final class Capture<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

extension LiveSyncChannel {
    /// Only for the inherited tests' configuration helper, which cannot `try`.
    static var fallbackForTests: LiveSyncChannel {
        // en_US always maps; the force is confined to test code and the failure would be loud.
        try! LiveSyncChannel(locale: Locale(identifier: "en_US"))
    }
}

extension LiveSyncClient {
    /// Tests about dispatch rather than validation: advertise `names` with an open object schema, so
    /// their frames reach the dispatch path (the client rejects un-advertised actions).
    func advertiseForTesting(_ names: String...) {
        adoptAdvertisedContext(LiveSyncContext(actions: names.map { LiveSyncAction($0, description: $0, schema: ["type": "object"]) }))
    }
}
