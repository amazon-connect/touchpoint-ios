import Foundation
import TouchpointCore

/// Where a call stands, as CallKit and the transport together see it.
public enum CallState: Sendable, Equatable {
    case idle
    /// `CXStartCallAction` requested, not yet performed by the system.
    case requesting
    /// The system performed the start; the audio session is being granted and media is joining.
    case connecting
    case connected
    /// The system took the audio session away (a cellular call came in). Media is paused by the OS;
    /// it resumes on reactivation without a rejoin. The phase underneath (connecting or connected) is
    /// restored when the session comes back.
    case interrupted
}

/// An app-placed call that participates in the operating system's telephony model.
///
/// Outbound only — `StartWebRTCContact` is client-initiated, so there is no PushKit and no
/// `reportNewIncomingCall`. The host still declares the `voip` background mode, without which
/// CallKit refuses the outbound start (`unentitled`). **CallKit is the gatekeeper, not decoration:**
///
/// 1. `startCall()` requests a `CXStartCallAction`.
/// 2. When the system performs it, the audio session's category and mode are set and the action is
///    fulfilled. Nothing else — the Connect sample's blocking network call inside the action handler
///    is the hazard not to copy.
/// 3. `didActivateAudioSession` is what starts media: credential vending and the Chime join run
///    downstream of CallKit granting the session.
///
/// Mute and end from the app go *through* CallKit (`CXSetMutedCallAction`, `CXEndCallAction`) so the
/// system call UI and ours never disagree. The transport reports connect/end back here, **tagged with
/// the call they belong to**, so CallKit's view of the call is accurate and a late event from a
/// previous call cannot touch the next one. No hold: `supportsHolding` is false.
@MainActor
public final class TouchpointCallManager: CallProviderDelegate {
    public private(set) var state: CallState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    public var onStateChange: (@MainActor (CallState) -> Void)?
    /// Configuration faults and request failures. Nothing here is thrown to a caller that could
    /// catch it, so it is delivered.
    public var onError: (@MainActor (TouchpointError) -> Void)?
    /// The current call's identifier, as CallKit knows it.
    public private(set) var callID: UUID?
    /// `UIBackgroundModes` lacked `audio` at init. Also reported through `onError`; kept as a
    /// property so a host that set `onError` late can still find out.
    public let backgroundAudioMissing: Bool

    private let provider: any CallProviding
    private let controller: any CallControlling
    private let actions: CallActions
    private let displayName: String
    private enum Phase: Equatable { case requesting, connecting, connected }
    private var phase: Phase?
    private var interrupted = false
    private var mediaStarted = false
    private var endedBySystemAction = false

    /// - Parameters:
    ///   - actions: the transport and audio-session hooks the system's actions drive.
    ///   - backgroundModes: the host's `UIBackgroundModes`. `audio` is required for a call to keep its
    ///     audio when backgrounded; a missing mode is reported now, loudly, because the symptom
    ///     otherwise appears much later as broken audio.
    ///   - displayName: what the system call UI shows as the handle (the contact centre's name).
    public init(provider: any CallProviding, controller: any CallControlling, actions: CallActions,
                backgroundModes: [String], displayName: String) {
        self.provider = provider
        self.controller = controller
        self.actions = actions
        self.displayName = displayName
        self.backgroundAudioMissing = !backgroundModes.contains("audio")
        provider.configuration = CallProviderConfiguration()
        provider.setDelegate(self)
        if backgroundAudioMissing {
            // Reported asynchronously so a host that sets `onError` right after `init` still hears it.
            Task { @MainActor [weak self] in
                self?.onError?(.invalidConfiguration("UIBackgroundModes must include `audio` for voice calls to survive backgrounding; add it to the host app's Info.plist"))
            }
        }
    }

    // MARK: App-initiated

    /// Asks the system to start an outbound call. Returns the call's identifier once the request is
    /// accepted; media starts later, when the system grants the audio session.
    @discardableResult
    public func startCall() async throws -> UUID {
        guard callID == nil else { throw TouchpointError.invalidConfiguration("a call is already in progress") }
        guard !displayName.isEmpty else { throw TouchpointError.invalidConfiguration("displayName must not be empty: it is what the system call UI shows") }
        let id = UUID()
        callID = id
        mediaStarted = false
        interrupted = false
        endedBySystemAction = false
        setPhase(.requesting)
        do {
            try await controller.request(.start(id, handle: displayName))
        } catch {
            if callID == id { finish() }
            throw TouchpointError.transportFailure("CallKit refused the start request: \(type(of: error))(\((error as NSError).code))")
        }
        // The system may have performed — and failed — the start while the request was in flight.
        guard callID == id else { throw TouchpointError.transportFailure("the call ended before it could start") }
        return id
    }

