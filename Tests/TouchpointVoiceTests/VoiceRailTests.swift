import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointVoice

/// The floating voice rail (design-01…03) and the speaking signal that drives its
/// ripple.
// Serialized: the rail renders the SDK surface, and with `.glass` restored as the default that
// draws a system material and the shared noise tile. Rendering those from several tests at once
// segfaults under Swift Testing's parallel execution — the other voice suites are serialized for
// the same reason.
@Suite("Voice rail and speaking signal", .serialized)
@MainActor
struct VoiceRailTests {
    // MARK: Rail contents (S3, S4)

    @Test("The rail's controls: web's speakers, mic, close, with the menu, the iOS output-route picker and chat around them")
    func railControls() {
        #expect(VoiceMiniRail.controls(hasMenu: true) == [.menu, .speakers, .microphone, .audioRoute, .close])
        #expect(VoiceMiniRail.controls(hasMenu: false) == [.speakers, .microphone, .audioRoute, .close])
        // The open-chat control leads, so the rail can stand in for the host's Support pill.
        #expect(VoiceMiniRail.controls(hasMenu: false, hasChat: true) == [.chat, .speakers, .microphone, .audioRoute, .close])
        // Draggable (web VoiceMini's handle): the handle leads everything.
        #expect(VoiceMiniRail.controls(hasMenu: false, hasChat: true, draggable: true) == [.dragHandle, .chat, .speakers, .microphone, .audioRoute, .close])
        #expect(!VoiceMiniRail.ripples(.chat, localSpeaking: true, remoteSpeaking: true))
        #expect(VoiceMiniRail.variant(for: .chat) == .ghost)
    }

    // MARK: Behaviour through the facade (S5)

    /// A connected call: CallKit performed the start, the audio session activated, and Chime's
    /// session has started.
    private func connected() async throws -> Rig {
        let rig = try await Rig.make()
        try await rig.call.start()
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        return rig
    }

    // Mute and end are not re-tested here: the rail's buttons call `call.setMuted` and `call.end`,
    // and that both route through CallKit rather than around it is CallManagerTests K4 / K4b.

    @Test("The facade publishes the speaking signal, and the end of a call clears it")
    func facadeSpeakingSignal() async throws {
        let rig = try await connected()
        rig.meeting.join("agent-1", externalUserID: "x-agent")
        rig.meeting.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await eventuallyOnMain { rig.call.isRemoteSpeaking })
        #expect(!rig.call.isLocalSpeaking)

        rig.meeting.volume([VoiceVolume(attendeeID: "att-local", isAudible: true)])
        #expect(await eventuallyOnMain { rig.call.isLocalSpeaking })

