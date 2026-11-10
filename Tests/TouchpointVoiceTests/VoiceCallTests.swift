import Foundation
import Testing
import TouchpointCore
@testable import TouchpointVoice

// MARK: - Audio session ordering, routing, interruptions, announcements — through the facade

/// A scripted audio session: records configuration, lets a test fire route changes and interruptions.
final class FakeAudioSession: VoiceAudioSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var _configured: [VoiceAudioSessionOptions] = []
    private var handlers: VoiceAudioSessionHandlers?
    var configureError: Error?
    var output: String? = "Speaker"
    var configured: [VoiceAudioSessionOptions] { lock.withLock { _configured } }
    var observing: Bool { lock.withLock { handlers != nil } }

    func configureForCall(options: VoiceAudioSessionOptions) throws {
        if let configureError { throw configureError }
        lock.withLock { _configured.append(options) }
    }
    func currentOutputName() -> String? { output }
    func observe(_ h: VoiceAudioSessionHandlers) -> any VoiceAudioObservationToken {
        lock.withLock { handlers = h }
        return Token { [weak self] in self?.lock.withLock { self?.handlers = nil } }
    }
    func routeChanged(_ reason: VoiceRouteChangeReason, to output: String?) { self.output = output; lock.withLock { handlers }?.onRouteChange(reason, output) }
    func interruptionBegan() { lock.withLock { handlers }?.onInterruptionBegan() }
    func interruptionEnded(shouldResume: Bool) { lock.withLock { handlers }?.onInterruptionEnded(shouldResume) }

    final class Token: VoiceAudioObservationToken, @unchecked Sendable {
        let onDeinit: () -> Void
        init(_ f: @escaping () -> Void) { onDeinit = f }
        deinit { onDeinit() }
    }
}

@MainActor
/// Shared by the call and rail suites: one fake CallKit, audio session and Chime meeting behind a
/// real `TouchpointVoiceCall`.
struct Rig {
    let call: TouchpointVoiceCall
    let sys: FakeCallSystem
    let audio: FakeAudioSession
    let meeting: FakeMeetingSession
    let session: TouchpointSession
    let announced: Capture<[String]>
    let states: Capture<[VoiceCallState]>
    /// Private, so a test posting "the app went to the background" reaches only this call.
    let notifications: NotificationCenter

    static let didEnterBackground = Notification.Name("test.didEnterBackground")
    static let willResignActive = Notification.Name("test.willResignActive")

    static func make(permission: PermissionStatus = .granted, policy: PermissionPolicy = .never, backend: (any TouchpointBackend)? = nil,
                     allowsScreenShare: Bool = false) async throws -> Rig {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-vc-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let meeting = FakeMeetingSession()
        let transport = VoiceTransport(driver: meeting)
        let session = TouchpointSession(broker: CredentialBroker(backend: backend ?? VoiceStubBackend(), keychain: InMemoryKeychainStore()), store: store, transports: [.voice: transport])
        let sys = FakeCallSystem(); let audio = FakeAudioSession()
        let announced = Capture<[String]>([]); let states = Capture<[VoiceCallState]>([])
        let notifications = NotificationCenter()
        let call = TouchpointVoiceCall(session: session, transport: transport, provider: sys, controller: sys, audioSession: audio,
                                       permissions: ScriptedMic(permission), permissionPolicy: policy,
                                       backgroundModes: ["audio"], displayName: "Acme Bank",
                                       allowsScreenShare: allowsScreenShare,
                                       notificationCenter: notifications, backgroundNotification: didEnterBackground,
                                       announce: { announced.value.append($0) })
        call.onStateChange = { states.value.append($0) }
        return Rig(call: call, sys: sys, audio: audio, meeting: meeting, session: session, announced: announced, states: states,
                   notifications: notifications)
    }

    /// Drive the system's side of a successful start up to media joining: the Chime join has been
    /// requested (so the fake's callbacks have somewhere to land) but has not started.
    func systemStarts() async throws -> UUID {
        let id = try #require(call.callID)
        #expect(await sys.performStart(id))
        await sys.activateAudio()
        #expect(await eventuallyOnMain { meeting.started.count >= 1 }, "credentials vended and the join requested")
        return id
    }
}