    /// Ends the call through CallKit; the system then performs `CXEndCallAction` and we stop media.
    /// If CallKit no longer knows the call (an action timed out and it dropped it), the manager
    /// recovers by ending locally rather than staying stuck with a phantom call.
    public func endCall() async throws {
        guard let callID else { return }
        do {
            try await controller.request(.end(callID))
        } catch {
            await actions.endCall()
            finish()
            throw TouchpointError.transportFailure("CallKit refused the end request: \(type(of: error))(\((error as NSError).code))")
        }
    }

    /// Mutes through CallKit so the system UI reflects it; the system performs `CXSetMutedCallAction`.
    public func setMuted(_ muted: Bool) async throws {
        guard let callID else { throw TouchpointError.invalidConfiguration("no call") }
        try await controller.request(.setMuted(callID, muted))
    }

    // MARK: Transport-reported

    /// The transport's `.connected` for `call`: tell CallKit the outgoing call connected. Events for
    /// any other call — a previous one's late echo — are ignored.
    public func transportDidConnect(call: UUID) {
        guard call == callID, phase == .connecting else { return }
        setPhase(.connected)
        provider.report(.outgoingConnected(call))
    }

    /// The transport's `.contactEnded` for `call`.
    ///
    /// - The far side or the network ending it is reported to CallKit with the mapped reason.
    /// - `.customerEnded` reached here without CallKit performing the end (the host called
    ///   `session.end()` directly): CallKit has no "local hang-up" reason, and `.failed` would show
    ///   "Call Failed" for something the customer did — so the end is *requested* through CallKit,
    ///   which then performs `CXEndCallAction` and the normal path finishes.
    /// - CallKit itself ended it (`performEndCall` ran): it already knows; nothing is reported.
    public func transportDidEnd(call: UUID, _ reason: EndReason) {
        guard call == callID else { return }
        if endedBySystemAction { finish(); return }
        if reason == .customerEnded {
            endedBySystemAction = true
            Task { @MainActor [weak self] in
                do { try await self?.controller.request(.end(call)) }
                catch {
                    // Still this call? A later call must not be finished by this one's failure.
                    guard let self, self.callID == call else { return }
                    self.provider.report(.ended(call, .failed))
                    self.finish()
                }
            }
            return
        }
        provider.report(.ended(call, Self.callEndedReason(for: reason, connected: phase == .connected)))
        finish()
    }

    static func callEndedReason(for reason: EndReason, connected: Bool) -> CallEndedReason {
        switch reason {
        case .agentEnded: return .remoteEnded
        case .systemEnded: return connected ? .failed : .unanswered
        case .customerEnded, .connectionLost, .credentialVendingFailed: return .failed
        }
    }

    private func setPhase(_ p: Phase?) {
        phase = p
        state = interrupted && p != nil ? .interrupted : (p.map { Self.state(for: $0) } ?? .idle)
    }

    private static func state(for p: Phase) -> CallState {
        switch p { case .requesting: .requesting; case .connecting: .connecting; case .connected: .connected }
    }

    private func finish() {
        callID = nil
        mediaStarted = false
        interrupted = false
        setPhase(nil)
    }

    // MARK: CallProviderDelegate — the system performing actions

    public func performStartCall(_ id: UUID) async -> Bool {
        guard id == callID, phase == .requesting else { return false }
        do {
            try actions.configureAudioSession()
        } catch {
            onError?(.transportFailure("audio session configuration failed: \(type(of: error))(\((error as NSError).code))"))
            finish()
            return false
        }
        setPhase(.connecting)
        provider.report(.outgoingStartedConnecting(id))
        return true
    }

    public func performEndCall(_ id: UUID) async -> Bool {
        guard id == callID else { return false }
        endedBySystemAction = true
        await actions.endCall()
        finish()
        return true
    }

    public func performSetMuted(_ id: UUID, _ muted: Bool) async -> Bool {
        guard id == callID else { return false }
        do { try await actions.setMuted(muted) } catch { return false }
        return true
    }

    /// The gate. Media starts here and only here, once per call. A reactivation after an
    /// interruption restores the phase the call was in — it does not invent "connected".
    public func audioSessionDidActivate() async {
        guard callID != nil, let phase else { return }
        if interrupted {
            interrupted = false
            setPhase(phase)
            return
        }
        guard phase == .connecting, !mediaStarted else { return }
        mediaStarted = true
        actions.startMedia()
    }

    public func audioSessionDidDeactivate() async {
        guard callID != nil, let phase, phase != .requesting else { return }
        interrupted = true
        setPhase(phase)
    }

    public func providerDidReset() async {
        guard callID != nil else { return }
        endedBySystemAction = true
        await actions.endCall()
        finish()
    }

    /// CallKit stopped waiting on an action we never settled. The call is gone on its side; end
    /// media and go idle so the next `startCall` is not refused for a phantom call.
    public func actionTimedOut(_ id: UUID) async {
        guard id == callID else { return }
        onError?(.transportFailure("CallKit timed out waiting for a call action"))
        endedBySystemAction = true
        await actions.endCall()
        finish()
    }
}
