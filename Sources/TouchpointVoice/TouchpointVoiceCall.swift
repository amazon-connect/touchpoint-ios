import Foundation
import Observation
import TouchpointCore

/// The call as a host sees it: one state, combining CallKit's view, the transport's, and the audio
/// session's.
public enum VoiceCallState: Sendable, Equatable {
    case idle
    /// `CXStartCallAction` requested.
    case requesting
    /// The system granted the audio session; credentials are being vended and media is joining.
    case connecting
    case connected
    /// Chime is re-establishing media after a drop (within `reconnectTimeout`). Not a session event.
    case reconnecting
    /// The system took the audio session for another call.
    case interrupted
    case ended(EndReason)
}

/// One outbound voice call, end to end: CallKit, the Chime transport, the audio session, the
/// `TouchpointSession` contact, the microphone permission, and VoiceOver announcements (plan
//). A host creates one per app and calls ``start`` / ``end`` / ``setMuted(_:)``.
///
/// The ordering the whole thing exists to get right:
///
/// 1. ``start()`` checks the microphone permission (a denial is a product state, surfaced before any
///    system request), then asks CallKit for a `CXStartCallAction`.
/// 2. CallKit performs it → the audio session's category and mode are set, the action is fulfilled.
///    No network here.
/// 3. CallKit activates the audio session → `session.startVoice` vends credentials and joins Chime.
/// 4. The transport's `.connected` tells CallKit the call connected; `.contactEnded` tells it why.
///
/// Routing and interruptions are observed by the SDK itself: Chime's route observer drops
/// `.categoryChange` and `.override`, the two that fire most under CallKit, and its interruption
/// handling is telemetry-only. Every state change is announced for VoiceOver.
/// `@Observable` so SwiftUI redraws when the call changes — the rail reads `state`, `isMuted` and
/// the speaking signal directly. The `onStateChange` / `onMuteChange` callbacks remain for hosts
/// that mirror into their own model.
@MainActor
@Observable
public final class TouchpointVoiceCall {
    public private(set) var state: VoiceCallState = .idle {
        didSet { if state != oldValue { onStateChange?(state); announce(for: state, previous: oldValue) } }
    }
    public var onStateChange: (@MainActor (VoiceCallState) -> Void)?
    public var onError: (@MainActor (TouchpointError) -> Void)?
    /// Set when ``start()`` refused because the microphone is denied: what to show and the Settings link.
    public private(set) var permissionDenial: PermissionDenial?
    public var callID: UUID? { manager.callID }
    public private(set) var isMuted = false {
        didSet { if isMuted != oldValue { onMuteChange?(isMuted) } }
    }
    /// Fires when the microphone state changes — from the app, the system call UI, or an interruption.
    public var onMuteChange: (@MainActor (Bool) -> Void)?
    /// Whether the customer hears the other side — the Speakers control (VO-4). `true` is playback
    /// on, web's default. Drives the full-screen view's Speakers toggle; a host that hides the view
    /// reads it for its own. Mutes *remote playback*, never the microphone.
    public private(set) var speakersOn = true {
        didSet { if speakersOn != oldValue { onSpeakersChange?(speakersOn) } }
    }
    public var onSpeakersChange: (@MainActor (Bool) -> Void)?
    /// Current audio output, as announced ("Speaker", a headset's name).
    public private(set) var audioOutput: String?
    /// Whether the customer is currently audible. Drives the rail's microphone ripple.
    public private(set) var isLocalSpeaking = false
    /// Whether anyone on the other side is currently audible. Drives the speaker ripple.
    public private(set) var isRemoteSpeaking = false
    public var onSpeakingChange: (@MainActor (_ local: Bool, _ remote: Bool) -> Void)?
    /// Screen sharing with the agent (only when the host passed `allowsScreenShare`). The rail's
    /// share control is the indicator; a host that hides the rail reads this for its own.
    public private(set) var screenShare: ScreenShareState = .unavailable {
        didSet {
            guard screenShare != oldValue else { return }
            onScreenShareChange?(screenShare)
            announceScreenShare(screenShare, previous: oldValue)
        }
    }
    public var onScreenShareChange: (@MainActor (ScreenShareState) -> Void)?

