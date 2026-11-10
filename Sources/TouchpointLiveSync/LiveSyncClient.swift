import Foundation
import TouchpointCore
#if canImport(UIKit)
import UIKit
#endif

/// State of the action socket.
public enum LiveSyncConnectionState: Sendable, Equatable {
    /// Created but not connected yet.
    case idle
    /// The first connection attempt is in flight.
    case connecting
    /// Connected; invocations are flowing and context is being delivered.
    case connected
    /// The socket dropped and is being reopened; `attempt` counts consecutive failures.
    case reconnecting(attempt: Int)
    /// Closed, either by ``LiveSyncClient/disconnect()`` or because retries were exhausted.
    case disconnected
}

/// Keeps the app's state in sync with a parallel voice conversation.
///
/// A client opens a receive-only WebSocket to the Live Sync backend for one Amazon Connect contact,
/// tells the conversation engine what the app can currently do via ``sendContext(_:)``, and calls
/// ``onAction`` whenever the customer asks for one of those things out loud.
///
/// The client is isolated to the main actor, so ``onAction`` can mutate view state directly without
/// hopping actors:
///
/// ```swift
/// let client = LiveSyncClient(
///     configuration: LiveSyncConfiguration(
///         region: "us-west-2",
///         conversationId: contactId,
///         channel: try LiveSyncChannel(locale: .current)
///     ),
///     credentials: broker,          // a CredentialBroker; keys are fetched per connection
///     consent: .held,               // nothing is posted until the customer grants it
///     autoConnect: false
/// )
///
/// // Only advertised actions reach `onAction`, each payload checked against its schema.
/// try await client.sendContext(actions: [
///     LiveSyncAction("set_contact_info", description: "Fill in the contact form", schema: ContactInfo.schema),
/// ])
/// client.onAction = { invocation in
///     switch invocation.action {
///     case "set_contact_info":
///         let contact = try invocation.decode(ContactInfo.self)
///         model.fullName = contact.fullName
///         model.email = contact.email
///     default:
///         break
///     }
/// }
/// client.connect()
///
/// await client.setConsent(.granted)      // from the consent sheet
/// ```
///
/// Context is normally advertised through the declarative layer; `sendContext` is the
/// lower-level escape hatch.
///
/// Call ``disconnect()`` when the screen goes away; the socket is otherwise closed when the client is
/// deallocated.
@MainActor
public final class LiveSyncClient: LiveSyncControl {
    /// Connection details this client was created with.
    public let configuration: LiveSyncConfiguration

    /// Current state of the action socket.
    public private(set) var connectionState: LiveSyncConnectionState = .idle {
        didSet {
            guard connectionState != oldValue else { return }
            onConnectionStateChange?(connectionState)
        }
    }

    /// Called whenever ``connectionState`` changes.
    public var onConnectionStateChange: (@MainActor (LiveSyncConnectionState) -> Void)?

    /// Called on the main actor for every action the conversation engine invokes.
    ///
    /// This is the single place where the app decides what an action does. Switch on
    /// ``LiveSyncActionInvocation/action`` and read the payload. Only actions in the context last
    /// advertised (``sendContext(_:)``) arrive here, each with a payload already checked on the
    /// device against the schema you declared; anything else is rejected first and reported as
    /// ``LiveSyncError/invalidPayload(action:description:)``. Keep a `default` case anyway, and check
    /// business rules (an amount's ceiling, an id that must exist) in the handler:
    ///
    /// ```swift
    /// client.onAction = { [weak self] invocation in
    ///     guard let self else { return }
    ///     switch invocation.action {
    ///     case "set_contact_info":
    ///         apply(try invocation.decode(ContactInfo.self))
    ///     case "search_flights":
    ///         searchFlights()
    ///     default:
    ///         logger.warning("Unknown Live Sync action \(invocation.action)")
    ///     }
    /// }
    /// ```
    ///
    /// Errors thrown here — a payload that does not match the model, a validation failure of your own
    /// — are reported to ``onError`` as
    /// ``LiveSyncError/actionHandlerFailed(action:description:)`` and never interrupt the socket.
    public var onAction: (@MainActor (LiveSyncActionInvocation) throws -> Void)?

    /// Called for socket failures, unparseable frames, and errors thrown by ``onAction``. Recoverable
    /// failures are reported here rather than thrown, because they happen outside any call the app
    /// made.
    public var onError: (@MainActor (LiveSyncError) -> Void)?

    /// Called for every `navigation` frame. These arrive whether or not the app
    /// advertised destinations, so an app that does not navigate on the assistant's behalf can leave
    /// this `nil`; the frame is then counted in ``diagnostics`` and otherwise ignored.
    public var onNavigation: (@MainActor (LiveSyncNavigation) -> Void)?

    /// Called whenever ``dispatchState`` changes — on agent join/leave via the session, or on
    /// explicit calls. Never silent.
    public var onDispatchStateChange: (@MainActor (DispatchState, DispatchChangeReason?) -> Void)?

    /// Whether invocations reach ``onAction`` right now. Suspended while a human agent is on
    /// the contact, and from a cold resume until the transcript is reconciled. An invocation that
    /// arrives while suspended is dropped and counted; one already inside ``onAction`` completes.
    public private(set) var dispatchState: DispatchState = .enabled

