import Foundation
import Testing
import TouchpointCore
@testable import TouchpointVoice

// MARK: - The full-screen voice view's state logic
//
// Tested through the model and the pure screen decision, never a rendered view (SwiftUI builds no
// accessibility tree off-screen, and Chime is iOS-only): the integrator verifies the look on a
// device. The model drives the real `TouchpointVoiceCall` facade over the same fakes the call and
// rail suites use, so "the view starts / restarts / ends the call" is exercised end to end.

@Suite("Full-screen voice view model (VO-1…VO-5)", .serialized)
@MainActor
struct VoiceViewModelTests {

    /// Starts the view's call and drives the system to connected, mirroring the call's state into
    /// the model as the SwiftUI `onChange` would.
    private func connectedModel(sleeper: HeldVoiceClock? = nil) async throws -> (Rig, TouchpointVoiceModel) {
        let rig = try await Rig.make()
        let model = sleeper.map { TouchpointVoiceModel(call: rig.call, firstJoinTimeout: .seconds(30), sleeper: $0) }
            ?? TouchpointVoiceModel(call: rig.call)
        model.appear()
        #expect(await eventuallyOnMain { rig.call.callID != nil }, "appear() started the call")
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        model.callStateChanged(rig.call.state)
        return (rig, model)
    }

    // MARK: VO-1 / VO-2 — the pure screen decision

    @Test("The screen follows the call: connecting, live, ended once connected, failed when it never did")
    func screenDecision() {
        #expect(VoiceScreen.screen(callState: .idle, everConnected: false, failed: false) == .connecting)
        #expect(VoiceScreen.screen(callState: .requesting, everConnected: false, failed: false) == .connecting)
        #expect(VoiceScreen.screen(callState: .connecting, everConnected: false, failed: false) == .connecting)
        #expect(VoiceScreen.screen(callState: .connected, everConnected: true, failed: false) == .live)
        // A Chime reconnect or a system interruption keeps the live call on screen.
        #expect(VoiceScreen.screen(callState: .reconnecting, everConnected: true, failed: false) == .live)
        #expect(VoiceScreen.screen(callState: .interrupted, everConnected: true, failed: false) == .live)
        // Web's rule: ended once connected; the error screen is only for a call that never connected.
        #expect(VoiceScreen.screen(callState: .ended(.agentEnded), everConnected: true, failed: false) == .ended)
        #expect(VoiceScreen.screen(callState: .ended(.customerEnded), everConnected: true, failed: false) == .ended)
        #expect(VoiceScreen.screen(callState: .ended(.connectionLost), everConnected: false, failed: false) == .failed)
        // A start that threw (mic denied) or the first-join timeout forces failed, whatever the state.
        #expect(VoiceScreen.screen(callState: .connecting, everConnected: false, failed: true) == .failed)
    }

    // MARK: VO-3 — view-owned lifecycle

    @Test("Shown for an idle call, the view starts it (web starts on mount)")
    func appearStartsTheCall() async throws {
        let (rig, model) = try await connectedModel()
        #expect(model.screen == .live)
        #expect(rig.meeting.started.count == 1)
    }