/// A backend whose vend fails — the failure shape that happens *before* the session emits anything.
actor FailingVoiceBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { throw TouchpointError.invalidConfiguration("voice only") }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        throw TouchpointError.credentialVendingFailed(underlying: "URLError(-1009)")
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
}

struct ScriptedMic: PermissionRequesting {
    let status: PermissionStatus
    init(_ s: PermissionStatus) { status = s }
    func status(of permission: Permission) async -> PermissionStatus { status }
    func requestIfAllowed(_ permission: Permission, policy: PermissionPolicy) async -> PermissionStatus {
        policy.allows(permission) ? .granted : status
    }
}

@Suite("TouchpointVoiceCall: audio session, routing, interruptions, announcements", .serialized)
@MainActor
struct VoiceCallTests {
    @Test("A1: the audio session is configured inside the start action, with the call options, before media; never activated by us")
    func configureOrdering() async throws {
        let rig = try await Rig.make()
        try await rig.call.start()
        #expect(rig.audio.configured.isEmpty, "not before the system performs the start")
        let id = try #require(rig.call.callID)
        #expect(await rig.sys.performStart(id))
        #expect(rig.audio.configured == [.call], "set in the CXStartCallAction handler, before fulfil")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.meeting.started.isEmpty, "media waits for didActivate")
        await rig.sys.activateAudio()
        #expect(await eventuallyOnMain { rig.meeting.started.count == 1 })
    }

    @Test("A2: the Bluetooth hands-free option is in the call options, and the compiler fork resolves to the SDK's spelling")
    func bluetoothOption() {
        #expect(VoiceAudioSessionOptions.call.contains(.allowBluetoothHandsFree))
        #expect(VoiceAudioSessionOptions.call.contains(.defaultToSpeaker))
        #expect(!VoiceAudioSessionOptions.call.contains(.allowBluetoothA2DP), "A2DP is output-only; a call needs the microphone")
    }

