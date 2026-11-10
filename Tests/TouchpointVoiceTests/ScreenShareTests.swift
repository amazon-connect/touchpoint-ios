import Foundation
import Testing
import TouchpointCore
@testable import TouchpointVoice

// MARK: - Customer → agent screen sharing over Chime content share
//
// The SDK only routes Connect's signal and starts and stops Chime's own capture and content share;
// these tests cover that routing, the state machine and the facade. What Chime does with the frames
// is a device test (plan "Device validation").

/// Thread-safe record of what the transport's screen-share observer was told.
final class ShareStates: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [ScreenShareState] = []
    var values: [ScreenShareState] { lock.withLock { _values } }
    func add(_ s: ScreenShareState) { lock.withLock { _values.append(s) } }
}

/// Records each voice request so a test can read what reached the host backend.
actor RecordingVoiceBackend: TouchpointBackend {
    private(set) var requests: [VoiceContactRequest] = []
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        throw TouchpointError.invalidConfiguration("voice only")
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        requests.append(request)
        return VoiceFixtures.credentials()
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
}

@Suite("Screen share: request encoding")
struct ScreenShareRequestTests {
    @Test("T1: screenShare is encoded only when true, and decodes as false when absent")
    func requestEncoding() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceContactRequest(displayName: "a"))) as? [String: Any]
        #expect(plain?["screenShare"] == nil, "a host that did not opt in sends exactly today's body")
        let opted = try JSONSerialization.jsonObject(with: JSONEncoder().encode(VoiceContactRequest(displayName: "a", screenShare: true))) as? [String: Any]
        #expect(opted?["screenShare"] as? Bool == true)
        let decoded = try JSONDecoder().decode(VoiceContactRequest.self, from: Data(#"{"displayName":"a","attributes":{}}"#.utf8))
        #expect(decoded.screenShare == false)
        let roundTrip = try JSONDecoder().decode(VoiceContactRequest.self, from: JSONEncoder().encode(VoiceContactRequest(displayName: "a", screenShare: true)))
        #expect(roundTrip.screenShare)
    }
}

@Suite("Screen share: transport state machine")
struct ScreenShareTransportTests {
    /// A connected transport that asked Chime for the screen-share signal.
    private func connected(allows: Bool = true) async throws -> (VoiceTransport, FakeMeetingSession, TransportEventLog, Task<Void, Never>, ShareStates) {
        let fake = FakeMeetingSession()
        let t = VoiceTransport(driver: fake)
        let states = ShareStates()
        await t.setScreenShareObserver { state, _ in states.add(state) }
        await t.setAllowsScreenShare(allows)
        let (log, pump) = attachLog(t)
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        _ = await log.waitFor(1)
        return (t, fake, log, pump, states)
    }

    private func sharing() async throws -> (VoiceTransport, FakeMeetingSession, Task<Void, Never>) {
        let (t, fake, _, pump, _) = try await connected()
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        try await t.startScreenShare()
        fake.shareStarted()
        #expect(await eventually { await t.screenShare == .sharing })
        return (t, fake, pump)
    }

    @Test("T2: connected; ScreenSharingStarted makes sharing available, observer told once")
    func startedSignal() async throws {
        let (t, fake, _, pump, states) = try await connected(); defer { pump.cancel() }
        #expect(await t.screenShare == .unavailable)
        #expect(fake.started.first?.screenShare == true, "the driver registers the data-message observer only when asked")
        fake.shareSignal("ScreenSharingStarted")
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        try await Task.sleep(for: .milliseconds(30))
        #expect(states.values == [.available], "a repeated signal is not a change")
    }