    @Test("Shown for a call the host already started, the view adopts it instead of starting a second")
    func appearAdoptsAHostStartedCall() async throws {
        let rig = try await Rig.make()
        try await rig.call.start()
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        let startsBefore = rig.meeting.started.count

        let model = TouchpointVoiceModel(call: rig.call)
        model.appear()
        model.callStateChanged(rig.call.state)
        try? await Task.sleep(for: .milliseconds(40))
        #expect(rig.meeting.started.count == startsBefore, "no second call was started")
        #expect(model.screen == .live)

        // Collapsing the full screen back to the host's rail must not hang the host's call up.
        let id = try #require(rig.call.callID)
        model.disappear()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!rig.sys.requested.contains(.end(id)), "an adopted call is the host's to end")
        #expect(rig.call.state == .connected)
    }

    @Test("A connected call that ends is the ended screen, and reports onEnded once; a never-connected end is the failed screen")
    func endedAndFailedScreens() async throws {
        let (rig, model) = try await connectedModel()
        let ended = Capture<[EndReason]>([]); model.onEnded = { ended.value.append($0) }

        let id = try #require(rig.call.callID)
        _ = await rig.sys.performEnd(id)
        #expect(await eventuallyOnMain { rig.call.state == .ended(.customerEnded) })
        model.callStateChanged(rig.call.state)
        #expect(model.screen == .ended)
        #expect(ended.value == [.customerEnded], "reported once, with the reason")

        // A different model whose call never connects before ending shows the failed screen.
        let model2 = TouchpointVoiceModel(call: rig.call)
        model2.callStateChanged(.connecting)
        model2.callStateChanged(.ended(.credentialVendingFailed))
        #expect(model2.screen == .failed)
    }

    @Test("End hangs up the call (VO-3)")
    func endHangsUp() async throws {
        let (rig, model) = try await connectedModel()
        let id = try #require(rig.call.callID)
        model.end()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(id)) })
    }

    @Test("Leaving the view hangs up the call (VO-3: web's unmount)")
    func disappearHangsUp() async throws {
        let (rig, model) = try await connectedModel()
        let id = try #require(rig.call.callID)
        model.disappear()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(id)) })
    }

    @Test("Restart hangs the call up and then calls again (VO-3)")
    func restartHangsUpThenRecalls() async throws {
        let (rig, model) = try await connectedModel()
        let first = try #require(rig.call.callID)
        model.restart()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(first)) }, "the current call is hung up first")
        #expect(model.screen == .connecting, "the restart shows connecting, not ended")
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.call.callID != nil && rig.call.callID != first }, "a new call was started")
    }

    @Test("A start that throws — the microphone denied — is the failed screen (web's generic failure)")
    func micDeniedIsFailed() async throws {
        let rig = try await Rig.make(permission: .denied)
        let model = TouchpointVoiceModel(call: rig.call)
        model.appear()
        #expect(await eventuallyOnMain { model.screen == .failed })
    }

    // MARK: VO-5 — first-join timeout

    @Test("A call that never connects fails after the first-join timeout, via an injected clock")
    func firstJoinTimeoutFails() async throws {
        let clock = HeldVoiceClock()
        let rig = try await Rig.make()
        let model = TouchpointVoiceModel(call: rig.call, firstJoinTimeout: .seconds(30), sleeper: clock)
        model.appear()
        #expect(await clock.waitForPending(), "the timeout was armed")
        #expect(clock.requested.contains(.seconds(30)), "Android's 30 s value")
        #expect(model.screen == .connecting)
        clock.fire()
        #expect(await eventuallyOnMain { model.screen == .failed }, "the deadline passed before the call connected")
    }

    @Test("The first-join timeout is cancelled once the call connects, and firing it then is a no-op")
    func timeoutNotAppliedAfterConnected() async throws {
        let clock = HeldVoiceClock()
        let (_, model) = try await connectedModel(sleeper: clock)
        #expect(await eventuallyOnMain { clock.pending == 0 }, "connecting cancelled the timeout")
        clock.fire()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.screen == .live, "a late deadline does not fail a connected call")
    }

    @Test("firstJoinDeadlineReached is a no-op once the call has connected")
    func deadlineNoOpAfterConnected() async throws {
        let (_, model) = try await connectedModel()
        model.firstJoinDeadlineReached()
        #expect(model.screen == .live)
    }

    // MARK: Minimise — an iOS addition: hand the call to the host

    @Test("Minimise, then the view going away, leaves a call the view started running")
    func minimiseKeepsAViewOwnedCall() async throws {
        let (rig, model) = try await connectedModel()
        var ends = 0
        model.onEnded = { _ in ends += 1 }
        let id = try #require(rig.call.callID)
        model.minimise()
        model.disappear()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!rig.sys.requested.contains(.end(id)), "minimise hands the call to the host")
        #expect(rig.call.state == .connected)
        // The host ends it later: the view, minimised, reports nothing — the host follows `state`.
        model.callStateChanged(.ended(.customerEnded))
        #expect(ends == 0, "no onEnded once the call was handed to the host")
    }

    @Test("Minimised while still connecting, the call goes on to connect — the start is not cancelled, and the timeout cannot fail it")
    func minimiseWhileConnecting() async throws {
        let clock = HeldVoiceClock()
        let rig = try await Rig.make()
        let model = TouchpointVoiceModel(call: rig.call, firstJoinTimeout: .seconds(30), sleeper: clock)
        model.appear()
        #expect(await eventuallyOnMain { rig.call.callID != nil }, "appear() started the call")
        #expect(await clock.waitForPending(), "the timeout was armed")
        model.minimise()
        model.disappear()
        clock.fire()
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected }, "the host's call connected after the view left")
        let id = try #require(rig.call.callID)
        #expect(!rig.sys.requested.contains(.end(id)))
    }

    @Test("A Restart finishing after Minimise places the new call for the host and arms no timeout")
    func restartThenMinimise() async throws {
        let clock = HeldVoiceClock()
        let (rig, model) = try await connectedModel(sleeper: clock)
        let first = try #require(rig.call.callID)
        model.restart()
        model.minimise()
        model.disappear()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(first)) })
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.call.callID != nil && rig.call.callID != first }, "the restart's call was placed")
        let second = try #require(rig.call.callID)
        clock.fire()
        try? await Task.sleep(for: .milliseconds(80))
        #expect(!rig.sys.requested.contains(.end(second)), "no view-side timeout ends the host's call")
    }

    @Test("A Restart finishing after the view hung up and left places no new call")
    func restartThenDisappear() async throws {
        let (rig, model) = try await connectedModel()
        let first = try #require(rig.call.callID)
        model.restart()
        model.disappear()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(first)) })
        _ = await rig.sys.performEnd(first)
        try? await Task.sleep(for: .milliseconds(120))
        #expect(rig.call.callID == nil || rig.call.callID == first, "no call placed for a view that is gone")
        #expect(model.screen != .connecting, "not left on the restart's loader")
    }

    @Test("A view that comes back with its model kept can restart: the restart places a call")
    func reappearThenRestart() async throws {
        let (rig, model) = try await connectedModel()
        let first = try #require(rig.call.callID)
        model.disappear()                                   // hangs up the view's call
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(first)) })
        _ = await rig.sys.performEnd(first)
        model.appear()                                      // a host showing the same view again
        model.restart()
        #expect(await eventuallyOnMain { rig.call.callID != nil && rig.call.callID != first }, "Retry placed a new call")
    }

    @Test("Minimised but still on screen (the host did not dismiss), a Restart's new call is the view's again")
    func restartAfterMinimiseWhileShown() async throws {
        let (rig, model) = try await connectedModel()
        let first = try #require(rig.call.callID)
        model.minimise()                                    // no dismissal follows
        model.restart()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(first)) })
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.call.callID != nil && rig.call.callID != first })
        let second = try #require(rig.call.callID)
        model.disappear()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(second)) }, "the view placed it, so leaving hangs it up")
    }

    @Test("Shown on a facade whose last call is over, the view places a new call — and owns it, so leaving hangs it up")
    func appearAfterAnEndedCallStartsAndOwns() async throws {
        let (rig, first) = try await connectedModel()
        let firstID = try #require(rig.call.callID)
        first.end()
        _ = await rig.sys.performEnd(firstID)
        #expect(await eventuallyOnMain { if case .ended = rig.call.state { true } else { false } })

        let model = TouchpointVoiceModel(call: rig.call)
        model.appear()
        #expect(await eventuallyOnMain { rig.call.callID != nil && rig.call.callID != firstID }, "a new call, not the ended one adopted")
        let second = try #require(rig.call.callID)
        model.disappear()
        #expect(await eventuallyOnMain { rig.sys.requested.contains(.end(second)) }, "the view's own call is hung up on leaving")
    }

    @Test("The first-join deadline cannot fail a call handed to the host")
    func deadlineNoOpAfterMinimise() async throws {
        let rig = try await Rig.make()
        let model = TouchpointVoiceModel(call: rig.call, firstJoinTimeout: .seconds(30), sleeper: HeldVoiceClock())
        model.appear()
        #expect(await eventuallyOnMain { rig.call.callID != nil })
        let id = try #require(rig.call.callID)
        model.minimise()
        model.firstJoinDeadlineReached()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.screen != .failed)
        #expect(!rig.sys.requested.contains(.end(id)))
    }

    @Test("The header: Speakers, then Minimise while there is a call to keep, then the red close last")
    func headerControls() {
        typealias V = TouchpointVoiceView
        #expect(V.headerControls(screen: .live, hasMinimise: true, hasClose: true) == [.speakers, .minimise, .close])
        #expect(V.headerControls(screen: .connecting, hasMinimise: true, hasClose: true) == [.speakers, .minimise, .close])
        #expect(V.headerControls(screen: .ended, hasMinimise: true, hasClose: true) == [.speakers, .close],
                "an ended call has nothing to hand on")
        #expect(V.headerControls(screen: .failed, hasMinimise: true, hasClose: false) == [.speakers])
        #expect(V.headerControls(screen: .live, hasMinimise: false, hasClose: true) == [.speakers, .close], "no host handler, no control")
    }

    // MARK: VO-4 — Speakers

    @Test("Toggling Speakers mutes and unmutes remote playback through the media session, not the microphone")
    func speakersMuteRemotePlayback() async throws {
        let (rig, model) = try await connectedModel()
        #expect(model.speakersOn)
        let muteCallsBefore = rig.meeting.muteCalls.count

        model.toggleSpeakers()
        #expect(await eventuallyOnMain { rig.call.speakersOn == false })
        #expect(await eventually { rig.meeting.playbackMuteCalls.last == true })
        #expect(rig.meeting.muteCalls.count == muteCallsBefore, "the microphone was never touched")

        model.toggleSpeakers()
        #expect(await eventuallyOnMain { rig.call.speakersOn == true })
        #expect(await eventually { rig.meeting.playbackMuteCalls.last == false })
    }

    @Test("Speakers set while connecting is remembered and applied when media starts")
    func speakersRememberedUntilStart() async throws {
        let rig = try await Rig.make()
        try await rig.call.start()
        _ = try await rig.systemStarts()                                  // requested, not yet started
        await rig.call.setSpeakersOn(false)
        rig.meeting.started()
        #expect(await eventually { rig.meeting.playbackMuteCalls.contains(true) }, "the remembered mute was applied at the join")
    }
}

