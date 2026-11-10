import Foundation
import TouchpointCore

/// Outbound WebRTC voice over the Amazon Chime SDK, as a `ContactTransport`.
///
/// The host backend calls `StartWebRTCContact`; the broker hands back `VoiceContactCredentials`
/// whose `meetingJSON`/`attendeeJSON` this transport decodes and joins. Three rules shape it:
///
/// - **A dropped call is terminal for the contact.** There is no inbound path, so the agent cannot
///   call back, and a fresh `StartWebRTCContact` is a new contact with a new ID and a lost queue
///   position. Chime's own reconnect (bounded by `reconnectTimeoutMs`, 30 s here rather than its
///   180 s default) stays **inside** this transport, visible through ``isReconnecting`` and
///   ``onReconnectingChange`` for a call UI: the session treats any `.disconnected` from a voice
///   transport as the end of the contact (`refreshFailurePolicy(.voice) == .endContact`), so
///   surfacing Chime's recoverable drop there would end every call on its first Wi-Fi handoff. Once
///   Chime gives up, the transport reports `.contactEnded(.connectionLost)` plainly and stops.
/// - **No hold.** Chime exposes no hold primitive and the Connect reference declares calls
///   non-holdable. Mute is the one control besides end.
/// - **CallKit owns the audio session** (`callKitEnabled: true`). This transport never
///   touches `AVAudioSession`; `connect` is called from `didActivateAudioSession`.
///
/// The Chime SDK is behind `ChimeMeetingSessionDriving` so this actor is tested on macOS.
public actor VoiceTransport: ContactTransport {
    /// Owner decision 2026-10-12: long enough for a Wi-Fi → cellular handoff, short enough that the
    /// agent is not talking to dead air for three minutes.
    public static let defaultReconnectTimeout: Duration = .seconds(30)

    private let driver: any ChimeMeetingSessionDriving
    private let reconnectTimeoutMs: Int

    private enum Phase: Equatable { case idle, joining, connected, reconnecting, ended }
    private var phase: Phase = .idle
    private var localAttendeeID: String?
    private var muted = false
    /// A mute set while idle is a request for the *next* join; one left over from the last call is not.
    private var muteRequestedForThisCall = false
    /// Remote playback muted — the Speakers control (VO-4). Like `muted`, remembered across a join
    /// and re-asserted when media starts, because Chime starts each (re)join with playback live.
    private var playbackMuted = false
    private var playbackRequestedForThisCall = false
    private var handlersInstalled = false

    /// `true` while Chime is re-establishing media after a drop. Not a session event — see the type
    /// doc — but a call UI wants to show it.
    public private(set) var isReconnecting = false {
        didSet { if isReconnecting != oldValue { onReconnectingChange?(isReconnecting) } }
    }
    private var onReconnectingChange: (@Sendable (Bool) -> Void)?
    private var onSpeakingChange: (@Sendable (Bool, Bool) -> Void)?
    /// Who is audible right now. A **set**, not a boolean: Chime's volume updates name only the
    /// attendees whose level changed, so with two remote parties a delta saying one fell silent
    /// must not clear the ripple while the other is still talking.
    private var audibleRemotes: Set<String> = []
    private var localSpeaking = false
    private var remoteSpeaking = false
    /// Raw local audibility, as Chime last reported it; `localSpeaking` is the published, smoothed
    /// value (web's `createSpeakingFlag`, `voice.ts:99-137`).
    private var localAudible = false
    /// One generation per flag, bumped on every raw change and on a clear, so a pending switch-off
    /// scheduled for an older state (or an older contact) does nothing when it fires.
    private var localGeneration = 0
    private var remoteGeneration = 0
    private var localOffPending = false
    private var remoteOffPending = false
    private let sleeper: any VoiceSleeping
    /// Web's `SPEAKING_OFF_DELAY_MS`: a speaking indicator lingers this long after speech stops,
    /// so the gaps between words don't flicker it.
    static let speakingOffDelay: Duration = .milliseconds(500)

    /// Screen sharing. See ``ScreenShareState``; the transitions are the plan's table.
    public private(set) var screenShare: ScreenShareState = .unavailable {
        didSet {
            guard screenShare != oldValue else { return }
            screenShareVersion += 1
            onScreenShareChange?(screenShare, screenShareVersion)
        }
    }
    /// Increases with every change, so the facade's main-actor hops — which need not land in
    /// order — never let an older state overwrite a newer one.
    private(set) var screenShareVersion = 0
    private var onScreenShareChange: (@Sendable (ScreenShareState, Int) -> Void)?

    /// The current state and its version, for a caller that just changed it.
    func screenShareSnapshot() -> (ScreenShareState, Int) { (screenShare, screenShareVersion) }
    /// Set before a call by the facade from the host's opt-in; read at the join.
    private var allowsScreenShare = false

    /// Observe screen-sharing changes, with their version. Reported only when the state changes.
    func setScreenShareObserver(_ observer: (@Sendable (ScreenShareState, Int) -> Void)?) {
        onScreenShareChange = observer
    }

    /// Whether the next join listens for Connect's screen-sharing signal.
    func setAllowsScreenShare(_ allows: Bool) {
        allowsScreenShare = allows
    }

    /// Starts sharing this app's screen. Returns once the state is ``ScreenShareState/starting`` —
    /// never waits on iOS's consent prompt. Throws unless sharing is ``ScreenShareState/available``.
    public func startScreenShare() throws {
        guard screenShare == .available, phase == .connected || phase == .reconnecting else {
            throw TouchpointError.invalidConfiguration("screen sharing is not available")
        }
        screenShare = .starting
        driver.startScreenShare()
    }

    /// Stops sharing. A no-op unless starting or sharing.
    public func stopScreenShare() {
        guard screenShare == .starting || screenShare == .sharing else { return }
        screenShare = .available
        driver.stopScreenShare()
    }

    /// Observe Chime-internal reconnects, for a call UI's "reconnecting…" state.
    public func setReconnectingObserver(_ observer: (@Sendable (Bool) -> Void)?) {
        onReconnectingChange = observer
    }

    /// Observe who is audible: the local attendee, and anyone else. Reported only when it changes,
    /// because Chime raises volume updates several times a second while anyone is talking. Drives
    /// the voice rail's ripple.
    public func setSpeakingObserver(_ observer: (@Sendable (_ localSpeaking: Bool, _ remoteSpeaking: Bool) -> Void)?) {
        onSpeakingChange = observer
    }

    // Events: one stream per subscriber generation, buffered until a subscriber attaches
    // (`ContactTransport` ordering contract).
    private var continuation: AsyncStream<TransportEvent>.Continuation?
    private var buffered: [TransportEvent] = []

    // Driver callbacks arrive on Chime's threads; they are funnelled through this inbox and
    // processed on the actor, in order.
    private enum Inbound: Sendable {
        case connecting(Bool), started(Bool), dropped, cancelledReconnect, stopped(VoiceSessionStatus)
        case joined([VoiceAttendee]), left([VoiceAttendee])
        case volume([VoiceVolume])
        case shareSignal(Data), shareStarted, shareStopped(failed: Bool)
    }
    private let inbox: AsyncStream<Inbound>
    private let inboxContinuation: AsyncStream<Inbound>.Continuation
    private var pump: Task<Void, Never>?

    /// Production: a real Chime session per call.
    #if canImport(AmazonChimeSDK)
    public init(reconnectTimeout: Duration = VoiceTransport.defaultReconnectTimeout) {
        self.init(driver: ChimeMeetingSessionDriver(), reconnectTimeout: reconnectTimeout)
    }
    #endif

    init(driver: any ChimeMeetingSessionDriving, reconnectTimeout: Duration = VoiceTransport.defaultReconnectTimeout,
         sleeper: any VoiceSleeping = ContinuousClockVoiceSleeper()) {
        self.driver = driver
        self.sleeper = sleeper
        self.reconnectTimeoutMs = Int(reconnectTimeout.components.seconds) * 1000
            + Int(reconnectTimeout.components.attoseconds / 1_000_000_000_000_000)
        (inbox, inboxContinuation) = AsyncStream<Inbound>.makeStream(bufferingPolicy: .unbounded)
    }

    deinit {
        // Ends the pump's `for await` so the task completes; the driver closures hold only the
        // continuation. Media teardown needs isolated state and is `disconnect()`'s job.
        inboxContinuation.finish()
    }

    // MARK: ContactTransport

    public nonisolated var events: AsyncStream<TransportEvent> {
        AsyncStream { continuation in
            Task { await self.attach(continuation) }
        }
    }

    private func attach(_ c: AsyncStream<TransportEvent>.Continuation) {
        continuation?.finish()
        continuation = c
        for e in buffered { c.yield(e) }
        buffered.removeAll()
    }

    private func yield(_ e: TransportEvent) {
        if let continuation {
            if case .terminated = continuation.yield(e) {
                self.continuation = nil
                buffered.append(e)
            }
        } else {
            buffered.append(e)
        }
    }

    public func connect(credentials: any ExpiringCredentials) async throws {
        guard let c = credentials as? VoiceContactCredentials else {
            throw TouchpointError.invalidConfiguration("VoiceTransport needs VoiceContactCredentials, got \(type(of: credentials))")
        }
        guard phase == .idle || phase == .ended else {
            throw TouchpointError.invalidConfiguration("a call is already in progress")
        }
        let configuration = try VoiceMeetingConfiguration(meetingJSON: c.meetingJSON, attendeeJSON: c.attendeeJSON)
        buffered.removeAll()   // a previous contact's unobserved `.contactEnded` must not greet the next subscriber
        installHandlersIfNeeded()
        // Mute is per call. Whatever the last call ended with, a new one starts with the microphone live
        // unless the caller mutes before the join — both UIs show unmuted, so the join must be too.
        if !muteRequestedForThisCall { muted = false }
        muteRequestedForThisCall = false
        if !playbackRequestedForThisCall { playbackMuted = false }
        playbackRequestedForThisCall = false
        localAttendeeID = configuration.attendeeID
        // A fresh contact starts silent, whatever the previous one was doing when it ended.
        clearSpeaking()
        screenShare = .unavailable
        phase = .joining
        do {
            var parameters = configuration.startParameters(reconnectTimeoutMs: reconnectTimeoutMs)
            parameters.startMuted = muted
            parameters.screenShare = allowsScreenShare
            try driver.start(parameters)
        } catch {
            phase = .idle
            buffered.removeAll()
            throw TouchpointError.transportFailure("\(type(of: error))(\((error as NSError).code))")
        }
    }

    /// Voice carries no messages. A host that wants text alongside a call starts a chat contact.
    public func send(_ message: OutboundMessage) async throws {
        throw TouchpointError.invalidConfiguration("voice contacts carry no messages")
    }

    /// Ends the media session. Emits nothing: the session reports `.customerEnded` itself.
    public func disconnect() async {
        let wasLive = phase != .idle && phase != .ended
        phase = .ended
        isReconnecting = false
        screenShare = .unavailable   // the driver's stop ends any share first
        if wasLive { driver.stop() }
        continuation?.finish()
        continuation = nil
        buffered.removeAll()
    }

    // MARK: Call controls

    /// The microphone state as the SDK believes it: set only when Chime accepted the change, or
    /// when there is no live session yet and the request is being remembered for the join.
    public var isMuted: Bool { muted }

    /// Mutes or unmutes the microphone. Before the audio session starts the request is remembered
    /// and applied the moment it does. On a live session it is forwarded and `isMuted` follows only
    /// if Chime accepted it; the thrown error lets a CallKit mute action fail honestly.
    public func setMuted(_ newValue: Bool) throws {
        guard phase == .connected || phase == .reconnecting else { muted = newValue; muteRequestedForThisCall = true; return }
        guard driver.setMuted(newValue) else {
            throw TouchpointError.transportFailure(newValue ? "mute refused by the media session" : "unmute refused by the media session")
        }
        muted = newValue
    }

    /// Mutes or unmutes **remote playback** — the Speakers control (VO-4). Before the audio session
    /// starts the request is remembered and applied when it does; on a live session it is forwarded
    /// at once. Unlike `setMuted`, nothing is thrown: a refused playback mute is not a privacy
    /// concern, and the Speakers toggle reflects the customer's intent either way.
    public func setPlaybackMuted(_ newValue: Bool) {
        guard phase == .connected || phase == .reconnecting else { playbackMuted = newValue; playbackRequestedForThisCall = true; return }
        driver.setPlaybackMuted(newValue)
        playbackMuted = newValue
    }

    /// Whether remote playback is muted, as the SDK believes it.
    public var isPlaybackMuted: Bool { playbackMuted }

    /// Re-runs device selection — on a route change, or when Bluetooth connects mid-call.
    public func reselectAudioDevice() {
        guard phase == .connected || phase == .reconnecting else { return }
        guard let best = driver.listAudioDevices().max(by: { $0.kind < $1.kind }) else { return }
        driver.chooseAudioDevice(best)
    }

    // MARK: Driver callbacks → state machine

    private func installHandlersIfNeeded() {
        guard !handlersInstalled else { return }
        handlersInstalled = true
        let inbox = inboxContinuation
        driver.setHandlers(VoiceDriverHandlers(
            onConnecting: { inbox.yield(.connecting($0)) },
            onStarted: { inbox.yield(.started($0)) },
            onDropped: { inbox.yield(.dropped) },
            onCancelledReconnect: { inbox.yield(.cancelledReconnect) },
            onStopped: { inbox.yield(.stopped($0)) },
            onAttendeesJoined: { inbox.yield(.joined($0)) },
            onAttendeesLeft: { inbox.yield(.left($0)) },
            onVolumeChanged: { inbox.yield(.volume($0)) },
            onScreenShareSignal: { inbox.yield(.shareSignal($0)) },
            onScreenShareStarted: { inbox.yield(.shareStarted) },
            onScreenShareStopped: { inbox.yield(.shareStopped(failed: $0)) }
        ))
        let inboxStream = self.inbox
        pump = Task { [weak self] in
            for await inbound in inboxStream {
                guard let self else { return }
                await self.process(inbound)
            }
        }
    }

    private func process(_ inbound: Inbound) {
        // Once the contact has ended — by us or by the network — nothing Chime says afterwards
        // changes that. A late `started(reconnecting: true)` must not revive a dead contact.
        guard phase != .ended, phase != .idle else { return }
        switch inbound {
        case .connecting(let reconnecting):
            if reconnecting, phase == .connected {
                phase = .reconnecting
                isReconnecting = true
                clearSpeaking()   // no volume updates arrive while media is down
            }
        case .started(let reconnecting):
            let wasConnected = phase == .connected || phase == .reconnecting
            phase = .connected
            isReconnecting = false
            // Re-assert mute: Chime starts the (re)joined audio client unmuted. The initial mute is
            // also applied synchronously by the driver in `audioSessionDidStart` so the microphone
            // is never live between the start and this hop; this covers the reconnect path.
            if muted { _ = driver.setMuted(true) }
            // Playback (the Speakers control) is re-asserted the same way: Chime starts each
            // (re)join with remote audio live. No `startMuted` equivalent is needed — a few ms of
            // audible remote audio on a reconnect is not a privacy concern, so applying it here
            // rather than synchronously in the driver is enough.
            if playbackMuted { driver.setPlaybackMuted(true) }
            reselectAudioDevice()
            // Chime's own recovery is not a new connection to the session; a drop before the first
            // start (reconnecting == true while still .joining) is Chime retrying its join.
            if !(reconnecting && wasConnected) { yield(.connected) }
        case .dropped:
            // A drop before the agent joins is Chime still establishing; the Connect reference ignores
            // it too (CallManager.swift:305). After that it is a recoverable reconnect, kept internal.
            if phase == .connected {
                phase = .reconnecting
                isReconnecting = true
                // Media is down, so no volume update will ever clear a remote that was audible at
                // the moment of the drop; the ripple would run through "Reconnecting…".
                clearSpeaking()
            }
        case .cancelledReconnect:
            end(.connectionLost)
        case .stopped(let status):
            end(Self.endReason(for: status, hadConnected: phase != .joining))
        case .joined(let attendees):
            guard phase == .connected || phase == .reconnecting else { return }
            for a in attendees where a.id != localAttendeeID && !Self.isContentAttendee(a.id) {
                yield(.participantJoined(Participant(id: a.id, role: Self.role(for: a), displayName: "")))
            }
        case .left(let attendees):
            guard phase == .connected || phase == .reconnecting else { return }
            for a in attendees where a.id != localAttendeeID && !Self.isContentAttendee(a.id) {
                // A party who drops mid-sentence must not leave the ripple running.
                audibleRemotes.remove(a.id)
                yield(.participantLeft(id: a.id))
            }
            // Gone is not a pause between words: no off-delay for whoever left. **Deviation:** web
            // drives one flag from every remote's raw volume and leaves it alone on a departure;
            // here the audible set is aggregated, so one party's silence never schedules an off
            // while another still speaks, and a departure clears at once (which also cuts short a
            // pending off from a different party's pause).
            updateSpeaking(local: localAudible, remoteOffImmediately: true)
        case .volume(let updates):
            // `process` already dropped anything after the contact ended, so a late update cannot
            // leave a ripple running on a finished call.
            var nextLocal = localAudible
            for update in updates where !Self.isContentAttendee(update.attendeeID) {
                if update.attendeeID == localAttendeeID {
                    nextLocal = update.isAudible
                } else if update.isAudible {
                    audibleRemotes.insert(update.attendeeID)
                } else {
                    audibleRemotes.remove(update.attendeeID)
                }
            }
            updateSpeaking(local: nextLocal)
        case .shareSignal(let data):
            guard phase == .connected || phase == .reconnecting, let signal = ScreenShareSignal(data: data) else { return }
            switch signal {
            case .started:
                if screenShare == .unavailable { screenShare = .available }
            case .stopped:
                let wasSharing = screenShare == .starting || screenShare == .sharing
                screenShare = .unavailable
                if wasSharing { driver.stopScreenShare() }
            }
        case .shareStarted:
            // A content share nobody asked for — a late start after the customer stopped, say — is
            // ended rather than left showing the screen.
            if screenShare == .starting { screenShare = .sharing } else { driver.stopScreenShare() }
        case .shareStopped:
            // Declined, failed, or Chime confirming our own stop. Not an error: iOS reports
            // "Don't Allow" the same way as a failure, and the customer chose it.
            if screenShare == .starting || screenShare == .sharing { screenShare = .available }
        }
    }

    /// Chime's content-share attendee: `<attendeeId>#content`, ours or the agent's. Never a
    /// participant: ours would read as an unknown human and hold the Live Sync gate after
    /// the agent leaves; the agent's would announce the agent joining twice.
    static func isContentAttendee(_ id: String) -> Bool { id.hasSuffix("#content") }

    /// Feeds the raw audibility in. Each flag switches on at once and off only after
    /// ``speakingOffDelay`` of continuous silence; speech resuming in that window cancels the
    /// switch-off (web `createSpeakingFlag`). Volume-driven offs are delayed; a clear is not.
    private func updateSpeaking(local: Bool, remoteOffImmediately: Bool = false) {
        let remote = !audibleRemotes.isEmpty
        if local != localAudible { localGeneration += 1; localOffPending = false }
        localAudible = local
        var nextLocal = localSpeaking, nextRemote = remoteSpeaking
        if local { nextLocal = true } else if localSpeaking, !localOffPending {
            localOffPending = true
            scheduleOff(local: true, generation: localGeneration)
        }
        if remote {
            if remoteOffPending { remoteGeneration += 1; remoteOffPending = false }
            nextRemote = true
        } else if remoteSpeaking {
            if remoteOffImmediately {
                remoteGeneration += 1; remoteOffPending = false
                nextRemote = false
            } else if !remoteOffPending {
                remoteOffPending = true
                scheduleOff(local: false, generation: remoteGeneration)
            }
        }
        publish(local: nextLocal, remote: nextRemote)
    }

    private func scheduleOff(local: Bool, generation: Int) {
        let sleeper = sleeper
        Task { [weak self] in
            try? await sleeper.sleep(for: Self.speakingOffDelay)
            await self?.speakingOffElapsed(local: local, generation: generation)
        }
    }

    /// A delayed switch-off: applied only if nothing changed the flag since it was scheduled and
    /// it is still silent.
    private func speakingOffElapsed(local: Bool, generation: Int) {
        if local {
            guard localOffPending, generation == localGeneration, !localAudible else { return }
            localOffPending = false
            publish(local: false, remote: remoteSpeaking)
        } else {
            guard remoteOffPending, generation == remoteGeneration, audibleRemotes.isEmpty else { return }
            remoteOffPending = false
            publish(local: localSpeaking, remote: false)
        }
    }

    /// Reports the speaking signal when it has changed. Centralised so every path reports through
    /// one place.
    private func publish(local: Bool, remote: Bool) {
        guard local != localSpeaking || remote != remoteSpeaking else { return }
        localSpeaking = local
        remoteSpeaking = remote
        onSpeakingChange?(local, remote)
    }

    /// Silence, reported at once, and any pending switch-off cancelled. Called when a contact ends,
    /// a new one starts or media drops, so a customer who hangs up mid-sentence does not leave the
    /// next call's rail rippling, and a stale timer cannot touch the next call.
    private func clearSpeaking() {
        audibleRemotes.removeAll()
        localAudible = false
        localGeneration += 1; remoteGeneration += 1
        localOffPending = false; remoteOffPending = false
        publish(local: false, remote: false)
    }

    private func end(_ reason: EndReason) {
        phase = .ended
        isReconnecting = false
        clearSpeaking()
        screenShare = .unavailable
        // Always detach, even when Chime stopped on its own: the driver would otherwise hold a
        // session whose observers are still attached when the next call creates a new one.
        driver.stop()
        yield(.contactEnded(reason))
    }

    /// Why the meeting ended, in the session's vocabulary. Chime signals a call the far side
    /// finished with `audioCallEnded` or `audioServerHungup`; everything else that is not `ok` is a
    /// failure we could not recover from.
    static func endReason(for status: VoiceSessionStatus, hadConnected: Bool) -> EndReason {
        switch status {
        case .ok: return hadConnected ? .agentEnded : .systemEnded
        case .audioCallEnded, .audioServerHungup: return .agentEnded
        default: return .connectionLost
        }
    }

    /// The Connect reference identifies the agent attendee by an `externalUserId` ending in
    /// `agent`. Anything else remote is `.unknown`, which counts as human for the dispatch gate: a wrong
    /// guess pauses the assistant rather than dispatching into a call a person is handling. The mapping
    /// has been checked on a live call.
    static func role(for attendee: VoiceAttendee) -> ParticipantRole {
        attendee.externalUserID.lowercased().hasSuffix("agent") ? .agent : .unknown
    }
}