    @Test("T2b: reconnecting still accepts the signal")
    func startedWhileReconnecting() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        fake.dropped()
        #expect(await eventually { await t.isReconnecting })
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
    }

    @Test("T3: a signal before the join completes is ignored")
    func signalWhileJoining() async throws {
        let fake = FakeMeetingSession()
        let t = VoiceTransport(driver: fake)
        await t.setAllowsScreenShare(true)
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.shareSignal("ScreenSharingStarted")
        fake.started()
        _ = await log.waitFor(1)   // the inbox is ordered: the signal was processed while joining
        #expect(await t.screenShare == .unavailable)
    }

    @Test("T4: starting while unavailable throws and never reaches Chime")
    func startUnavailable() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        await #expect(throws: TouchpointError.self) { try await t.startScreenShare() }
        #expect(fake.shareStarts == 0)
    }

    @Test("T4b: starting twice throws the second time; Chime is asked once")
    func startTwice() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        try await t.startScreenShare()
        #expect(await t.screenShare == .starting, "returns once starting — never waits on the consent prompt")
        await #expect(throws: TouchpointError.self) { try await t.startScreenShare() }
        #expect(fake.shareStarts == 1)
    }

    @Test("T5: content share started moves starting → sharing")
    func startsSharing() async throws {
        let (t, _, pump) = try await sharing(); defer { pump.cancel() }
        #expect(await t.screenShare == .sharing)
    }

    @Test("T6/T7: the agent ending the session, or a view-only session, stops sharing", arguments: ["ScreenSharingStopped", "ScreenSharingStartedViewOnly"])
    func agentStops(_ signal: String) async throws {
        let (t, fake, pump) = try await sharing(); defer { pump.cancel() }
        fake.shareSignal(signal)
        #expect(await eventually { await t.screenShare == .unavailable })
        #expect(fake.shareStops == 1)
    }

    @Test("T6b: Stopped while only available stops nothing")
    func stoppedWhileAvailable() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        fake.shareSignal("ScreenSharingStopped")
        #expect(await eventually { await t.screenShare == .unavailable })
        #expect(fake.shareStops == 0)
    }

    @Test("T8: a failed or declined capture returns to available")
    func captureFails() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        try await t.startScreenShare()
        fake.shareStopped(failed: true)
        #expect(await eventually { await t.screenShare == .available })
    }

    @Test("T8b: the customer stopping returns to available and stops Chime")
    func customerStops() async throws {
        let (t, fake, pump) = try await sharing(); defer { pump.cancel() }
        await t.stopScreenShare()
        #expect(await t.screenShare == .available)
        #expect(fake.shareStops == 1)
        fake.shareStopped(failed: false)   // Chime's own confirmation lands afterwards: no change
        try await Task.sleep(for: .milliseconds(30))
        #expect(await t.screenShare == .available)
    }

    @Test("T9/T9b: the contact ending makes sharing unavailable; later signals are ignored; a new call starts unavailable")
    func contactEnds() async throws {
        let (t, fake, pump) = try await sharing(); defer { pump.cancel() }
        fake.stopped(.audioCallEnded)
        #expect(await eventually { await t.screenShare == .unavailable })
        fake.shareSignal("ScreenSharingStarted")
        try await Task.sleep(for: .milliseconds(30))
        #expect(await t.screenShare == .unavailable)

        try await t.connect(credentials: VoiceFixtures.credentials())
        #expect(await t.screenShare == .unavailable)
    }

    @Test("T10: content attendees (#content) are neither participants, speakers nor leavers")
    func contentAttendeesFiltered() async throws {
        let (t, fake, log, pump, _) = try await connected(); defer { pump.cancel() }
        let speaking = ShareStates()   // reused as a flag sink
        await t.setSpeakingObserver { _, remote in if remote { speaking.add(.sharing) } }
        fake.join("att-local#content", externalUserID: "")
        fake.join("agent-1", externalUserID: "x-agent")
        fake.join("agent-1#content", externalUserID: "x-agent")
        fake.volume([VoiceVolume(attendeeID: "agent-1#content", isAudible: true)])
        fake.leave("att-local#content")
        fake.join("sentinel", externalUserID: "x-agent")
        let events = await log.waitFor(3)
        let joins = events.compactMap { if case .participantJoined(let p) = $0 { p.id } else { nil } }
        #expect(joins == ["agent-1", "sentinel"], "one agent joined, not a second for its share")
        #expect(!events.contains { if case .participantLeft = $0 { true } else { false } })
        #expect(speaking.values.isEmpty)
        _ = t
    }

    @Test("T12: content share starting without a request is stopped")
    func unrequestedStart() async throws {
        let (t, fake, _, pump, _) = try await connected(); defer { pump.cancel() }
        fake.shareSignal("ScreenSharingStarted")
        #expect(await eventually { await t.screenShare == .available })
        fake.shareStarted()
        #expect(await eventually { fake.shareStops == 1 })
        #expect(await t.screenShare == .available)
    }

    @Test("T13: malformed or unknown signals change nothing")
    func malformedSignals() async throws {
        let (t, fake, _, pump, states) = try await connected(); defer { pump.cancel() }
        fake.shareSignalRaw(Data("nope".utf8))
        fake.shareSignalRaw(Data(#"{"message":5}"#.utf8))
        fake.shareSignalRaw(Data("[]".utf8))
        fake.shareSignal("SomethingElse")
        fake.shareSignal("ScreenSharingStarted")   // ordered after the junk
        #expect(await eventually { await t.screenShare == .available })
        #expect(states.values == [.available])
    }

    @Test("T15: without opt-in the driver is not asked for the signal")
    func notOptedIn() async throws {
        let (_, fake, _, pump, _) = try await connected(allows: false); defer { pump.cancel() }
        #expect(fake.started.first?.screenShare == false)
    }
}

@Suite("Screen share: session and facade", .serialized)
@MainActor
struct ScreenShareFacadeTests {
    @Test("T10b: our own #content attendee does not hold the human-present gate after the agent leaves")
    func contentDoesNotHoldGate() async throws {
        let fake = FakeMeetingSession()
        let transport = VoiceTransport(driver: fake)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-ss-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let session = TouchpointSession(broker: CredentialBroker(backend: VoiceStubBackend(), keychain: InMemoryKeychainStore()),
                                        store: store, transports: [.voice: transport])
        try await session.startVoice(VoiceContactRequest(displayName: "a"))
        fake.started()
        #expect(await eventuallyOnMain { session.state == .connected })
        fake.join("agent-1", externalUserID: "x-agent")
        fake.join("att-local#content", externalUserID: "")
        #expect(await eventuallyOnMain { (try? await session.participants().humanAgentPresent) == true })
        fake.leave("agent-1", externalUserID: "x-agent")
        #expect(await eventuallyOnMain { (try? await session.participants().humanAgentPresent) == false })
        await session.end()
    }

    private func connected(allows: Bool = true, backend: (any TouchpointBackend)? = nil) async throws -> Rig {
        let rig = try await Rig.make(backend: backend, allowsScreenShare: allows)
        try await rig.call.start()
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        return rig
    }

    private func sharing() async throws -> Rig {
        let rig = try await connected()
        rig.meeting.shareSignal("ScreenSharingStarted")
        #expect(await eventuallyOnMain { rig.call.screenShare == .available })
        try await rig.call.startScreenShare()
        rig.meeting.shareStarted()
        #expect(await eventuallyOnMain { rig.call.screenShare == .sharing })
        return rig
    }

    @Test("T15/T1: the opt-in reaches the backend request and the driver; without it neither changes")
    func optIn() async throws {
        let backend = RecordingVoiceBackend()
        let rig = try await connected(allows: true, backend: backend)
        #expect(await backend.requests.first?.screenShare == true)
        #expect(rig.meeting.started.first?.screenShare == true)

        let plainBackend = RecordingVoiceBackend()
        let plain = try await connected(allows: false, backend: plainBackend)
        #expect(await plainBackend.requests.first?.screenShare == false)
        #expect(plain.meeting.started.first?.screenShare == false)
    }

    @Test("Every change is announced: available, sharing, stopped")
    func announcements() async throws {
        let rig = try await sharing()
        #expect(rig.announced.value.contains(TouchpointStrings.screenShareAvailable))
        #expect(rig.announced.value.contains(TouchpointStrings.screenShareStarted))
        await rig.call.stopScreenShare()
        #expect(await eventuallyOnMain { rig.call.screenShare == .available })
        #expect(await eventuallyOnMain { rig.announced.value.last == TouchpointStrings.screenShareStopped })
    }

    @Test("T8: a declined capture is announced and is not an error")
    func declineIsNotAnError() async throws {
        let rig = try await connected()
        let errors = Capture<[TouchpointError]>([])
        rig.call.onError = { errors.value.append($0) }
        rig.meeting.shareSignal("ScreenSharingStarted")
        #expect(await eventuallyOnMain { rig.call.screenShare == .available })
        try await rig.call.startScreenShare()
        rig.meeting.shareStopped(failed: true)
        #expect(await eventuallyOnMain { rig.announced.value.last == TouchpointStrings.screenShareStopped })
        #expect(rig.call.screenShare == .available)
        #expect(errors.value.isEmpty)
    }

    @Test("T11/T11b: going to the background stops sharing; resigning active (the consent prompt) does not")
    func background() async throws {
        let rig = try await sharing()
        rig.notifications.post(name: Rig.willResignActive, object: nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(rig.call.screenShare == .sharing)
        #expect(rig.meeting.shareStops == 0)

        rig.notifications.post(name: Rig.didEnterBackground, object: nil)
        #expect(await eventuallyOnMain { rig.call.screenShare == .available })
        #expect(rig.meeting.shareStops == 1)
    }

    @Test("Starting through the facade while unavailable throws")
    func facadeStartUnavailable() async throws {
        let rig = try await connected()
        await #expect(throws: TouchpointError.self) { try await rig.call.startScreenShare() }
        #expect(rig.meeting.shareStarts == 0)
    }

    @Test("Ending the call while sharing leaves the facade unavailable")
    func callEndsWhileSharing() async throws {
        let rig = try await sharing()
        rig.meeting.stopped(.audioCallEnded)
        #expect(await eventuallyOnMain { rig.call.screenShare == .unavailable })
    }

    @Test("T14: the rail's share control — absent only when unavailable, selected while starting or sharing")
    func railControl() {
        #expect(VoiceMiniRail.controls(hasMenu: false, screenShare: .unavailable) == [.speakers, .microphone, .audioRoute, .close])
        #expect(VoiceMiniRail.controls(hasMenu: true, screenShare: .available) == [.menu, .speakers, .microphone, .audioRoute, .screenShare, .close])
        #expect(VoiceMiniRail.controls(hasMenu: false, screenShare: .sharing) == [.speakers, .microphone, .audioRoute, .screenShare, .close])
        #expect(!VoiceMiniRail.isSharing(.available))
        #expect(VoiceMiniRail.isSharing(.starting))
        #expect(VoiceMiniRail.isSharing(.sharing))
        #expect(!VoiceMiniRail.isSharing(.unavailable))
    }
}