// MARK: - Transport-level playback mute (VO-4)

@Suite("VoiceTransport remote playback mute (VO-4)")
struct VoiceTransportPlaybackMuteTests {
    @Test("Playback mute on a live call forwards to the driver; before the join it is remembered and re-asserted")
    func playbackMuteLifecycle() async throws {
        let driver = FakeMeetingSession()
        let transport = VoiceTransport(driver: driver)
        _ = transport.events
        try await transport.connect(credentials: VoiceFixtures.credentials())
        // Muted before the session starts: remembered, not yet forwarded.
        await transport.setPlaybackMuted(true)
        #expect(driver.playbackMuteCalls.isEmpty, "nothing to forward until the audio session starts")
        driver.started()
        #expect(await eventually { driver.playbackMuteCalls.last == true }, "re-asserted at the join, as Chime starts playback live")

        // On a live call it forwards at once.
        await transport.setPlaybackMuted(false)
        #expect(await eventually { driver.playbackMuteCalls.last == false })
        #expect(await eventually { await transport.isPlaybackMuted == false })
    }

    @Test("Playback mute does not carry over into the next call")
    func playbackMuteDoesNotCarryOver() async throws {
        let driver = FakeMeetingSession()
        let transport = VoiceTransport(driver: driver)
        let (log, pump) = attachLog(transport)
        defer { pump.cancel() }
        try await transport.connect(credentials: VoiceFixtures.credentials())
        driver.started()
        _ = await log.waitFor(1)                                          // .connected — now the call is live
        await transport.setPlaybackMuted(true)
        #expect(await eventually { await transport.isPlaybackMuted == true })
        driver.stopped(.audioCallEnded)
        _ = await log.waitFor(2)                                          // .contactEnded

        try await transport.connect(credentials: VoiceFixtures.credentials())
        #expect(await eventually { await transport.isPlaybackMuted == false }, "the next call starts with the other side audible")
    }
}