    private let session: TouchpointSession
    private let transport: VoiceTransport
    private let manager: TouchpointCallManager
    private let audioSession: any VoiceAudioSessionControlling
    private let permissions: any PermissionRequesting
    private let permissionPolicy: PermissionPolicy
    @ObservationIgnored private let announceText: @MainActor (String) -> Void
    @ObservationIgnored private var audioObservation: (any VoiceAudioObservationToken)?
    @ObservationIgnored private var eventPump: Task<Void, Never>? {
        didSet { pumpBox.set(eventPump) }
    }
    private var mutedBeforeInterruption = false
    private var activeCall: UUID?
    private var lastEndReason: EndReason?
    private let displayName: String
    private let allowsScreenShare: Bool

    #if canImport(CallKit) && canImport(AVFAudio) && !os(macOS)
    /// Production wiring: CallKit, the system audio session, the microphone permission.
    ///
    /// - Parameters:
    ///   - session: the `TouchpointSession` that will own the voice contact. Must have a
    ///     `VoiceTransport` registered for `.voice` — pass the same instance as `transport`.
    ///   - displayName: the contact centre's name, shown by the system call UI.
    ///   - permissionPolicy: whether the SDK may ask for the microphone. Default: never — the host
    ///     asks at a moment of its choosing and passes `[.microphone]` to let the SDK do it.
    ///   - allowsScreenShare: the customer may share this app's screen when the agent asks. Sent to
    ///     the host backend as ``VoiceContactRequest/screenShare``, which must then allow it on
    ///     `StartWebRTCContact`. Default `false`: the call is exactly as it was without it.
    public convenience init(session: TouchpointSession, transport: VoiceTransport, displayName: String,
                            permissionPolicy: PermissionPolicy = .never, allowsScreenShare: Bool = false) {
        let callKit = CallKitCallSystem()
        self.init(session: session, transport: transport, provider: callKit, controller: callKit,
                  audioSession: SystemAudioSession(), permissions: MicrophonePermissionRequester(),
                  permissionPolicy: permissionPolicy,
                  backgroundModes: Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? [],
                  displayName: displayName, allowsScreenShare: allowsScreenShare,
                  backgroundNotification: UIApplication.didEnterBackgroundNotification,
                  announce: LiveAnnouncer.announce)
    }
    #endif

    init(session: TouchpointSession, transport: VoiceTransport, provider: any CallProviding, controller: any CallControlling,
         audioSession: any VoiceAudioSessionControlling, permissions: any PermissionRequesting, permissionPolicy: PermissionPolicy,
         backgroundModes: [String], displayName: String, allowsScreenShare: Bool = false,
         notificationCenter: NotificationCenter = .default, backgroundNotification: Notification.Name? = nil,
         announce: @escaping @MainActor (String) -> Void) {
        self.allowsScreenShare = allowsScreenShare
        self.session = session
        self.transport = transport
        self.audioSession = audioSession
        self.permissions = permissions
        self.permissionPolicy = permissionPolicy
        self.announceText = announce
        self.displayName = displayName
        // The actions the system's CallKit callbacks drive. Each is the one place its job happens.
        let box = WeakBox()
        manager = TouchpointCallManager(
            provider: provider, controller: controller,
            actions: CallActions(
                configureAudioSession: { try box.call?.configureAudioSession() },
                startMedia: { box.call?.startMedia() },
                endCall: { await box.call?.endMedia() },
                setMuted: { try await box.call?.applyMute($0) }
            ),
            backgroundModes: backgroundModes, displayName: displayName)
        box.call = self
        manager.onStateChange = { [weak self] in self?.managerStateChanged($0) }
        manager.onError = { [weak self] in self?.onError?($0) }
        // Backgrounded, the capture sends nothing and the agent would keep the last frame: stop.
        // Not `willResignActive` — iOS's own consent prompt fires that.
        if allowsScreenShare, let backgroundNotification {
            let token = notificationCenter.addObserver(forName: backgroundNotification, object: nil, queue: nil) { _ in
                Task { @MainActor in await box.call?.stopScreenShare() }
            }
            backgroundBox.set(token, center: notificationCenter)
        }
    }