    /// Counters for what the client saw but did not act on. Diagnostic, not an API contract.
    public struct Diagnostics: Sendable, Equatable {
        /// `input` frames, which cannot be acted on while nothing advertises fields.
        public var droppedInputFrames = 0
        /// `navigation` frames received while ``LiveSyncClient/onNavigation`` was `nil`.
        public var unhandledNavigationFrames = 0
        /// Invocations that arrived while dispatch was suspended.
        public var suppressedInvocations = 0
        /// Lines the assistant spoke, delivered on the action socket. Informational.
        public var noteFrames = 0
        /// Times the idle guard closed a socket that had gone quiet past the lease threshold.
        public var idleReconnects = 0
        /// Times the stale-contact diagnostic fired.
        public var staleContactWarnings = 0
        /// Confirmation-required invocations that did not run: the user cancelled, a second one
        /// arrived while one was pending, or — while one was pending — dispatch was suspended (a
        /// human agent joined, or the session is reconciling after a reconnect), its action left the
        /// screen, the contact ended or consent was revoked.
        public var declinedConfirmations = 0
        /// Invocations rejected on the device before any handler: an action not advertised, or a
        /// payload that does not match its declared schema.
        public var rejectedInvocations = 0
    }
    public private(set) var diagnostics = Diagnostics()

    // MARK: - Action confirmation

    /// Metadata for an action that must be confirmed before its handler runs. The declarative layer
    /// keeps ``confirmationRequirements`` in step with the visible view tree; an imperative host
    /// (one that sets ``onAction`` directly, with no declarative tree to read from) sets the map
    /// itself to opt an action into the same gate.
    public struct ActionConfirmation: Sendable, Equatable {
        /// Human-readable description of the action, shown in the prompt body when `message` is nil.
        public var actionDescription: String?
        /// A host-supplied prompt body that overrides ``actionDescription``.
        public var message: String?
        public init(actionDescription: String? = nil, message: String? = nil) {
            self.actionDescription = actionDescription
            self.message = message
        }
    }

    /// Advertised actions that require user confirmation before dispatch, keyed by action name. The
    /// declarative `TouchpointActionAggregator` keeps this current from `confirmationRequired`
    /// declarations; set it directly on the imperative path.
    public var confirmationRequirements: [String: ActionConfirmation] = [:] {
        didSet {
            // The held action is no longer declared as needing confirmation — most often its screen
            // went away (the aggregator re-syncs this map on every advertise): the prompt is stale,
            // so it is declined rather than left to be confirmed for a screen that is gone.
            if let held = heldInvocation, confirmationRequirements[held.action] == nil { declinePendingConfirmation() }
        }
    }

    /// A confirmation awaiting the user's decision, or `nil`. Non-nil while a prompt should be on
    /// screen: the SwiftUI `.touchpointActionConfirmation` modifier presents it, or an imperative
    /// host observes ``onPendingConfirmationChange`` and presents its own UI, then calls
    /// ``confirmPendingAction()`` or ``cancelPendingAction()``.
    public struct PendingConfirmation: Identifiable, Sendable, Equatable {
        public let id: UUID
        /// The action name, matching ``LiveSyncActionInvocation/action``.
        public let action: String
        /// The declared human-readable description, for the prompt body.
        public let actionDescription: String?
        /// A host-supplied prompt body, if one was set on the declaration or requirement.
        public let message: String?
    }

    /// The confirmation awaiting a decision, or `nil`. Only one is ever held at a time (see
    /// ``dispatch(_:)``).
    public private(set) var pendingConfirmation: PendingConfirmation?
    /// Called whenever ``pendingConfirmation`` changes, so a non-SwiftUI host can drive its own UI.
    /// The `.touchpointActionConfirmation` modifier owns this callback when it is applied.
    public var onPendingConfirmationChange: (@MainActor (PendingConfirmation?) -> Void)?
    /// The invocation held behind ``pendingConfirmation``: delivered on confirm, dropped on cancel.
    private var heldInvocation: LiveSyncActionInvocation?
    // No standalone confirmation timeout: the protocol has no invocation timeout to mirror, and a
    // pending confirmation cannot outlive the contact — it is dropped (and counted) on `teardown()`
    // and on consent revocation. A host that wants a deadline calls `cancelPendingAction()` from its
    // own timer.

    /// Runs the held action's handler and clears the prompt. No-op when nothing is pending. Declines
    /// instead if dispatch was suspended meanwhile, and rejects it (``LiveSyncError/invalidPayload(action:description:)``)
    /// if it no longer matches what is advertised.
    public func confirmPendingAction() {
        guard let invocation = heldInvocation else { return }
        guard dispatchState == .enabled else {
            declinePendingConfirmation()
            return
        }
        // Re-checked against what is advertised now: the screen may have moved on, or re-advertised
        // the same name with a tighter schema, while the prompt was up. A rejection, not a decline:
        // the customer allowed it.
        if let problem = payloadProblem(invocation) {
            clearPendingConfirmation()
            diagnostics.rejectedInvocations += 1
            report(.invalidPayload(action: Self.reportableName(invocation.action), description: problem))
            return
        }
        clearPendingConfirmation()
        deliver(invocation)
    }

    /// Drops the held action without running its handler, reports it to the host through ``onError``,
    /// and counts it. No-op when nothing is pending. (The assistant is not told: the action socket is
    /// receive-only.)
    public func cancelPendingAction() {
        declinePendingConfirmation()
    }

    /// Shared decline path for a user cancel, a suspension, a screen change, a contact end, or a
    /// consent revocation while pending.
    private func declinePendingConfirmation() {
        guard let invocation = heldInvocation else { return }
        clearPendingConfirmation()
        diagnostics.declinedConfirmations += 1
        // The action socket is receive-only (context is POSTed, nothing is sent back on the wire),
        // so the decline reaches the host only, through the same `onError` / `actionHandlerFailed`
        // surface a failed action uses; the assistant is not told. The reason is deliberately
        // non-sensitive and Android's.
        report(.actionHandlerFailed(action: invocation.action, description: "declined by user"))
    }

    private func clearPendingConfirmation() {
        heldInvocation = nil
        pendingConfirmation = nil
        onPendingConfirmationChange?(nil)
    }

    /// How long a connected socket may stay silent before the client assumes the backend's
    /// 300-second connection lease has lapsed and reconnects (the zombie socket).
    /// `nil` disables the guard. Must be below the lease window to be useful.
    public let idleReconnectThreshold: Duration?