        // The agent hangs up mid-sentence. The signal must clear, or the next call's rail opens
        // mid-ripple.
        rig.meeting.stopped(.audioCallEnded)
        #expect(await eventuallyOnMain { !rig.call.isRemoteSpeaking && !rig.call.isLocalSpeaking })
    }

    @Test("A Chime reconnect clears the speaking signal: no volume arrives while media is down")
    func reconnectClearsSpeaking() async throws {
        let rig = try await connected()
        rig.meeting.join("agent-1", externalUserID: "x-agent")
        rig.meeting.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await eventuallyOnMain { rig.call.isRemoteSpeaking })
        rig.meeting.dropped()
        #expect(await eventuallyOnMain { rig.call.state == .reconnecting })
        #expect(await eventuallyOnMain { !rig.call.isRemoteSpeaking }, "the ripple must not run through Reconnecting…")
        rig.meeting.stopped(.audioCallEnded)
    }

    @Test("Two remote parties: one falling silent does not clear the ripple while the other still talks")
    func twoRemoteSpeakers() async throws {
        let rig = try await connected()
        rig.meeting.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true),
                            VoiceVolume(attendeeID: "supervisor-1", isAudible: true)])
        #expect(await eventuallyOnMain { rig.call.isRemoteSpeaking })
        // A delta naming only the agent — Chime sends the attendees whose level changed.
        rig.meeting.volume([VoiceVolume(attendeeID: "agent-1", isAudible: false)])
        try await Task.sleep(for: .milliseconds(60))
        #expect(rig.call.isRemoteSpeaking, "the supervisor is still audible")
        rig.meeting.volume([VoiceVolume(attendeeID: "supervisor-1", isAudible: false)])
        #expect(await eventuallyOnMain { !rig.call.isRemoteSpeaking })
    }

    @Test("A party who drops mid-sentence does not leave the ripple running")
    func departureClearsTheRipple() async throws {
        let rig = try await connected()
        rig.meeting.join("agent-1", externalUserID: "x-agent")
        rig.meeting.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await eventuallyOnMain { rig.call.isRemoteSpeaking })
        rig.meeting.leave("agent-1")
        #expect(await eventuallyOnMain { !rig.call.isRemoteSpeaking })
    }

    @Test("The rail shows a loader instead of controls until the call is connected, and nothing once it has ended")
    func railPhases() {
        #expect(VoiceMiniRail.phase(for: .idle) == .hidden)
        #expect(VoiceMiniRail.phase(for: .requesting) == .connecting)
        #expect(VoiceMiniRail.phase(for: .connecting) == .connecting)
        #expect(VoiceMiniRail.phase(for: .connected) == .live)
        // A Chime-internal reconnect keeps the controls: the call is still the user's to mute or end.
        #expect(VoiceMiniRail.phase(for: .reconnecting) == .live)
        #expect(VoiceMiniRail.phase(for: .interrupted) == .live)
        #expect(VoiceMiniRail.phase(for: .ended(.customerEnded)) == .hidden)
    }

    @Test("Only the close control is destructive; the rest are quiet ghosts")
    func railVariants() {
        #expect(VoiceMiniRail.variant(for: .close) == .error)
        for control in [VoiceMiniRail.Control.menu, .speakers, .microphone, .audioRoute] {
            #expect(VoiceMiniRail.variant(for: control) == .ghost)
        }
    }

    @Test("The ripple follows who is speaking: the speaker while the agent talks, the microphone while the customer does")
    func rippleTargets() {
        // Web ripples its Speakers toggle while the agent talks; the route picker never ripples.
        #expect(VoiceMiniRail.ripples(.speakers, localSpeaking: false, remoteSpeaking: true))
        #expect(!VoiceMiniRail.ripples(.speakers, localSpeaking: true, remoteSpeaking: false))
        #expect(!VoiceMiniRail.ripples(.audioRoute, localSpeaking: true, remoteSpeaking: true))
        #expect(!VoiceMiniRail.ripples(.dragHandle, localSpeaking: true, remoteSpeaking: true))
        #expect(VoiceMiniRail.ripples(.microphone, localSpeaking: true, remoteSpeaking: false))
        #expect(!VoiceMiniRail.ripples(.microphone, localSpeaking: false, remoteSpeaking: true))
        // Never on the other two, whoever is talking.
        #expect(!VoiceMiniRail.ripples(.close, localSpeaking: true, remoteSpeaking: true))
        #expect(!VoiceMiniRail.ripples(.menu, localSpeaking: true, remoteSpeaking: true))
    }

    // MARK: Speaking signal (S5)

    @Test("Chime's volume levels reduce to the one question the UI asks: is this attendee audible?")
    func audibility() {
        // muted (-1) and notSpeaking (0) are silence; low, medium and high are speech.
        #expect(!VoiceVolume.isAudible(level: -1))
        #expect(!VoiceVolume.isAudible(level: 0))
        #expect(VoiceVolume.isAudible(level: 1))
        #expect(VoiceVolume.isAudible(level: 2))
        #expect(VoiceVolume.isAudible(level: 3))
        // An unrecognised level is treated as silence rather than a stuck ripple.
        #expect(!VoiceVolume.isAudible(level: 99))
    }

    @Test("The transport splits volume updates into the local attendee and everyone else, and reports only changes")
    func transportSpeakingSignal() async throws {
        let driver = FakeMeetingSession()
        let transport = VoiceTransport(driver: driver)
        let observed = Recorder()
        await transport.setSpeakingObserver { local, remote in observed.append(local, remote) }
        try await transport.connect(credentials: VoiceFixtures.credentials())
        _ = await transport.events          // attach a subscriber so the pump runs
        driver.started()

        // The agent speaks. "att-local" is the attendee the fixture's configuration names.
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)))
        // The same update again changes nothing: no second report.
        let countAfterFirst = observed.count
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(observed.count == countAfterFirst, "an unchanged signal was reported again")

        // The customer speaks too.
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: true),
                       VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: true, remote: true)))

        // Silence from both.
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: false),
                       VoiceVolume(attendeeID: "agent-1", isAudible: false)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: false)))

        // A volume update after the contact ends is ignored rather than leaving a stuck ripple.
        driver.stopped(.audioCallEnded)
        try await Task.sleep(for: .milliseconds(30))
        let countAfterEnd = observed.count
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        try await Task.sleep(for: .milliseconds(50))
        #expect(observed.count == countAfterEnd, "a post-end volume update was reported")
    }

    // MARK: Speaking off-delay (c77, web `createSpeakingFlag`)

    /// A connected transport whose switch-off timers are held by `sleeper` until it fires.
    private func delayedRig() async throws -> (VoiceTransport, FakeMeetingSession, HeldVoiceClock, Recorder) {
        let driver = FakeMeetingSession(), sleeper = HeldVoiceClock(), observed = Recorder()
        let transport = VoiceTransport(driver: driver, sleeper: sleeper)
        await transport.setSpeakingObserver { local, remote in observed.append(local, remote) }
        try await transport.connect(credentials: VoiceFixtures.credentials())
        _ = await transport.events
        driver.started()
        return (transport, driver, sleeper, observed)
    }

    @Test("Speaking switches on at once and off only after 500 ms of silence")
    func offDelay() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)), "on edges are immediate")
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: false)])
        #expect(await sleeper.waitForPending())
        #expect(sleeper.requested.last == .milliseconds(500))
        try await Task.sleep(for: .milliseconds(40))
        #expect(observed.all.last == Pair(local: false, remote: true), "the flag stays on until the delay elapses")
        sleeper.fire()
        #expect(await observed.eventuallyLast(Pair(local: false, remote: false)))
    }

    @Test("Speech resuming within the delay cancels the switch-off; a pause between words never flickers")
    func resumeCancelsOff() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: true, remote: false)))
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: false)])
        #expect(await sleeper.waitForPending())
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: true)])
        try await Task.sleep(for: .milliseconds(40))
        sleeper.fire()                                  // the stale timer elapses
        try await Task.sleep(for: .milliseconds(40))
        #expect(observed.all.last == Pair(local: true, remote: false), "a resumed speaker was switched off")
        #expect(!observed.all.contains(Pair(local: false, remote: false)), "the indicator flickered off")
    }

    @Test("A contact ending clears at once")
    func clearIsImmediate() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)))
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: false)])
        #expect(await sleeper.waitForPending())
        driver.stopped(.audioCallEnded)
        // Off without waiting for the timer.
        #expect(await observed.eventuallyLast(Pair(local: false, remote: false)))
    }

    @Test("A timer left from before a reconnect does not switch off speech that started after it")
    func staleTimerAfterReconnect() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)))
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: false)])
        #expect(await sleeper.waitForPending())         // timer 1, for the old state
        driver.dropped()                               // media down: cleared at once
        driver.started(reconnecting: true)
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)))
        sleeper.fireOldest()                           // the stale timer elapses
        try await Task.sleep(for: .milliseconds(40))
        #expect(observed.all.last == Pair(local: false, remote: true), "a stale timer switched off live speech")
    }

    @Test("Off, on, off: only the newest timer can switch it off")
    func onlyNewestTimerCounts() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: true, remote: false)))
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: false)])
        #expect(await sleeper.waitForPending())          // timer 1
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: true)])
        driver.volume([VoiceVolume(attendeeID: "att-local", isAudible: false)])
        try await Task.sleep(for: .milliseconds(40))     // timer 2 scheduled
        sleeper.fireOldest()
        try await Task.sleep(for: .milliseconds(40))
        #expect(observed.all.last == Pair(local: true, remote: false), "timer 1 switched off a newer pause")
        sleeper.fire()
        #expect(await observed.eventuallyLast(Pair(local: false, remote: false)))
    }

    @Test("Someone leaving clears their ripple at once: gone is not a pause")
    func departureIsImmediate() async throws {
        let (transport, driver, sleeper, observed) = try await delayedRig(); defer { withExtendedLifetime(transport) {} }
        driver.join("agent-1", externalUserID: "x-agent")
        driver.volume([VoiceVolume(attendeeID: "agent-1", isAudible: true)])
        #expect(await observed.eventuallyLast(Pair(local: false, remote: true)))
        driver.leave("agent-1")
        #expect(await observed.eventuallyLast(Pair(local: false, remote: false)))
        try await Task.sleep(for: .milliseconds(40))     // a scheduled timer would reach the sleeper by now
        #expect(sleeper.pending == 0, "a departure scheduled a delayed switch-off")
    }

    struct Pair: Equatable { let local: Bool; let remote: Bool }

    /// Collects the observer's reports. A class so the `@Sendable` observer can append.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var pairs: [Pair] = []

        func append(_ local: Bool, _ remote: Bool) {
            lock.lock(); defer { lock.unlock() }
            pairs.append(Pair(local: local, remote: remote))
        }

        var all: [Pair] { lock.lock(); defer { lock.unlock() }; return pairs }
        var count: Int { all.count }

        /// Waits for the latest report to equal `pair`. Takes a value rather than a predicate so
        /// nothing non-Sendable crosses an isolation boundary.
        func eventuallyLast(_ pair: Pair) async -> Bool {
            for _ in 0..<100 {
                if all.last == pair { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
    }
}
