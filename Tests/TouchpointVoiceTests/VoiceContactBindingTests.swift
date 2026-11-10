import Testing
import TouchpointCore
@testable import TouchpointVoice

/// When the voice contact id becomes readable — the contract a host binding Live Sync to a call
/// depends on.
///
/// `start()` returns once CallKit has accepted the `CXStartCallAction`. The contact itself is created
/// later: CallKit activates the audio session, and only then does `session.startVoice` vend
/// credentials. A host that reads `session.contactID` straight after `start()` therefore reads nil,
/// binds Live Sync to nothing, and leaves it on whatever contact it had before — which is exactly how
/// an app shipped voice Live Sync that connected, posted, and never received an action
/// while chat worked on the same code. `.connected` is the first state at which the id is guaranteed.
@Suite("Voice contact id timing", .serialized)
@MainActor
struct VoiceContactBindingTests {
    @Test("The contact id is nil when start() returns, and set by the time the call is connected")
    func contactIDArrivesAtConnected() async throws {
        let rig = try await Rig.make()

        try await rig.call.start()
        #expect(rig.session.contactID == nil,
                "start() returns on CallKit's acceptance; the contact has not been created yet")

        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { rig.call.state == .connected })
        #expect(rig.session.contactID != nil, "the contact exists once the call is connected")
    }

    @Test("A host observing onStateChange for .connected sees the contact id at that moment")
    func bindOnConnected() async throws {
        let rig = try await Rig.make()
        let bound = Capture<[String?]>([])
        // The working shape: capture the id inside the state callback, not after start().
        rig.call.onStateChange = { [session = rig.session] s in
            if s == .connected { bound.value.append(session.contactID) }
        }

        try await rig.call.start()
        _ = try await rig.systemStarts()
        rig.meeting.started()
        #expect(await eventuallyOnMain { !bound.value.isEmpty })

        let id = try #require(bound.value.first ?? nil, "the id was readable inside the .connected callback")
        #expect(id == rig.session.contactID)
    }

    @Test("A second call reaches .connected again, so a per-call bind fires per call")
    func secondCallRebinds() async throws {
        let rig = try await Rig.make()
        let binds = Capture<Int>(0)
        rig.call.onStateChange = { [session = rig.session] s in
            if s == .connected, session.contactID != nil { binds.value += 1 }
        }

        try await rig.call.start(); let first = try await rig.systemStarts()
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }
        #expect(await eventuallyOnMain { binds.value == 1 })
        _ = await rig.sys.performEnd(first)
        #expect(await eventuallyOnMain { rig.session.state == .ended(.customerEnded) })
        #expect(await eventuallyOnMain { rig.call.state == .ended(.customerEnded) })

        try await rig.call.start()
        let second = try #require(rig.call.callID)
        #expect(await rig.sys.performStart(second))
        await rig.sys.activateAudio()
        #expect(await eventuallyOnMain { rig.meeting.started.count == 2 }, "second join requested")
        rig.meeting.started(); _ = await eventuallyOnMain { rig.call.state == .connected }

        // Each start is a fresh StartWebRTCContact; the bind must follow it rather than being a
        // one-shot on the first call. (The stub backend vends one fixture id, so distinctness of
        // the id itself is the real backend's property, not something this fake can show.)
        #expect(await eventuallyOnMain { binds.value == 2 })
    }
}