    /// How long a connected socket with context posted may stay silent before
    /// ``LiveSyncError/contactMayBeStale(quietFor:)`` is reported. A stale `conversationId` yields a
    /// socket that connects and delivers nothing, for ever; this turns that silence into a
    /// diagnosable state. `nil` disables. Default 45 s: long enough for the assistant to finish its
    /// greeting, short enough to be useful during a call.
    public let staleContactThreshold: Duration?
    /// `true` once the diagnostic has fired for the current connection and no frame has arrived since.
    public private(set) var contactMayBeStale = false
    private var staleWatch: Task<Void, Never>?
    private var hasReceivedFrame = false

    private let urlSession: URLSession
    private let credentials: any LiveSyncCredentialSource
    private let transports: any LiveSyncTransportFactory
    private let clock: any LiveSyncSleeping
    private let idleClock: any LiveSyncSleeping
    private let socketHolder = SocketHolder()
    private var idleGuard: Task<Void, Never>?
    /// Set by the idle guard before it closes the socket: the loop reconnects at once rather than
    /// treating a deliberate close as a failure to back off from.
    private var idleReconnectPending = false

    /// After ``teardown()`` the client is finished: the contact has ended and nothing may reconnect.
    public private(set) var isTornDown = false
    /// Set by ``enterBackground()`` when a loop was running, so ``enterForeground()`` knows to resume.
    private var resumeOnForeground = false

    /// Backoff between reconnect attempts. `maxAttempts` caps the *exponent*, not the number of
    /// tries: Live Sync must never give up while the call may still be live, so after the cap every
    /// attempt waits the capped delay (plus one-sided jitter) and tries again.
    public let reconnection: ReconnectionPolicy

    /// The customer's consent decision. Every context POST is gated on `.granted`.
    public private(set) var consent: ConsentDecision
    private var reportedConsentDenied = false

    /// The last context advertised, re-posted on every (re)connection. Not because an unsubscribed POST
    /// is discarded — the backend keeps context ~300 s regardless of any socket — but because the
    /// re-post refreshes that lease, and because a command the assistant issues in reply needs a
    /// registered socket to land on (commands, unlike context, are dropped without one).
    private var advertisedContext = LiveSyncContext()
    private var hasContextToSend = false
    /// Whether a context is held and not yet posted. Exposed for tests of the consent gate.
    var hasPendingContext: Bool { hasContextToSend }

    /// Set by a 401/403 (socket handshake or context POST): the running loop invalidates the key and
    /// backs off *in place* rather than tearing itself down and restarting — the restart path reset
    /// the attempt counter and could spin against a backend that keeps refusing the key.
    private var authFailed = false
    /// Consecutive 401/403s on the **context POST**. A socket can open with a key the context
    /// API refuses — the wrong kind of key, say — and each refusal re-vends and reconnects; a
    /// `.text` frame on the freshly opened socket resets `attempt`, so without this the cycle would
    /// repeat at the first-retry delay, at network speed. It floors the backoff exponent until a
    /// POST succeeds, and is reset only then.
    private var authFailures = 0
    /// Context POSTs run here, serialised and off the socket loop, so a slow POST never holds up
    /// frame dispatch and two posts cannot land out of order (the last one wins the 300 s lease).
    private var contextPost: Task<Void, Never>?
    private var socketLoop: Task<Void, Never>?
    /// Which loop is current. `runSocket` clears `socketLoop` on the way out only if it is still its
    /// own — the defect the proof of concept had was a loop that ended on its own and left the slot
    /// occupied, making every later `connect()` a silent no-op.
    private var loopGeneration = 0
    private var isConnected = false
    private var invocationObservers: [UUID: AsyncStream<LiveSyncActionInvocation>.Continuation] = [:]

    /// Creates a client and, unless `autoConnect` is `false`, immediately opens the action socket.
    ///
    /// - Parameters:
    ///   - configuration: connection details for the Live Sync session.
    ///   - credentials: where the deployment and API keys come from — normally the `CredentialBroker`.
    ///     Consulted on every connection attempt, so a rotated key reaches the next socket.
    ///   - consent: the customer's decision. Defaults to held: nothing is posted until granted.
    ///   - reconnection: backoff between attempts; see `reconnection`.
    ///   - autoConnect: whether to open the socket right away. Pass `false` to defer to
    ///     ``connect()``, for instance to attach ``onAction`` first.
    ///   - session: the `TouchpointSession` running the contact, if any. Registers this client as the
    ///     session's `LiveSyncControl` so agent-presence gating and contact-end
    ///     teardown reach the socket. Without it the session's gating calls are no-ops.
    ///   - idleReconnectThreshold: see ``idleReconnectThreshold``. Default 4 minutes, under the
    ///     backend's 5-minute connection lease.
    ///   - staleContactThreshold: see ``staleContactThreshold``.
    public convenience init(
        configuration: LiveSyncConfiguration,
        credentials: any LiveSyncCredentialSource,
        consent: ConsentDecision = .default,
        reconnection: ReconnectionPolicy = .default,
        autoConnect: Bool = true,
        session: TouchpointSession? = nil,
        idleReconnectThreshold: Duration? = .seconds(240),
        staleContactThreshold: Duration? = .seconds(45)
    ) {
        self.init(configuration: configuration, credentials: credentials, consent: consent,
                  reconnection: reconnection, autoConnect: false,
                  urlSession: URLSession(configuration: .default),
                  transports: WebSocketTransportFactory(), clock: ContinuousClockSleeper(),
                  idleClock: ContinuousClockSleeper(), idleReconnectThreshold: idleReconnectThreshold,
                  staleContactThreshold: staleContactThreshold)
        if let session { attach(to: session) }
        observeApplicationLifecycle()
        if autoConnect { connect() }
    }