    /// Installed on the first `start()`, awaited, so a drop right after the join is never missed.
    @ObservationIgnored private var reconnectObserverInstalled = false
    private func installReconnectObserverIfNeeded() async {
        guard !reconnectObserverInstalled else { return }
        reconnectObserverInstalled = true
        let weakSelf = WeakBox(); weakSelf.call = self
        await transport.setSpeakingObserver { [weak self] local, remote in
            Task { @MainActor in
                guard let self else { return }
                guard self.isLocalSpeaking != local || self.isRemoteSpeaking != remote else { return }
                self.isLocalSpeaking = local
                self.isRemoteSpeaking = remote
                self.onSpeakingChange?(local, remote)
            }
        }
        await transport.setReconnectingObserver { reconnecting in
            Task { @MainActor in weakSelf.call?.transportReconnecting(reconnecting) }
        }
        await transport.setScreenShareObserver { state, version in
            Task { @MainActor in weakSelf.call?.applyScreenShare(state, version: version) }
        }
    }

    /// Mirrors `eventPump`'s handle outside actor isolation. `@Observable` makes `deinit`
    /// nonisolated, so it cannot read a main-actor property; this box can be read from there, and
    /// cancelling it is the backstop for a host that drops the facade instead of calling
    /// `shutdown()`.
    @ObservationIgnored private nonisolated let pumpBox = PumpBox()

    @ObservationIgnored private nonisolated let backgroundBox = ObserverBox()

    deinit { pumpBox.cancel(); backgroundBox.remove() }