    @Test("A3: a route change — including categoryChange and override, which Chime drops — re-selects the device and announces the output")
    func routeChange() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); _ = try await rig.systemStarts()
        rig.meeting.started(); await Task.yield()
        rig.meeting.devices = [VoiceAudioDevice(label: "Pods", kind: .bluetooth), VoiceAudioDevice(label: "Speaker", kind: .speaker)]
        let chosenBefore = rig.meeting.chosenDevices.count
        rig.audio.routeChanged(.newDeviceAvailable, to: "Pods")                 // Bluetooth connected mid-call
        #expect(await eventuallyOnMain { rig.meeting.chosenDevices.last?.label == "Pods" })
        #expect(rig.meeting.chosenDevices.count == chosenBefore + 1)
        // The customer picks the speaker in the CallKit route menu: reflected and announced, not overridden.
        rig.audio.routeChanged(.override, to: "Speaker")
        #expect(await eventuallyOnMain { rig.announced.value.contains { $0.contains("Speaker") } })
        #expect(rig.meeting.chosenDevices.count == chosenBefore + 1, "an override is the customer's choice; the SDK does not re-pick Bluetooth over it")
        rig.audio.routeChanged(.categoryChange, to: "Speaker")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.meeting.chosenDevices.count == chosenBefore + 1)
        #expect(rig.announced.value.contains { $0.contains("Pods") })
    }

    @Test("A4: an interruption mutes and announces; its end with shouldResume unmutes and announces resumed; without it the mic stays muted")
    func interruption() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        rig.audio.interruptionBegan()
        #expect(await eventuallyOnMain { rig.meeting.muteCalls.last == true })
        #expect(rig.announced.value.contains(TouchpointStrings.callInterrupted))
        rig.audio.interruptionEnded(shouldResume: true)
        #expect(await eventuallyOnMain { rig.meeting.muteCalls.last == false })
        #expect(rig.announced.value.contains(TouchpointStrings.callResumed))

        rig.audio.interruptionBegan()
        _ = await eventuallyOnMain { rig.meeting.muteCalls.last == true }
        let before = rig.meeting.muteCalls.count
        rig.audio.interruptionEnded(shouldResume: false)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.meeting.muteCalls.count == before, "no resume hint from AVAudioSession: nothing yet")
        #expect(rig.call.isMuted)
        // CallKit's authoritative signal: the audio session deactivates and reactivates.
        await rig.sys.deactivateAudio(); await rig.sys.activateAudio()
        #expect(await eventuallyOnMain { rig.meeting.muteCalls.last == false }, "didActivate after the interruption restores the microphone")
        #expect(!rig.call.isMuted)
        _ = id
    }

    @Test("A4b: a mute the customer set before the interruption is not undone by its end")
    func interruptionRespectsUserMute() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started()
        _ = await eventuallyOnMain { rig.call.state == .connected }
        try await rig.call.setMuted(true); _ = await rig.sys.performMute(id, true)
        #expect(await eventuallyOnMain { rig.call.isMuted })
        rig.audio.interruptionBegan()
        rig.audio.interruptionEnded(shouldResume: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.call.isMuted, "the customer muted; the interruption does not unmute for them")
    }

    @Test("A6: every call-state change is announced for VoiceOver with a catalog string, never a raw key")
    func announcements() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); _ = try await rig.systemStarts()
        rig.meeting.started()
        _ = await eventuallyOnMain { rig.call.state == .connected }
        rig.meeting.dropped(); _ = await eventuallyOnMain { rig.call.state == .reconnecting }
        rig.meeting.started(reconnecting: true); _ = await eventuallyOnMain { rig.call.state == .connected }
        rig.meeting.stopped(.audioCallEnded)
        #expect(await eventuallyOnMain { rig.call.state == .ended(.agentEnded) })
        #expect(rig.announced.value.contains(TouchpointStrings.callConnecting))
        #expect(rig.announced.value.contains(TouchpointStrings.callConnected))
        #expect(rig.announced.value.contains(TouchpointStrings.callReconnecting))
        #expect(rig.announced.value.contains(TouchpointStrings.callEnded))
        #expect(rig.announced.value.allSatisfy { !$0.hasPrefix("touchpoint.") })
        #expect(rig.states.value.first == .requesting)
    }

    @Test("A6b: mute and unmute are announced; a lost call announces failed")
    func muteAndFailureAnnouncements() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        _ = await rig.sys.performMute(id, true)
        #expect(await eventuallyOnMain { rig.announced.value.contains(TouchpointStrings.callMuted) })
        _ = await rig.sys.performMute(id, false)
        #expect(await eventuallyOnMain { rig.announced.value.contains(TouchpointStrings.callUnmuted) })
        rig.meeting.dropped(); rig.meeting.cancelledReconnect()
        #expect(await eventuallyOnMain { rig.call.state == .ended(.connectionLost) })
        #expect(rig.announced.value.contains(TouchpointStrings.callFailed))
        #expect(rig.sys.reported.last == .ended(id, .failed))
    }

    @Test("A7: the microphone — denied is a product state surfaced before any CallKit request; not-determined is asked only with host opt-in")
    func microphonePermission() async throws {
        let denied = try await Rig.make(permission: .denied)
        do { try await denied.call.start(); Issue.record("expected a throw") }
        catch let TouchpointError.permissionDenied(p) { #expect(p == .microphone) }
        #expect(denied.sys.requested.isEmpty)
        #expect(denied.call.permissionDenial?.consequence == .voiceUnavailableChatRemains)

        let undetermined = try await Rig.make(permission: .notDetermined, policy: .never)
        do { try await undetermined.call.start(); Issue.record("expected a throw") }
        catch let TouchpointError.permissionDenied(p) { #expect(p == .microphone) }
        #expect(undetermined.sys.requested.isEmpty, "the SDK never asks without opt-in")

        let optedIn = try await Rig.make(permission: .notDetermined, policy: PermissionPolicy(mayRequest: [.microphone]))
        try await optedIn.call.start()
        #expect(optedIn.sys.requested.count == 1)
    }

    @Test("E1: ending from the app goes through CallKit; the system performing it stops media and the session ends as customerEnded")
    func endFromApp() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        try await rig.call.end()
        #expect(rig.sys.requested.last == .end(id))
        #expect(await rig.sys.performEnd(id))
        #expect(await eventuallyOnMain { rig.session.state == .ended(.customerEnded) })
        #expect(rig.meeting.stopCount == 1)
        #expect(rig.call.state == .ended(.customerEnded))
    }

    @Test("E2: a second call after the first ended works end to end (the facade is reusable)")
    func secondCall() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let first = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.session.state == .ended(.customerEnded) })
        #expect(await eventuallyOnMain { rig.call.state == .ended(.customerEnded) })
        try await rig.call.start()
        let second = try #require(rig.call.callID)
        #expect(second != first)
        #expect(await rig.sys.performStart(second))
        await rig.sys.activateAudio()
        #expect(await eventuallyOnMain { rig.meeting.started.count == 2 }, "second join requested; session state \(rig.session.state), call \(rig.call.state)")
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected }, "call \(rig.call.state) session \(rig.session.state)")
    }

    @Test("E4: a credential-vending failure — before the session emits anything — still ends the CallKit call and releases the observers")
    func vendFailureEndsCall() async throws {
        let rig = try await Rig.make(backend: FailingVoiceBackend())
        let errors = Capture<[TouchpointError]>([]); rig.call.onError = { errors.value.append($0) }
        try await rig.call.start()
        let id = try #require(rig.call.callID)
        #expect(await rig.sys.performStart(id)); await rig.sys.activateAudio()
        #expect(await eventuallyOnMain { rig.call.state == .ended(.credentialVendingFailed) })
        #expect(rig.sys.reported.last == .ended(id, .failed), "CallKit is told; no phantom call")
        #expect(!rig.audio.observing)
        #expect(rig.meeting.started.isEmpty)
        #expect(errors.value.contains { if case .credentialVendingFailed = $0 { true } else { false } })
        #expect(rig.announced.value.contains(TouchpointStrings.callFailed))
        try await rig.call.start()                                      // and the facade is usable again
    }

    @Test("A4c: a mute the customer sets *during* an interruption is the new baseline — its end does not unmute")
    func muteDuringInterruption() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        rig.audio.interruptionBegan()
        _ = await eventuallyOnMain { rig.call.isMuted }
        _ = await rig.sys.performMute(id, true)                                 // system UI mute mid-interruption
        rig.audio.interruptionEnded(shouldResume: true)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(rig.call.isMuted, "the customer muted; the interruption's end does not undo it")
    }

    @Test("M1: mute does not carry over into the next call")
    func muteDoesNotCarryOver() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let first = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        _ = await rig.sys.performMute(first, true)
        #expect(await eventuallyOnMain { rig.call.isMuted })
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.call.state == .ended(.customerEnded) })
        try await rig.call.start(); _ = try await rig.systemStarts()
        #expect(rig.meeting.started.last?.startMuted == false, "the second join starts with the microphone live, as both UIs show")
        #expect(!rig.call.isMuted)
    }

    @Test("M5: the system activating the audio session before the start request returns still starts media")
    func activationBeforeRequestReturns() async throws {
        let rig = try await Rig.make()
        rig.sys.performStartDuringRequest = true
        rig.sys.activateDuringRequest = true
        try await rig.call.start()
        #expect(await eventuallyOnMain { rig.meeting.started.count == 1 }, "media started although didActivate preceded the request's return")
    }

    @Test("E5: shutdown() ends the call and waits for it, so a host may release the facade without stranding the meeting")
    func shutdownWaits() async throws {
        let rig = try await Rig.make()
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        let done = Task { @MainActor in await rig.call.shutdown() }
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(id)) })
        _ = await rig.sys.performEnd(id)
        await done.value
        #expect(rig.call.callID == nil)
        #expect(rig.meeting.stopCount == 1)
        #expect(await eventuallyOnMain { rig.session.state == .ended(.customerEnded) })
    }

    @Test("E6: mute changes are observable — from the app, the system UI, and an interruption")
    func muteObservable() async throws {
        let rig = try await Rig.make()
        let seen = Capture<[Bool]>([]); rig.call.onMuteChange = { seen.value.append($0) }
        try await rig.call.start(); let id = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        _ = await rig.sys.performMute(id, true); _ = await rig.sys.performMute(id, false)
        rig.audio.interruptionBegan()
        #expect(await eventuallyOnMain { seen.value == [true, false, true] })
    }

    @Test("E3: the audio observers are installed for the call and released when it ends")
    func observersLifecycle() async throws {
        let rig = try await Rig.make()
        #expect(!rig.audio.observing)
        try await rig.call.start(); let id = try await rig.systemStarts()
        #expect(rig.audio.observing)
        _ = await rig.sys.performEnd(id)
        #expect(await eventuallyOnMain { !rig.audio.observing })
    }
}