    init(
        configuration: LiveSyncConfiguration,
        credentials: any LiveSyncCredentialSource,
        consent: ConsentDecision,
        reconnection: ReconnectionPolicy,
        autoConnect: Bool,
        urlSession: URLSession,
        transports: any LiveSyncTransportFactory,
        clock: any LiveSyncSleeping,
        idleClock: (any LiveSyncSleeping)? = nil,
        idleReconnectThreshold: Duration? = nil,
        staleContactThreshold: Duration? = nil
    ) {
        self.configuration = configuration
        self.credentials = credentials
        self.consent = consent
        self.reconnection = reconnection
        self.urlSession = urlSession
        self.transports = transports
        self.clock = clock
        self.idleClock = idleClock ?? clock
        self.idleReconnectThreshold = idleReconnectThreshold
        self.staleContactThreshold = staleContactThreshold
        if autoConnect {
            connect()
        }
    }

    deinit {
        // Deallocation is a full teardown: the socket closes, and so does the idle guard.
        socketHolder.closeCurrent()
        idleGuard?.cancel()
        staleWatch?.cancel()
        lifecycleObservers.removeAll()
    }

    /// Notification tokens; removed when the client goes away.
    private let lifecycleObservers = ObserverTokens()

    /// Registers with the session as its `LiveSyncControl` and adopts the session's
    /// current gate, so a client created after a cold resume starts suspended rather than enabled.
    public func attach(to session: TouchpointSession) {
        session.register(liveSync: self)
        if session.dispatchState == .suspended {
            applyDispatch(.suspended, reason: session.dispatchReason)
        }
    }

    // MARK: - Lifecycle: the teardown model

    /// Background: a *resumable* disconnect. Context and handlers are kept; the socket is closed
    /// because iOS will suspend it anyway, and because the backend's connection lease lapses in the
    /// background regardless. ``enterForeground()`` reconnects and replays.
    public func enterBackground() {
        guard !isTornDown else { return }
        resumeOnForeground = socketLoop != nil
        disconnect()
    }

    /// Foreground: reconnect if the client was running when it went to the background. The replay
    /// of advertised context happens on `.opened`, through the consent gate. Dispatch is the
    /// session's decision (it suspends until the transcript is reconciled), not this call's.
    public func enterForeground() {
        guard !isTornDown, resumeOnForeground else { return }
        resumeOnForeground = false
        connect()
    }

