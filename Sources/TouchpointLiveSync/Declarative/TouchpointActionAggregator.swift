import Foundation
import Observation

/// Turns the stream of action sets the view tree reports into context posts, and routes incoming
/// invocations to the handler that declared them.
///
/// **Debounce.** A navigation produces a burst of preference updates (the old screen's actions
/// vanish, the new screen's appear, a few re-renders settle). The first change starts a 50 ms
/// timer; every further change restarts it; the post goes out when the tree has been quiet for 50 ms
/// **or** 300 ms after the first change, whichever comes first — so a tree that never settles still
/// advertises something. The values are the one prior art's defaults and are a starting point to be
/// measured, not a validated optimum.
///
/// **Diff by content.** A set whose fingerprint equals the last one advertised is ignored before
/// any timer starts, so re-renders with unchanged content, and view-identity churn that recreates
/// closures, never post (and never reset the timer).
@MainActor
@Observable
public final class TouchpointActionAggregator {
    /// What the tree currently declares (the last set reported, debounced or not).
    public private(set) var current = TouchpointActionSet()
    /// What was last advertised to the engine.
    public private(set) var advertised = TouchpointActionSet()
    /// The most recent invocation routed, for the debug overlay.
    public private(set) var lastInvocation: LiveSyncActionInvocation?
    /// Contexts posted so far.
    public private(set) var postCount = 0
    /// Unknown-name invocations that reached this aggregator (the advertised context is stale or
    /// the name is misspelled at one end).
    public private(set) var unroutedInvocations = 0
    /// Invocations handed to a declared handler that accepted them. Observable, so a host can react
    /// to the assistant acting on the app — get the chat out of the way of the screen it changed.
    public private(set) var routedInvocations = 0

    public let debounce: Duration
    public let maxWait: Duration

    private let post: @MainActor (LiveSyncContext) async throws -> Void
    private let report: @MainActor (LiveSyncError) -> Void
    /// Pushes confirmation requirements to the bound client whenever the advertised set changes. A
    /// no-op for the client-less inits — a multi-client or imperative host sets
    /// `client.confirmationRequirements` itself, the same way it sets `onAction`.
    private var syncConfirmations: @MainActor (TouchpointActionSet) -> Void = { _ in }
    private let clock: any LiveSyncSleeping
    private var timer: Task<Void, Never>?
    private var burstStartedAt: ContinuousClock.Instant?
    private var pendingFingerprint: Set<TouchpointActionDeclaration.Fingerprint>?
    private var inFlight: Task<Void, Never>?

    /// - Parameters:
    ///   - post: where contexts go — `client.sendContext(_:)` in production.
    ///   - report: where failures go — `client.onError` in production.
    init(
        debounce: Duration = .milliseconds(50),
        maxWait: Duration = .milliseconds(300),
        clock: any LiveSyncSleeping = ContinuousClockSleeper(),
        report: @escaping @MainActor (LiveSyncError) -> Void = { _ in },
        post: @escaping @MainActor (LiveSyncContext) async throws -> Void
    ) {
        self.debounce = debounce
        self.maxWait = maxWait
        self.clock = clock
        self.report = report
        self.post = post
    }

    /// Binds the aggregator to a client: contexts go to `sendContext`, failures to `onError`, and
    /// the client's `onAction` is routed through the declared handlers.
    public convenience init(client: LiveSyncClient, debounce: Duration = .milliseconds(50), maxWait: Duration = .milliseconds(300)) {
        self.init(debounce: debounce, maxWait: maxWait, clock: ContinuousClockSleeper(),
                  report: { [weak client] in client?.onError?($0) },
                  post: { [weak client] in try await client?.sendContext($0) })
        client.onAction = { [weak self] invocation in try self?.route(invocation) }
        // Keep the client's confirmation gate in step with the view tree: whichever actions declare
        // `confirmationRequired` are the ones the client holds for the user.
        syncConfirmations = { [weak client] set in client?.confirmationRequirements = set.confirmationRequirements }
        client.confirmationRequirements = current.confirmationRequirements
        // Consent re-granted after a denial cleared the client's context: advertise the screen again.
        client.onContextNeeded = { [weak self] in self?.readvertise() }
    }