    /// The background observer's token, removable from the nonisolated `deinit`.
    private final class ObserverBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token: (any NSObjectProtocol)?
        private var center: NotificationCenter?
        func set(_ token: any NSObjectProtocol, center: NotificationCenter) {
            lock.withLock { self.token = token; self.center = center }
        }
        func remove() {
            let (token, center) = lock.withLock { (self.token, self.center) }
            if let token { center?.removeObserver(token) }
            lock.withLock { self.token = nil; self.center = nil }
        }
    }

    /// Holds the pump's handle outside actor isolation, so `deinit` can cancel it.
    private final class PumpBox: @unchecked Sendable {
        private let lock = NSLock()
        private var task: Task<Void, Never>?

        func set(_ task: Task<Void, Never>?) {
            lock.lock(); defer { lock.unlock() }
            self.task?.cancel()
            self.task = task
        }

        func cancel() {
            lock.lock(); defer { lock.unlock() }
            task?.cancel()
            task = nil
        }
    }

    private final class WeakBox: @unchecked Sendable { weak var call: TouchpointVoiceCall? }

    // MARK: Host API

    /// Places the call. Throws `permissionDenied(.microphone)` — and sets ``permissionDenial`` — when the
    /// microphone is off and the policy does not allow asking; throws if a call is already live.
    public func start() async throws {
        permissionDenial = nil
        var status = await permissions.status(of: .microphone)
        if status == .notDetermined { status = await permissions.requestIfAllowed(.microphone, policy: permissionPolicy) }
        guard status == .granted else {
            permissionDenial = PermissionDenial(.microphone)
            throw TouchpointError.permissionDenied(.microphone)
        }
        guard manager.callID == nil else { throw TouchpointError.invalidConfiguration("a call is already in progress") }
        guard !session.isActive else { throw TouchpointError.invalidConfiguration("the session already has an active contact; voice needs its own session or the contact ended") }
        isMuted = false
        mutedBeforeInterruption = false
        speakersOn = true
        lastEndReason = nil
        await installReconnectObserverIfNeeded()
        await transport.setAllowsScreenShare(allowsScreenShare)
        // `activeCall` is set from the manager's `.requesting` transition, synchronously inside
        // `startCall`, so a `didActivate` that lands before the request returns still finds it.
        _ = try await manager.startCall()
    }

    /// Ends the call through CallKit.
    public func end() async throws { try await manager.endCall() }

    /// Ends the call and waits until it has: for a host that is about to release this object. A
    /// facade dropped mid-call would leave the Chime meeting and the Connect contact running.
    public func shutdown() async {
        defer { eventPump = nil }
        guard manager.callID != nil else { return }
        try? await manager.endCall()
        let deadline = ContinuousClock.now + .seconds(5)
        while manager.callID != nil, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if manager.callID != nil { await session.end() }   // CallKit never performed the end: end media directly
    }

    /// Mutes through CallKit, so the system UI agrees.
    public func setMuted(_ muted: Bool) async throws { try await manager.setMuted(muted) }

    /// Turns the other side's audio on or off — the Speakers control (VO-4). Mutes *remote
    /// playback* in the media session, never the microphone, and does not go through CallKit (the
    /// system call UI has no speaker-playback concept of its own). Safe in any state; the request is
    /// remembered and applied when media starts if the call is still connecting.
    public func setSpeakersOn(_ on: Bool) async {
        await transport.setPlaybackMuted(!on)
        speakersOn = on
    }

    /// Starts sharing this app's screen with the agent: iOS's consent prompt follows. Returns once
    /// sharing is ``ScreenShareState/starting``; throws unless ``screenShare`` is
    /// ``ScreenShareState/available``. A declined prompt returns to available and is announced —
    /// it is the customer's choice, not an error.
    public func startScreenShare() async throws {
        try await transport.startScreenShare()
        let (state, version) = await transport.screenShareSnapshot()
        applyScreenShare(state, version: version)
    }

    /// Stops sharing. Safe to call in any state.
    public func stopScreenShare() async {
        await transport.stopScreenShare()
        let (state, version) = await transport.screenShareSnapshot()
        applyScreenShare(state, version: version)
    }

    @ObservationIgnored private var screenShareVersion = 0

    private func applyScreenShare(_ state: ScreenShareState, version: Int) {
        guard version > screenShareVersion else { return }
        screenShareVersion = version
        screenShare = state
    }

    // MARK: CallActions — what the system's actions drive

    private func configureAudioSession() throws {
        try audioSession.configureForCall(options: .call)
        installAudioObservers()
    }

    /// `didActivateAudioSession`: start the contact. The session vends credentials and connects the
    /// transport; its events drive CallKit from here on. Fire-and-forget by contract.
    private func startMedia() {
        guard let call = activeCall else { return }
        eventPump?.cancel()
        let events = session.events
        let pump = Task { @MainActor [weak self] in
            // A new subscriber is caught up with the previous contact's replay (its `.contactEnded`
            // included). Nothing counts until this contact's own `.connecting` has gone by.
            var thisContact = false
            for await event in events {
                guard let self, self.activeCall == call else { return }
                switch event {
                case .stateChanged(.connecting): thisContact = true
                case .stateChanged(.connected) where thisContact: self.manager.transportDidConnect(call: call)
                case .contactEnded(let reason) where thisContact:
                    self.lastEndReason = reason
                    self.manager.transportDidEnd(call: call, reason)
                    return
                case .failed(let error) where thisContact: self.onError?(error)
                default: break
                }
            }
        }
        eventPump = pump
        Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.session.startVoice(VoiceContactRequest(displayName: self.displayName, screenShare: self.allowsScreenShare)) }
            catch {
                let mapped = error as? TouchpointError ?? .transportFailure("\(type(of: error))")
                if self.lastEndReason == nil { self.onError?(mapped) }   // the pump already reported a transport failure
                // Two failure shapes. A transport connect failure arrives *after* `.connecting`, so the
                // session emits `.contactEnded` and the pump ends the call. A credential-vending failure
                // happens *before* `.connecting`: nothing is emitted, and without this CallKit would
                // keep a phantom call ringing and the audio observers would stay installed.
                guard self.activeCall == call, self.lastEndReason == nil else { return }
                // Both are failures the customer should hear as such ("Call failed", not "Call ended").
                if case .credentialVendingFailed = mapped { self.lastEndReason = .credentialVendingFailed }
                else { self.lastEndReason = .connectionLost }
                self.manager.transportDidEnd(call: call, self.lastEndReason ?? .connectionLost)
            }
        }
    }

    private func endMedia() async {
        await session.end()
    }

    private func applyMute(_ muted: Bool) async throws {
        try await transport.setMuted(muted)
        isMuted = muted
        if interruptionActive { mutedBeforeInterruption = muted }   // the customer's choice outlives the interruption
        announceText(muted ? TouchpointStrings.callMuted : TouchpointStrings.callUnmuted)
    }

    // MARK: State fusion

    private func managerStateChanged(_ s: CallState) {
        switch s {
        case .idle:
            // The transport's end reason arrives through the session pump; if the manager went idle
            // first (system end), fall back to customerEnded.
            if case .ended = state {} else { state = .ended(lastEndReason ?? .customerEnded) }
            removeAudioObservers()
            // Silence, so the next call's rail does not open mid-ripple. The transport clears its
            // own copy too; this covers an end the transport never saw (a system end, say).
            if isLocalSpeaking || isRemoteSpeaking {
                isLocalSpeaking = false
                isRemoteSpeaking = false
                onSpeakingChange?(false, false)
            }
            activeCall = nil
            lastEndReason = nil
            screenShare = .unavailable   // an end the transport never saw (a system end) included
        case .requesting:
            activeCall = manager.callID
            state = .requesting
        case .connecting: state = .connecting
        case .connected:
            state = .connected
            if interruptionActive { Task { @MainActor [weak self] in await self?.resumeAfterInterruption() } }
        case .interrupted: state = .interrupted
        }
    }

    private func transportReconnecting(_ reconnecting: Bool) {
        guard activeCall != nil else { return }
        if reconnecting { state = .reconnecting } else if state == .reconnecting { state = .connected }
    }

    // MARK: Audio session observers

    private func installAudioObservers() {
        guard audioObservation == nil else { return }
        audioOutput = audioSession.currentOutputName()
        audioObservation = audioSession.observe(VoiceAudioSessionHandlers(
            onRouteChange: { [weak self] reason, output in
                Task { @MainActor [weak self] in await self?.routeChanged(reason, output: output) }
            },
            onInterruptionBegan: { [weak self] in
                Task { @MainActor [weak self] in await self?.interruptionBegan() }
            },
            onInterruptionEnded: { [weak self] resume in
                Task { @MainActor [weak self] in await self?.interruptionEnded(shouldResume: resume) }
            }))
    }

    private func removeAudioObservers() {
        audioObservation = nil
    }

    /// A device arriving or leaving re-runs selection (Bluetooth connecting mid-call overwrites any
    /// earlier choice, so it must be re-made). `.override` and `.categoryChange` — the two Chime's
    /// observer drops — are what the CallKit route picker produces when the *customer* chooses the
    /// earpiece or the speaker: those are reflected and announced, never overridden.
    private func routeChanged(_ reason: VoiceRouteChangeReason, output: String?) async {
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable, .noSuitableRouteForCategory:
            await transport.reselectAudioDevice()
        case .categoryChange, .override, .wakeFromSleep, .routeConfigurationChange, .unknown:
            break
        }
        if let output, output != audioOutput {
            audioOutput = output
            announceText(TouchpointStrings.callRoute(output))
        }
    }

    /// Chime's interruption handling is telemetry-only; the SDK mutes so a half-resumed session
    /// does not leak audio, and restores the customer's own mute choice afterwards.
    private var interruptionActive = false

    private func interruptionBegan() async {
        guard !interruptionActive else { return }
        interruptionActive = true
        mutedBeforeInterruption = isMuted
        isMuted = true                               // flags first: an `.ended` must not interleave with the await
        try? await transport.setMuted(true)
        announceText(TouchpointStrings.callInterrupted)
    }

    /// `shouldResume` is advisory. CallKit's authoritative "you have audio back" is the manager
    /// leaving `.interrupted` (`didActivate`), handled in `managerStateChanged`; this covers the
    /// non-CallKit case and is a no-op when that already ran.
    private func interruptionEnded(shouldResume: Bool) async {
        guard interruptionActive, shouldResume else { return }
        await resumeAfterInterruption()
    }

    private func resumeAfterInterruption() async {
        guard interruptionActive else { return }
        interruptionActive = false
        if !mutedBeforeInterruption { isMuted = false; try? await transport.setMuted(false) }
        announceText(TouchpointStrings.callResumed)
    }

    // MARK: VoiceOver

    private func announceScreenShare(_ state: ScreenShareState, previous: ScreenShareState) {
        let wasActive = previous == .starting || previous == .sharing
        switch state {
        case .available where previous == .unavailable: announceText(TouchpointStrings.screenShareAvailable)
        case .sharing: announceText(TouchpointStrings.screenShareStarted)
        case .available, .unavailable: if wasActive { announceText(TouchpointStrings.screenShareStopped) }
        case .starting: break   // iOS's consent prompt speaks for itself
        }
    }

    private func announce(for state: VoiceCallState, previous: VoiceCallState) {
        switch state {
        case .idle, .requesting: break
        case .connecting: announceText(TouchpointStrings.callConnecting)
        case .connected: if previous != .interrupted { announceText(TouchpointStrings.callConnected) }
        case .reconnecting: announceText(TouchpointStrings.callReconnecting)
        case .interrupted: break   // announced by the audio-session interruption, which carries the reason
        case .ended(let reason):
            switch reason {
            case .connectionLost, .credentialVendingFailed: announceText(TouchpointStrings.callFailed)
            default: announceText(TouchpointStrings.callEnded)
            }
        }
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit
enum LiveAnnouncer {
    @MainActor static func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: text)
    }
}
#endif