    private func observeApplicationLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        lifecycleObservers.add(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterBackground() }
        })
        lifecycleObservers.add(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.enterForeground() }
        })
        #endif
    }

    // MARK: - Connection

    /// Opens the action socket. Does nothing when already connecting or connected, or after
    /// ``teardown()``.
    public func connect() {
        guard socketLoop == nil, !isTornDown else { return }
        loopGeneration &+= 1
        let generation = loopGeneration
        // The loop holds `self` weakly *between* events, not for its whole life: an `await
        // self?.runSocket()` would pin the client until the socket closed, and the socket only
        // closes in `deinit` — the leak the socket holder exists to prevent.
        socketLoop = Task { [weak self] in
            await LiveSyncClient.runSocketLoop(weak: WeakClient(self, generation: generation), generation: generation)
        }
    }

    /// `self` as the loop sees it: re-resolved at every step, so a deallocated client ends the loop.
    @MainActor
    private final class WeakClient: Sendable {
        weak var client: LiveSyncClient?
        /// Set when a step decided the loop must stop (configuration error, no retries).
        private(set) var stopped = false

        /// Builds the socket request. `nil` means "could not this time": `stopped` says whether to quit.
        func request(attempt: inout Int) async -> URLRequest? {
            guard let c = client else { stopped = true; return nil }
            do {
                return try await c.makeSocketRequest()
            } catch let error as LiveSyncError {
                guard let c = client else { stopped = true; return nil }
                c.report(error)
                // A configuration error cannot heal by waiting; a vend failure can.
                if case .invalidConfiguration = error {
                    c.connectionState = .disconnected
                    stopped = true
                    return nil
                }
                if !(await c.backOff(attempt: &attempt)) { stopped = true }
                return nil
            } catch {
                guard let c = client else { stopped = true; return nil }
                c.report(.socketFailure(description: LiveSyncError.describe(error)))
                if !(await c.backOff(attempt: &attempt)) { stopped = true }
                return nil
            }
        }

        func openTransport(request: URLRequest, attempt: Int) -> (any LiveSyncTransport, AsyncStream<LiveSyncTransportEvent>)? {
            // The credential fetch is not cancellation-aware (the broker awaits an unstructured
            // task), so a `disconnect()` or revocation that landed during it is only seen here.
            // Opening a socket now would leave one running that nothing closes.
            guard !Task.isCancelled, let c = client, c.loopGeneration == generation else { return nil }
            c.connectionState = attempt == 0 ? .connecting : .reconnecting(attempt: attempt)
            let transport = c.transports.makeTransport()
            c.socketHolder.set(transport)
            return (transport, transport.open(request: request))
        }

        /// Bookkeeping once the stream ended. `false` if the client is gone.
        func afterStream(_ transport: any LiveSyncTransport) -> Bool {
            guard let c = client else { return false }
            c.socketHolder.clear(transport)
            // Only the current loop owns the connection state: a superseded loop finishing late
            // must not overwrite what the new one has established.
            guard c.loopGeneration == generation else { return false }
            c.isConnected = false
            c.stopIdleGuard()
            c.stopStaleWatch()
            if !Task.isCancelled, let error = transport.terminationError {
                c.report(error)
                // A refused handshake means the key is dead: invalidate before the retry so the
                // next attempt vends afresh instead of retrying a revoked key for ever.
                if case .httpFailure(let status, _) = error, status == 401 || status == 403 { c.authFailed = true }
            }
            return true
        }

        func backOff(attempt: inout Int) async -> Bool {
            guard let c = client, c.loopGeneration == generation else { return false }
            return await c.backOff(attempt: &attempt)
        }

        let generation: Int
        init(_ c: LiveSyncClient?, generation: Int) { client = c; self.generation = generation }
    }

    /// Closes the action socket and stops reconnecting. The advertised context and ``onAction`` are
    /// kept, so a later ``connect()`` resumes where this left off.
    public func disconnect() {
        socketLoop?.cancel()
        socketLoop = nil
        contextPost?.cancel()
        contextPost = nil
        stopIdleGuard()
        stopStaleWatch()
        socketHolder.closeCurrent()
        isConnected = false
        connectionState = .disconnected
    }

    /// Full teardown: the contact has ended. Closes the socket, forgets the advertised context
    /// and handlers, and makes every later ``connect()`` a no-op. Not resumable — a new contact gets
    /// a new client. The session calls this through `LiveSyncControl` when the contact ends.
    public func teardown() async {
        isTornDown = true
        resumeOnForeground = false
        // A sensitive action still awaiting confirmation when the contact ends is dropped without
        // running — and counted, like a cancel. Done before `onAction` is cleared; `onError` stays
        // live through teardown, so the host still hears the decline.
        declinePendingConfirmation()
        disconnect()
        advertisedContext = LiveSyncContext()
        hasContextToSend = false
        onAction = nil
        onNavigation = nil
        for continuation in invocationObservers.values { continuation.finish() }
        invocationObservers = [:]
    }

    // MARK: - Dispatch gate

    /// Stops invocations reaching ``onAction``. Called by the session when a human agent joins, and
    /// on a cold resume until the transcript confirms who is on the contact. The socket stays open —
    /// the assistant may still be talking, and context keeps its lease — but nothing it says moves
    /// the app while a person is handling the customer.
    public func suspendDispatch(reason: DispatchChangeReason) async {
        applyDispatch(.suspended, reason: reason)
    }

    /// Lets invocations through again. Called by the session when the last human agent leaves or
    /// reconciliation finds none.
    public func resumeDispatch() async {
        applyDispatch(.enabled, reason: nil)
    }

    private func applyDispatch(_ state: DispatchState, reason: DispatchChangeReason?) {
        guard state != dispatchState else { return }
        // A sensitive action awaiting the customer's Allow must not run with a person on the
        // contact — or across any other suspension (a reconnect still reconciling): fail safe, as
        // Android does. Declined before the host hears of the suspension, so its UI never shows a
        // prompt for a gate that is already shut.
        if state == .suspended { declinePendingConfirmation() }
        dispatchState = state
        onDispatchStateChange?(state, reason)
    }

    /// Forces a fresh key: invalidates the source's cache and reconnects, because the key lives in
    /// the socket URL and cannot reach a live socket any other way. Call this when the host backend
    /// has rotated the Live Sync credentials; the next attempt vends anew.
    public func rotateCredentials() async {
        await credentials.invalidateLiveSyncCredentials()
        let wasRunning = socketLoop != nil
        disconnect()
        if wasRunning { connect() }
    }

    /// Records the customer's decision. Granting flushes any held context; denying closes the socket
    /// and clears what was advertised (revocation is immediate).
    public func setConsent(_ decision: ConsentDecision) async {
        guard decision != consent else { return }
        consent = decision
        reportedConsentDenied = false
        switch decision {
        case .granted:
            if isConnected { scheduleContextPost() }
            // A denial cleared what was advertised; nothing is held to post. Ask the declarative
            // layer for the screen's actions again — until then every invocation would be rejected
            // as not advertised.
            if !hasContextToSend { onContextNeeded?() }
        case .denied:
            advertisedContext = LiveSyncContext()
            hasContextToSend = false
            // Revocation is immediate: a sensitive action awaiting confirmation is dropped
            // (and counted) rather than left on screen to be confirmed after consent was withdrawn.
            declinePendingConfirmation()
            disconnect()
            // The host hears the decision's effect once, now — not on some later sendContext.
            reportedConsentDenied = true
            report(.consentNotGranted)
        case .held:
            break
        }
    }

    private static func runSocketLoop(weak: WeakClient, generation: Int) async {
        defer {
            // Only our own slot: a newer `connect()` may already own it.
            if let c = weak.client, c.loopGeneration == generation { c.socketLoop = nil }
        }
        var attempt = 0

        // Every strong reference to the client lives inside one of these helpers and is released
        // when it returns. Nothing strong survives across the `for await` on the socket stream, so a
        // client the host dropped deallocates — and `deinit` closes the socket — while connected.
        while !Task.isCancelled {
            guard let request = await weak.request(attempt: &attempt) else {
                if weak.client == nil || weak.stopped { return }
                continue
            }
            guard let (transport, stream) = weak.openTransport(request: request, attempt: attempt) else { return }

            for await event in stream {
                // Frames queued before a `disconnect()` must not reach the host after it.
                if Task.isCancelled { transport.close(); break }
                guard let c = weak.client else { transport.close(); return }
                switch event {
                case .opened:
                    c.isConnected = true
                    c.hasReceivedFrame = false
                    c.connectionState = .connected
                    c.scheduleContextPost()
                    c.restartIdleGuard()
                case .text(let text):
                    // The connection has proven itself only once something arrives on it. Resetting
                    // on `.opened` let a server that accepts the handshake and closes at once keep
                    // the client at the initial delay for ever.
                    attempt = 0
                    c.hasReceivedFrame = true
                    c.stopStaleWatch()
                    c.contactMayBeStale = false
                    c.restartIdleGuard()
                    c.ingest(text)
                }
            }

            guard weak.afterStream(transport) else { return }
            if Task.isCancelled { break }
            if let c = weak.client, c.authFailed {
                c.authFailed = false
                await c.credentials.invalidateLiveSyncCredentials()
            }
            if let c = weak.client, c.idleReconnectPending {
                // The idle guard closed a healthy-looking socket on purpose; reconnect straight away.
                c.idleReconnectPending = false
                attempt = 0
                continue
            }
            if !(await weak.backOff(attempt: &attempt)) { break }
        }

        if let c = weak.client, c.loopGeneration == generation { c.connectionState = .disconnected }
    }

    /// Waits out the backoff for the next attempt. Returns `false` only when the loop should stop:
    /// the task was cancelled, or the policy allows no retries at all (`maxAttempts == 0`, which the
    /// tests use to make the loop end on its own). Otherwise Live Sync keeps trying for ever, at the
    /// capped delay — a dropped socket must not end the assistant's ability to help while the call
    /// is still going.
    private func backOff(attempt: inout Int) async -> Bool {
        guard reconnection.maxAttempts > 0 else { return false }
        attempt += 1
        connectionState = .reconnecting(attempt: attempt)
        // Floor the exponent by the consecutive context-POST refusal count: a frame arriving
        // on a socket the context API then refuses must not let the next attempt fire at the fast
        // initial delay. A successful POST clears `authFailures`.
        let delay = reconnection.delay(forAttempt: min(max(attempt, authFailures), reconnection.maxAttempts))
        do {
            try await clock.sleep(for: delay)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    func makeSocketRequest() async throws -> URLRequest {
        let creds = try await vendCredentials()
        try configuration.validate(credentials: creds)
        var request = URLRequest(url: try configuration.socketURL(credentials: creds))
        // `Sec-WebSocket-*` headers are owned by URLSession and must not be set here. No `Origin`:
        // the proof of concept sent a hardcoded one that the backend never required.
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private func vendCredentials() async throws -> LiveSyncCredentials {
        do {
            return try await credentials.liveSyncCredentials()
        } catch let error as TouchpointError {
            // Case name only. The broker passes host-thrown errors through, and a host's
            // `httpFailure` body or `transportFailure` text is not ours to surface.
            throw LiveSyncError.credentialVendingFailed(description: String(String(describing: error).prefix { $0 != "(" }))
        } catch {
            throw LiveSyncError.credentialVendingFailed(description: LiveSyncError.describe(error))
        }
    }

    // MARK: - Context

    /// Advertises what the app can currently do.
    ///
    /// The context replaces whatever was advertised before rather than merging into it: pass the full
    /// set of actions for the app's current state on every call. Handling stays in ``onAction``, which
    /// survives across contexts.
    ///
    /// When the socket is not yet open the context is stored and posted as soon as it connects — the
    /// backend discards context for a contact that has no subscriber — so this returns without
    /// performing a request in that case.
    ///
    /// - Throws: ``LiveSyncError`` when the request fails or is rejected.
    ///
    /// This is the imperative, lower-level call. The declarative `.touchpointAction` modifier is
    /// the surface most hosts should use; this stays public as the documented escape hatch for a host
    /// whose view tree cannot express its actions declaratively.
    public func sendContext(_ context: LiveSyncContext) async throws {
        advertisedContext = context
        hasContextToSend = true
        reportUnusableSchemas(in: context)
        guard consentAllowsPosting() else { return }
        guard isConnected else { return }
        // One serialised path for every POST — this call and the on-open replay — so two contexts
        // cannot land out of order and leave the older one owning the 300 s lease. The caller still
        // hears this post's outcome.
        let previous = contextPost
        let post = Task { @MainActor [weak self] () throws -> Void in
            await previous?.value                         // a superseded post finishes or is cancelled first
            guard let self else { return }
            do {
                try await self.postContext()
                self.armStaleWatch()
            } catch let error as LiveSyncError {
                if case .httpFailure(let status, _) = error, status == 401 || status == 403 {
                    self.authFailed = true
                    self.socketHolder.closeCurrent()
                }
                throw error
            }
        }
        contextPost = Task { _ = try? await post.value }
        try await post.value
    }

    /// The consent gate. `.denied` is reported once per decision rather than on every call,
    /// since the host already knows and the user has already answered.
    private func consentAllowsPosting() -> Bool {
        switch consent {
        case .granted: return true
        case .held: return false
        case .denied:
            if !reportedConsentDenied { reportedConsentDenied = true; report(.consentNotGranted) }
            return false
        }
    }

    /// Advertises what the app can currently do, without building a ``LiveSyncContext`` first.
    ///
    /// - Parameters:
    ///   - scopes: scope tags for the current app state, passed through to the engine so it can
    ///     narrow the available actions. Omitted from the request when `nil`.
    ///   - actions: the full set of actions the assistant may invoke. Replaces the previously
    ///     advertised set.
    public func sendContext(
        scopes: [String]? = nil,
        actions: [LiveSyncAction] = []
    ) async throws {
        try await sendContext(LiveSyncContext(actions: actions, scopes: scopes))
    }

    /// Posts the pending context from its own task, replacing any post still in flight: the newest
    /// context is the one that must own the 300 s lease, and the socket loop must not wait on it.
    private func scheduleContextPost() {
        guard hasContextToSend, consentAllowsPosting() else { return }
        let previous = contextPost
        contextPost = Task { @MainActor [weak self] in
            await previous?.value                         // serialised behind any in-flight post
            await self?.sendPendingContext()
        }
    }

    private func sendPendingContext() async {
        guard hasContextToSend, consentAllowsPosting() else { return }
        do {
            try await postContext()
            authFailures = 0 // a POST succeeded: clear the context-refusal floor
            armStaleWatch()
        } catch is CancellationError {
            return
        } catch let error as LiveSyncError {
            report(error)
            // The key was refused: rotated or revoked. Mark it so the running loop invalidates and
            // backs off in place — restarting the loop here reset the attempt counter and could spin
            // against a backend that keeps refusing. Count the refusal so the backoff grows even
            // when a frame on the just-opened socket reset `attempt`.
            if case .httpFailure(let status, _) = error, status == 401 || status == 403 {
                authFailed = true
                authFailures += 1
                socketHolder.closeCurrent()      // ends the stream; the loop handles the rest
            }
        } catch {
            report(.requestFailed(description: LiveSyncError.describe(error)))
        }
    }

    /// The context request: `POST /nlu/c/<deploymentKey>/connect-<language>/context`, authenticated
    /// with the `nlx-api-key` header.
    func makeContextRequest() async throws -> URLRequest {
        let creds = try await vendCredentials()
        try configuration.validate(credentials: creds)
        var request = URLRequest(url: try configuration.contextURL(credentials: creds))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(creds.apiKey, forHTTPHeaderField: "nlx-api-key")
        if let userAgent = configuration.userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        request.httpBody = try contextRequestBody()
        return request
    }

    func postContext() async throws {
        let request = try await makeContextRequest()
        // The decision can change while the credentials were being fetched; the consent gate is checked at the
        // last moment before anything leaves the device, not only at the call site.
        guard consent == .granted else { return }
        try Task.checkCancellation()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw LiveSyncError.requestFailed(description: LiveSyncError.describe(error))
        }

        // Not an HTTP response means the request did not reach the API as HTTP; treating it as
        // success (the proof of concept did) would silently drop the context.
        guard let http = response as? HTTPURLResponse else {
            throw LiveSyncError.requestFailed(description: "non-HTTP response \(type(of: response))")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LiveSyncError.httpFailure(
                statusCode: http.statusCode,
                responseBody: String(data: data, encoding: .utf8)
            )
        }
    }

    /// The context request body: `{ conversationId, context: { "nlx:vpContext": … } }`.
    func contextRequestBody() throws -> Data {
        let body = ContextRequest(
            conversationId: configuration.conversationId,
            context: ["nlx:vpContext": advertisedContext.voicePlusContext()]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(body)
        } catch {
            throw LiveSyncError.requestFailed(description: LiveSyncError.describe(error))
        }
    }

    private struct ContextRequest: Encodable {
        let conversationId: String
        let context: [String: JSONValue]
    }

    // MARK: - Invocations

    /// A stream of every action invoked by the conversation engine.
    ///
    /// Useful for observers that want the raw feed — logging, analytics, or a view model that would
    /// rather `for await` than register a closure. ``onAction`` is called regardless of whether anyone
    /// is consuming this stream, and each call returns an independent stream.
    public func invocations() -> AsyncStream<LiveSyncActionInvocation> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<LiveSyncActionInvocation>.makeStream(
            bufferingPolicy: .unbounded
        )
        invocationObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.invocationObservers[id] = nil
            }
        }
        return stream
    }

    /// Parses one socket frame and dispatches it. Exposed for tests and for apps that receive Live
    /// Sync frames through their own transport.
    func ingest(_ text: String) {
        guard let data = text.data(using: .utf8) else {
            report(.malformedInvocation(description: "Frame was not valid UTF-8"))
            return
        }
        do {
            switch try LiveSyncInboundFrame.decode(from: data) {
            case .custom(let invocation):
                dispatch(invocation)
            case .navigation(let navigation):
                if let onNavigation, dispatchState == .enabled {
                    onNavigation(navigation)
                } else {
                    diagnostics.unhandledNavigationFrames += 1
                }
            case .input:
                diagnostics.droppedInputFrames += 1
            case .note:
                diagnostics.noteFrames += 1
            case .unknown:
                break
            }
        } catch let error as LiveSyncError {
            report(error)
        } catch {
            report(.malformedInvocation(description: LiveSyncError.describe(error)))
        }
    }

    private func dispatch(_ invocation: LiveSyncActionInvocation) {
        // While a human agent is on the contact nothing the assistant says moves the app. The
        // observation stream is gated too — it is a dispatch path, just a different shape of one.
        guard dispatchState == .enabled else {
            diagnostics.suppressedInvocations += 1
            return
        }
        // The backend does not validate against the advertised schema, and can fire actions
        // the device never advertised. Checked here, before a prompt can show it or a handler or the
        // observation feed can see it — so an invalid payload is rejected, never counted as declined.
        if let problem = payloadProblem(invocation) {
            diagnostics.rejectedInvocations += 1
            report(.invalidPayload(action: Self.reportableName(invocation.action), description: problem))
            return
        }
        // A confirmation-required action is held until the user confirms. Its handler does not
        // run, and the observation feed does not see it either, until then — the feed reflects what
        // was actually dispatched. A second confirmation-required invocation while one is pending is
        // DECLINED, not queued: one sensitive decision is held at a time, and silently stacking or
        // reordering sensitive prompts is worse than making the engine re-ask.
        if let requirement = confirmationRequirements[invocation.action] {
            guard pendingConfirmation == nil else {
                diagnostics.declinedConfirmations += 1
                report(.actionHandlerFailed(action: invocation.action, description: "declined by user"))
                return
            }
            heldInvocation = invocation
            let pending = PendingConfirmation(id: UUID(), action: invocation.action,
                                              actionDescription: requirement.actionDescription,
                                              message: requirement.message)
            pendingConfirmation = pending
            onPendingConfirmationChange?(pending)
            return
        }
        deliver(invocation)
    }

    // MARK: - On-device payload validation

    /// Why an invocation must not run, or `nil`. Names a keyword and a pointer, never a value.
    private func payloadProblem(_ invocation: LiveSyncActionInvocation) -> String? {
        guard let action = advertisedContext.actions.first(where: { $0.name == invocation.action }) else {
            return "not in the advertised context"
        }
        guard let schema = action.schema else {
            // Advertised without parameters: the engine has nothing to send.
            if case .object(let members) = invocation.payload, members.isEmpty { return nil }
            return "parameters for an action advertised without a schema"
        }
        return LiveSyncPayloadValidator.validate(invocation.payload, against: schema)?.description
    }

    /// An un-advertised action's name comes from the frame, not from the app: report it only if it
    /// looks like an action name (the engine's own advertise pattern), never arbitrary text.
    static func reportableName(_ name: String) -> String {
        let allowed = name.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
        }
        return allowed && (1...64).contains(name.unicodeScalars.count) ? name : "<unnamed>"
    }

    /// Schema problems already reported to this client's host, so a re-advertise does not repeat them.
    private var reportedSchemaProblems: Set<String> = []

    /// An action whose schema is outside the supported subset can never run — every invocation would
    /// be rejected mid-call. Say so when it is advertised, once per action and problem.
    private func reportUnusableSchemas(in context: LiveSyncContext) {
        for action in context.actions {
            guard let schema = action.schema else { continue }
            var problems: [String] = []
            if let unsupported = LiveSyncPayloadValidator.unsupportedKeyword(in: schema) {
                problems.append("schema for \(action.name) uses \(unsupported); its invocations will be rejected")
            }
            if let name = LiveSyncPayloadValidator.backendUnwrappedProperty(in: schema) {
                problems.append("schema for \(action.name) has a top-level property named \(name), which the Live Sync engine unwraps; its invocations may be rejected")
            }
            if let rewrite = LiveSyncPayloadValidator.engineRewrite(in: schema) {
                problems.append("schema for \(action.name) has \(rewrite.description), which the Live Sync engine always sends as a string"
                                + (rewrite.admitsString ? "" : "; its invocations will be rejected"))
            }
            for problem in problems where reportedSchemaProblems.insert(problem).inserted {
                report(.invalidConfiguration(problem))
            }
        }
    }

    /// Called when the client needs the app's context again — consent re-granted after a denial
    /// cleared it (the grant may come from the SDK's own consent sheet). Until context is sent,
    /// every invocation is rejected as not advertised. An aggregator built with `init(client:)` sets
    /// this to its ``TouchpointActionAggregator/readvertise()``; a host with a client-less aggregator
    /// or an imperative context sets it to re-send the current one.
    public var onContextNeeded: (@MainActor () -> Void)?

    /// Tests: what ``sendContext(_:)`` records, without a post.
    func adoptAdvertisedContext(_ context: LiveSyncContext) {
        advertisedContext = context
    }

    /// Yields to observers and calls ``onAction``. The confirmation gate is upstream in
    /// ``dispatch(_:)``; a confirmed action arrives here having already been decided on.
    private func deliver(_ invocation: LiveSyncActionInvocation) {
        for continuation in invocationObservers.values {
            continuation.yield(invocation)
        }

        guard let onAction else { return }
        do {
            try onAction(invocation)
        } catch {
            report(
                .actionHandlerFailed(
                    action: invocation.action,
                    description: LiveSyncError.describe(error)
                )
            )
        }
    }

    // MARK: - Idle guard: the zombie socket

    /// (Re)arms the idle timer. The backend's connection lease is renewed only when a command is
    /// delivered, so a socket silent for longer than the lease is TCP-healthy and useless. There is
    /// no ping in the protocol; the only remedy is to reconnect before the lease lapses.
    private func restartIdleGuard() {
        stopIdleGuard()
        guard let threshold = idleReconnectThreshold else { return }
        idleGuard = Task { @MainActor [weak self, idleClock] in
            do { try await idleClock.sleep(for: threshold) } catch { return }
            guard let self, !Task.isCancelled, self.isConnected else { return }
            self.diagnostics.idleReconnects += 1
            self.idleReconnectPending = true
            self.socketHolder.closeCurrent()   // ends the stream; the loop reconnects without backoff
        }
    }

    private func stopIdleGuard() {
        idleGuard?.cancel()
        idleGuard = nil
    }

    // MARK: - Stale-contact diagnostic

    /// Armed once context has been posted on a live socket. A frame disarms it; silence past the
    /// threshold reports `contactMayBeStale`, once per connection.
    private func armStaleWatch() {
        guard let threshold = staleContactThreshold, isConnected, !hasReceivedFrame, !contactMayBeStale,
              staleWatch == nil else { return }
        staleWatch = Task { @MainActor [weak self, idleClock] in
            do { try await idleClock.sleep(for: threshold) } catch { return }
            guard let self, !Task.isCancelled, self.isConnected, !self.hasReceivedFrame else { return }
            self.contactMayBeStale = true
            self.diagnostics.staleContactWarnings += 1
            self.report(.contactMayBeStale(quietFor: threshold))
        }
    }

    private func stopStaleWatch() {
        staleWatch?.cancel()
        staleWatch = nil
    }

    private func report(_ error: LiveSyncError) {
        onError?(error)
    }
}

/// Notification observer tokens, removable from a nonisolated `deinit`.
private final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [NSObjectProtocol] = []
    func add(_ token: NSObjectProtocol) { lock.withLock { tokens.append(token) } }
    func removeAll() {
        let tokens = lock.withLock { let t = self.tokens; self.tokens = []; return t }
        for t in tokens { NotificationCenter.default.removeObserver(t) }
    }
}

/// Holds the live transport so `deinit` can close the socket without touching main-actor state.
private final class SocketHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var transport: (any LiveSyncTransport)?

    func set(_ transport: any LiveSyncTransport) {
        let previous: (any LiveSyncTransport)? = lock.withLock {
            let previous = self.transport
            self.transport = transport
            return previous
        }
        previous?.close()
    }

    func clear(_ transport: any LiveSyncTransport) {
        lock.withLock {
            if self.transport === transport { self.transport = nil }
        }
    }

    func closeCurrent() {
        let transport: (any LiveSyncTransport)? = lock.withLock {
            let transport = self.transport
            self.transport = nil
            return transport
        }
        transport?.close()
    }
}