    /// An aggregator that outlives any one client — for a host that creates a client per contact
    /// but has one view tree. `post` forwards to whichever client is current; the host sets that
    /// client's `onAction` to `route(_:)`. `report` receives post failures. `confirmations` receives
    /// the `confirmationRequired` actions on every advertise: forward it to the current
    /// client's ``LiveSyncClient/confirmationRequirements``, or a gated action runs unconfirmed.
    public convenience init(
        debounce: Duration = .milliseconds(50),
        maxWait: Duration = .milliseconds(300),
        report: @escaping @MainActor (LiveSyncError) -> Void = { _ in },
        confirmations: @escaping @MainActor ([String: LiveSyncClient.ActionConfirmation]) -> Void = { _ in },
        post: @escaping @MainActor (LiveSyncContext) async throws -> Void
    ) {
        self.init(debounce: debounce, maxWait: maxWait, clock: ContinuousClockSleeper(), report: report, post: post)
        syncConfirmations = { confirmations($0.confirmationRequirements) }
    }

    /// Re-advertises the current set to a new destination — call after the client behind `post`
    /// changed, so the new socket gets the screen already on show, and after consent is re-granted
    /// on a client this aggregator is not bound to. Required: a client rejects every invocation of an
    /// action it has not been told about.
    public func readvertise() {
        pendingFingerprint = current.fingerprint
        advertised = TouchpointActionSet()
        flushNow()
    }

    /// The view tree reported a new set. Called on every preference change.
    public func update(_ set: TouchpointActionSet) {
        current = set
        let fingerprint = set.fingerprint
        // Unchanged against what is advertised (or already queued): nothing to do, and the timer is
        // not touched — identity churn must not keep postponing a real change. A revert to the
        // advertised set while a change is queued records the revert; the flush then posts nothing.
        if fingerprint == (pendingFingerprint ?? advertised.fingerprint) { return }
        pendingFingerprint = fingerprint
        scheduleFlush()
    }

    /// Posts whatever is pending now, cancelling the debounce. Used when the host knows the tree
    /// has settled (and by tests).
    public func flushNow() {
        timer?.cancel(); timer = nil
        burstStartedAt = nil
        guard let pending = pendingFingerprint else { return }
        pendingFingerprint = nil
        // A change reverted within the window nets to nothing: do not re-post what the engine has.
        guard pending != advertised.fingerprint else { return }
        let set = current
        advertised = set
        syncConfirmations(set)
        postCount += 1
        let previous = inFlight
        inFlight = Task { @MainActor [post, report] in
            await previous?.value
            do { try await post(set.context) }
            catch let e as LiveSyncError { report(e) }
            catch { report(.requestFailed(description: LiveSyncError.describe(error))) }
        }
    }

    /// Hands an invocation to the declared handler. Throws `actionHandlerFailed` through the client
    /// for handler and decode errors; counts unknown names and reports them as a diagnostic error.
    public func route(_ invocation: LiveSyncActionInvocation) throws {
        lastInvocation = invocation
        // Route against what is *advertised*, not what the tree shows this instant: the engine acted
        // on the context it was given. If the tree has moved on the action is still honoured by the
        // handler that promised it, and the next post corrects the engine.
        guard let declaration = advertised[invocation.action] ?? current[invocation.action] else {
            unroutedInvocations += 1
            report(.actionHandlerFailed(action: invocation.action, description: "no declared action with this name"))
            return
        }
        try declaration.handler(invocation.payload)
        routedInvocations += 1
    }

    private func scheduleFlush() {
        let now = ContinuousClock.now
        let started = burstStartedAt ?? now
        burstStartedAt = started
        let ceilingRemaining = maxWait - started.duration(to: now)
        let wait = min(debounce, max(.zero, ceilingRemaining))
        timer?.cancel()
        timer = Task { @MainActor [weak self, clock] in
            do { try await clock.sleep(for: wait) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.flushNow()
        }
    }
}
