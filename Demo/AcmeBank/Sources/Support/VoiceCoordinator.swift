import Foundation
import Observation
import TouchpointCore
import TouchpointVoice

/// Voice for the demo: "Call us" places a WebRTC call to the Connect instance
/// through CallKit, with the system call UI's mute and end working alongside ours.
///
/// Its own `TouchpointSession` over the same broker as chat — a session has one active contact and the
/// chat one may be mid-conversation. The call lands on `touchpoint-voice-livesync`, the same flow
/// Live Sync voice uses, so the assistant that drives the screens is the one who answers.
@MainActor
@Observable
final class VoiceCoordinator {
    private(set) var call: TouchpointVoiceCall?
    private(set) var state: VoiceCallState = .idle
    private(set) var lastError: String?
    /// Set when the microphone is denied: the dock shows `PermissionDenialView` with a Settings link.
    private(set) var permissionDenial: PermissionDenial?
    private(set) var isMuted = false
    var isAvailable: Bool { configure != nil }

    /// Ring-my-phone mode (Android's "voice by phone", `POST /voice/call`): Connect calls the
    /// customer's phone, so there is no in-app call — only the contact, which Live Sync binds to.
    /// `usesPhone` is read at each tap, so the Settings switch takes effect without a relaunch.
    private var placePhoneCall: (@MainActor () async throws -> String)?
    var usesPhone: @MainActor () -> Bool = { false }
    /// What the dock says while Connect rings the phone; nil otherwise.
    private(set) var phoneCallStatus: String?

    func enablePhoneCall(_ place: @escaping @MainActor () async throws -> String) { placePhoneCall = place }

    /// The contact the call just created. Live Sync binds to it so the assistant can drive the
    /// screens without anyone typing a contact id — the same handoff chat already does. Mirrors the
    /// web PoC's `onContactStarted`, which reads `ContactId` out of its own backend reply rather
    /// than asking the customer for it.
    var onContactStarted: ((String) -> Void)?

    /// Retained so the contact id is readable once the call reaches `.connected`; a second call
    /// replaces the contact, so this is re-read on every connection rather than cached.
    private var session: TouchpointSession?

    /// Builds the session + transport for a call. Set by the support coordinator in live mode.
    private var configure: (@MainActor () async throws -> (TouchpointSession, VoiceTransport))?

    func enable(_ configure: @escaping @MainActor () async throws -> (TouchpointSession, VoiceTransport)) {
        self.configure = configure
    }

    /// Leaving live mode: end any call, drop the facade (and the live session and broker it holds),
    /// and hide the button. Without this a later offline run could place a real call on stale credentials.
    func disable() async {
        await call?.shutdown()
        call = nil
        session = nil
        configure = nil
        placePhoneCall = nil
        phoneCallStatus = nil
        onContactStarted = nil
        state = .idle
        permissionDenial = nil
        // Offline mode hides the microphone, so `startCall` — the only thing that clears this —
        // becomes unreachable; a live-mode error would otherwise sit in the dock forever.
        lastError = nil
    }

    /// The customer chose to keep typing instead of granting the microphone.
    func dismissDenial() { permissionDenial = nil }

    var isInCall: Bool {
        switch state { case .idle, .ended: false; default: true }
    }

    func startCall() async {
        lastError = nil
        permissionDenial = nil
        if let placePhoneCall, usesPhone() {
            phoneCallStatus = "Calling your phone…"
            do {
                let id = try await placePhoneCall()
                phoneCallStatus = "Your phone is ringing. Answer to talk to the assistant."
                print("[voice] phone contact \(id)")
                onContactStarted?(id)
            } catch {
                phoneCallStatus = nil
                lastError = Self.describe(error)
                print("[voice] phone call failed: \(error)")
            }
            return
        }
        do {
            if call == nil {
                guard let configure else { lastError = "Voice mode needs live mode — Settings → Support mode."; return }
                let (session, voice) = try await configure()
                self.session = session
                // The host opts in to the SDK asking for the microphone at the moment of the call —
                // the natural moment, and the demo has no earlier onboarding screen for it. Screen
                // sharing too: the demo backend allows it on `StartWebRTCContact` when asked, and the
                // rail offers it only once the agent opens a session.
                let c = TouchpointVoiceCall(session: session, transport: voice, displayName: PartnerBrand.bankName,
                                            permissionPolicy: PermissionPolicy(mayRequest: [.microphone]),
                                            allowsScreenShare: true)
                c.onStateChange = { [weak self] s in
                    guard let self else { return }
                    self.state = s
                    print("[voice] state → \(s)")
                    // A call that connects supersedes an earlier error. Not on `.ended`: a failed
                    // start reports its error and then ends, and clearing there erased the reason.
                    if s == .connected { self.lastError = nil }
                    // Bind Live Sync here, not after `start()`. `start()` returns once CallKit has
                    // accepted the request; the contact itself is created later, when CallKit
                    // activates the audio session and `session.startVoice` runs in its own task. At
                    // `start()`'s return `contactID` is still nil — reading it there bound nothing,
                    // and Live Sync stayed on whatever contact it had before (the chat's), so the
                    // voice assistant's actions went to a conversation the app was not listening to.
                    // `.connected` is the first state at which the contact is guaranteed to exist.
                    // Every start is a fresh StartWebRTCContact with a new id, so this fires per
                    // call and rebinds rather than holding a dead contact.
                    if s == .connected, let id = self.session?.contactID {
                        print("[voice] contact \(id)")
                        self.onContactStarted?(id)
                    }
                }
                c.onMuteChange = { [weak self] m in self?.isMuted = m }
                c.onError = { [weak self] e in self?.lastError = Self.describe(e); print("[voice] error: \(e)") }
                call = c
            }
            try await call?.start()
        } catch TouchpointError.permissionDenied(.microphone) {
            permissionDenial = call?.permissionDenial ?? PermissionDenial(.microphone)
            print("[voice] microphone denied")
        } catch {
            lastError = Self.describe(error)
            print("[voice] start failed: \(error)")
        }
    }

    func endCall() async {
        try? await call?.end()
    }

    func toggleMute() async {
        guard let call else { return }
        do { try await call.setMuted(!call.isMuted) } catch { lastError = Self.describe(error) }
        // `isMuted` follows the facade's `onMuteChange`, which fires when CallKit has performed the action.
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? TouchpointError {
            switch e {
            case .invalidConfiguration(let m): return m
            case .httpFailure(let code, _): return "backend returned \(code)"
            case .permissionDenied(let p): return "\(p.rawValue) permission denied"
            case .transportFailure(let m): return m
            default: return "\(e)"
            }
        }
        return "\(type(of: error))"
    }
}
