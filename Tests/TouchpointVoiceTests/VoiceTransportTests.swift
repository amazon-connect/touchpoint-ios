import Foundation
import Testing
import TouchpointCore
@testable import TouchpointVoice

// MARK: - VoiceTransport over a scripted Chime session

@Suite("VoiceTransport: join, state machine, controls")
struct VoiceTransportTests {
    private func make(timeout: Duration = VoiceTransport.defaultReconnectTimeout) -> (VoiceTransport, FakeMeetingSession) {
        let fake = FakeMeetingSession()
        return (VoiceTransport(driver: fake, reconnectTimeout: timeout), fake)
    }

    /// A sentinel through the same inbox as the event under test: when the join has been dispatched,
    /// everything queued before it has been processed too.
    private func drain(_ fake: FakeMeetingSession, _ log: TransportEventLog, expecting count: Int) async -> [TransportEvent] {
        fake.join("sentinel-\(count)", externalUserID: "x-agent")
        let events = await log.waitFor(count + 1)
        return events.filter { if case .participantJoined(let p) = $0, p.id.hasPrefix("sentinel-") { false } else { true } }
    }

    @Test("V1: connect decodes Connect's ConnectionData into the Chime join and emits .connected only when the audio session starts")
    func connectJoins() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        let p = try #require(fake.started.first)
        #expect(p.meetingID == "m-1")
        #expect(p.attendeeID == "att-local")
        #expect(p.joinToken == "jt-1")
        #expect(p.externalUserID == "")
        #expect(p.urls.audioHostURL == "a.example:3478")
        #expect(p.urls.signalingURL == "wss://s.example")
        #expect(p.urls.ingestionURL == nil, "no Chime client telemetry: ingestion is switched off")
        #expect(p.reconnectTimeoutMs == 30_000)
        #expect(p.callKitEnabled)
        #expect(!p.startMuted)
        fake.connecting()
        fake.join("att-9", externalUserID: "x-agent")                    // before start: not forwarded
        fake.started()
        #expect(await drain(fake, log, expecting: 1) == [.connected], "nothing before the audio session starts — not even attendees")
    }

    @Test("V1b: a non-default reconnect timeout converts to whole milliseconds")
    func timeoutConversion() async throws {
        let (t, fake) = make(timeout: .milliseconds(12_500))
        try await t.connect(credentials: VoiceFixtures.credentials())
        #expect(fake.started.first?.reconnectTimeoutMs == 12_500)
    }

    @Test("V2: the wrong credential type is refused before anything starts; connecting twice is refused")
    func guards() async throws {
        let (t, fake) = make()
        await #expect(throws: TouchpointError.self) {
            try await t.connect(credentials: ChatContactCredentials(contactID: "c", participantID: "p", participantToken: "t", expiresAt: nil))
        }
        #expect(fake.started.isEmpty)
        try await t.connect(credentials: VoiceFixtures.credentials())
        await #expect(throws: TouchpointError.self) { try await t.connect(credentials: VoiceFixtures.credentials()) }
        #expect(fake.started.count == 1)
    }

    @Test("V3: a MediaPlacement missing a URL Chime requires is a typed malformedPayload, not a silent nil")
    func malformedMeeting() async {
        let (t, fake) = make()
        await #expect(throws: TouchpointError.malformedPayload("ConnectionData.Meeting.MediaPlacement.AudioHostUrl")) {
            try await t.connect(credentials: VoiceFixtures.credentials(meeting: VoiceFixtures.meetingMissingHost))
        }
        #expect(fake.started.isEmpty)
    }

    @Test("V4: Chime's own reconnect stays inside the transport — no session event, isReconnecting toggles, mute is re-asserted")
    func chimeReconnectIsInternal() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        let flags = Flags()
        await t.setReconnectingObserver { flags.append($0) }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        _ = await log.waitFor(1)
        try await t.setMuted(true)
        fake.dropped()
        #expect(await eventually { await t.isReconnecting })
        fake.connecting(reconnecting: true)
        fake.started(reconnecting: true)
        #expect(await eventually { !(await t.isReconnecting) })
        #expect(await drain(fake, log, expecting: 1) == [.connected], "the session never heard about the drop")
        #expect(flags.values == [true, false])
        #expect(fake.muteCalls == [true, true], "mute re-applied after the rejoin: Chime restarts unmuted")
    }

    @Test("V4b: a drop before the agent joins (still joining) is ignored, as the Connect reference does")
    func dropWhileJoining() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.dropped()
        fake.connecting(reconnecting: true)
        fake.started(reconnecting: true)
        #expect(await log.waitFor(1) == [.connected])
        #expect(!(await t.isReconnecting))
    }

    @Test("V5: a dropped call is terminal — cancelled reconnect ends the contact with connectionLost, stops media, and later events are ignored")
    func droppedIsTerminal() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        fake.dropped()
        fake.cancelledReconnect()
        fake.started(reconnecting: true)                        // must not revive the contact
        fake.join("att-9", externalUserID: "x-agent")          // nor this
        #expect(await eventually { await log.events.count == 2 })
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await log.events == [.connected, .contactEnded(.connectionLost)])
        #expect(fake.stopCount == 1, "the transport stops the media session itself; nothing else will")
        #expect(!(await t.isReconnecting))
    }

    @Test("V6: stop statuses map to end reasons — call ended / server hung up → agentEnded; rejected or failed → connectionLost; the driver is detached in every case")
    func stopStatuses() async throws {
        for (status, reason) in [(VoiceSessionStatus.audioCallEnded, EndReason.agentEnded),
                                 (.audioServerHungup, .agentEnded),
                                 (.audioAuthenticationRejected, .connectionLost),
                                 (.audioInternalServerError, .connectionLost),
                                 (.audioJoinedFromAnotherDevice, .connectionLost),
                                 (.unknown(999), .connectionLost)] {
            let (t, fake) = make()
            let (log, pump) = attachLog(t); defer { pump.cancel() }
            try await t.connect(credentials: VoiceFixtures.credentials())
            fake.started()
            fake.stopped(status)
            #expect(await log.waitFor(2).last == .contactEnded(reason), "\(status)")
            #expect(fake.stopCount == 1, "\(status): the driver is detached so a second call cannot inherit its observers")
        }
    }

    @Test("V6b: a stop with status .ok maps on whether the call had connected — before: systemEnded; after: agentEnded")
    func okStop() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.stopped(.ok)
        #expect(await log.waitFor(1) == [.contactEnded(.systemEnded)])
        #expect(VoiceTransport.endReason(for: .ok, hadConnected: true) == .agentEnded)
    }

    @Test("V7: remote attendees become participants — `…agent` is the agent, anything else is unknown (human, so dispatch pauses); the local attendee is filtered")
    func attendees() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        fake.join("att-local", externalUserID: "")                          // us
        fake.join("att-9", externalUserID: "abc-agent")
        fake.join("att-7", externalUserID: "something-else")
        fake.leave("att-9")
        #expect(await log.waitFor(4) == [
            .connected,
            .participantJoined(Participant(id: "att-9", role: .agent, displayName: "")),
            .participantJoined(Participant(id: "att-7", role: .unknown, displayName: "")),
            .participantLeft(id: "att-9"),
        ])
    }

    @Test("V8: a mute requested before the join is applied by the driver at start, before the transport hears .connected; live mute follows Chime's answer")
    func mute() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.setMuted(true)
        #expect(await t.isMuted)
        #expect(fake.muteCalls.isEmpty, "nothing to mute yet")
        try await t.connect(credentials: VoiceFixtures.credentials())
        #expect(fake.started.first?.startMuted == true)
        fake.started()
        _ = await log.waitFor(1)
        #expect(fake.muteCalls.first == true, "applied inside audioSessionDidStart, synchronously")
        try await t.setMuted(false)
        #expect(fake.muteCalls.last == false)
        #expect(!(await t.isMuted))
        fake.muteResult = false
        await #expect(throws: TouchpointError.self) { try await t.setMuted(true) }
        #expect(!(await t.isMuted), "a refused mute does not lie about the microphone")
    }

    @Test("V9: disconnect stops the media session, finishes the stream, emits nothing itself, and drops later callbacks; disconnect while joining also stops")
    func disconnect() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        _ = await log.waitFor(1)
        await t.disconnect()
        #expect(fake.stopCount == 1)
        fake.stopped(.audioCallEnded)                        // Chime acknowledges our stop
        fake.join("att-9", externalUserID: "x-agent")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(await log.events == [.connected])

        let (t2, fake2) = make()
        try await t2.connect(credentials: VoiceFixtures.credentials())
        await t2.disconnect()
        #expect(fake2.stopCount == 1)
    }

    @Test("V9b: a second contact on the same transport after a network end starts clean — no stale .contactEnded, fresh session")
    func secondContact() async throws {
        let (t, fake) = make()
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        fake.stopped(.audioServerHungup)                        // network ended it; no subscriber yet → buffered
        #expect(await eventually { fake.stopCount == 1 })
        try await t.connect(credentials: VoiceFixtures.credentials())
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        fake.started()
        #expect(await log.waitFor(1) == [.connected], "the first contact's end did not greet the second subscriber")
        #expect(fake.started.count == 2)
    }

    @Test("V10: voice carries no messages")
    func sendRefused() async {
        let (t, _) = make()
        await #expect(throws: TouchpointError.self) {
            try await t.send(OutboundMessage(clientMessageID: UUID(), body: "hi"))
        }
    }

    @Test("V11: events raised before a subscriber attaches are buffered, and a second `events` access supersedes the first")
    func buffersBeforeSubscriber() async throws {
        let (t, fake) = make()
        try await t.connect(credentials: VoiceFixtures.credentials())
        fake.started()
        fake.join("att-9", externalUserID: "x-agent")
        // Not attached yet. Attach now: both must replay, in order.
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        #expect(await log.waitFor(2) == [.connected, .participantJoined(Participant(id: "att-9", role: .agent, displayName: ""))])
        let (log2, pump2) = attachLog(t); defer { pump2.cancel() }
        fake.leave("att-9")
        #expect(await log2.waitFor(1) == [.participantLeft(id: "att-9")])
        #expect(await eventually { await log.events.count == 2 }, "the superseded stream received nothing more")
    }

    @Test("V12: a start failure from the driver is a transportFailure naming only the error type and code, and the transport is left reconnectable")
    func startFails() async throws {
        let (t, fake) = make()
        fake.failStart = NSError(domain: "chime", code: 7, userInfo: [NSLocalizedDescriptionKey: "token jt-1 rejected"])
        do { try await t.connect(credentials: VoiceFixtures.credentials()); Issue.record("expected a throw") }
        catch let TouchpointError.transportFailure(d) { #expect(!d.contains("jt-1")); #expect(d.contains("7")) }
        fake.failStart = nil
        try await t.connect(credentials: VoiceFixtures.credentials())
        #expect(fake.started.count == 1)
    }

    @Test("V13: audio devices — Bluetooth is preferred over wired over speaker, chosen when the session starts (after the category is set)")
    func devicePreference() async throws {
        let (t, fake) = make()
        let (log, pump) = attachLog(t); defer { pump.cancel() }
        fake.devices = [VoiceAudioDevice(label: "iPhone", kind: .handset), VoiceAudioDevice(label: "Speaker", kind: .speaker),
                        VoiceAudioDevice(label: "Pods", kind: .bluetooth), VoiceAudioDevice(label: "Wired", kind: .wiredHeadset)]
        try await t.connect(credentials: VoiceFixtures.credentials())
        #expect(fake.chosenDevices.isEmpty, "devices are enumerated only once the audio session has started")
        fake.started()
        _ = await log.waitFor(1)
        #expect(fake.chosenDevices.map(\.label) == ["Pods"])
        fake.devices = [VoiceAudioDevice(label: "Speaker", kind: .speaker), VoiceAudioDevice(label: "Wired", kind: .wiredHeadset)]
        await t.reselectAudioDevice()
        #expect(fake.chosenDevices.map(\.label) == ["Pods", "Wired"])
    }

    @Test("Neither the configuration nor the start parameters print the join token")
    func noTokenInDescriptions() throws {
        let c = try VoiceMeetingConfiguration(meetingJSON: VoiceFixtures.meetingJSON, attendeeJSON: VoiceFixtures.attendeeJSON)
        let p = c.startParameters(reconnectTimeoutMs: 1)
        for text in ["\(c)", String(reflecting: c), "\(p)", String(reflecting: p)] { #expect(!text.contains("jt-1"), Comment(rawValue: text)) }
        var dumped = ""; dump(p, to: &dumped); #expect(!dumped.contains("jt-1"))
    }
}

/// Collects `onReconnectingChange` values from the transport's nonisolated callback.
final class Flags: @unchecked Sendable {
    private let lock = NSLock(); private var _v: [Bool] = []
    func append(_ b: Bool) { lock.withLock { _v.append(b) } }
    var values: [Bool] { lock.withLock { _v } }
}

// MARK: - Through the session: the reason reconnect must stay internal

// Serialised: three ConversationStores opening SQLite stores in parallel crashed CoreData during
// schema creation (also how Core's own session suite runs).
@Suite("VoiceTransport under TouchpointSession", .serialized)
@MainActor
struct VoiceTransportSessionTests {
    private func makeSession(_ transport: VoiceTransport) async throws -> TouchpointSession {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-voice-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let broker = CredentialBroker(backend: VoiceStubBackend(), keychain: InMemoryKeychainStore())
        return TouchpointSession(broker: broker, store: store, transports: [.voice: transport])
    }

    @Test("S1: a Chime drop and recovery leaves the session connected — the contact survives a Wi-Fi handoff")
    func chimeReconnectSurvives() async throws {
        let fake = FakeMeetingSession()
        let session = try await makeSession(VoiceTransport(driver: fake))
        try await session.startVoice(VoiceContactRequest(displayName: "v"))
        fake.started()
        #expect(await eventuallyOnMain { session.state == .connected })
        fake.dropped(); fake.connecting(reconnecting: true); fake.started(reconnecting: true)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(session.state == .connected)
        #expect(session.isActive)
    }

    @Test("S2: Chime giving up ends the contact with connectionLost, once, with no second StartWebRTCContact")
    func chimeGiveUpEnds() async throws {
        let fake = FakeMeetingSession()
        let backend = VoiceStubBackend()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-voice-\(UUID().uuidString)")
        let store = try await ConversationStore(containerURL: dir, keychain: InMemoryKeychainStore())
        let session = TouchpointSession(broker: CredentialBroker(backend: backend, keychain: InMemoryKeychainStore()), store: store, transports: [.voice: VoiceTransport(driver: fake)])
        try await session.startVoice(VoiceContactRequest(displayName: "v"))
        fake.started()
        #expect(await eventuallyOnMain { session.state == .connected })
        fake.dropped(); fake.cancelledReconnect()
        #expect(await eventuallyOnMain { session.state == .ended(.connectionLost) })
        #expect(await backend.voiceStarts == 1)
        #expect(fake.started.count == 1)
    }

    @Test("S3: the agent hanging up ends the contact with agentEnded")
    func agentHangsUp() async throws {
        let fake = FakeMeetingSession()
        let session = try await makeSession(VoiceTransport(driver: fake))
        try await session.startVoice(VoiceContactRequest(displayName: "v"))
        fake.started()
        #expect(await eventuallyOnMain { session.state == .connected })
        fake.stopped(.audioCallEnded)
        #expect(await eventuallyOnMain { session.state == .ended(.agentEnded) })
    }
}

actor VoiceStubBackend: TouchpointBackend {
    var voiceStarts = 0
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        throw TouchpointError.invalidConfiguration("voice only")
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        voiceStarts += 1
        return VoiceFixtures.credentials()
    }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
}

@Suite("VoiceMeetingConfiguration decode")
struct VoiceMeetingConfigurationTests {
    @Test("Decodes the Connect response shape, every MediaPlacement URL required, ingestion dropped")
    func decode() throws {
        let c = try VoiceMeetingConfiguration(meetingJSON: VoiceFixtures.meetingJSON, attendeeJSON: VoiceFixtures.attendeeJSON)
        #expect(c.meetingID == "m-1")
        #expect(c.attendeeID == "att-local")
        #expect(c.joinToken == "jt-1")
        #expect(c.urls.turnControlURL == "https://t.example")
        #expect(c.urls.audioFallbackURL == "wss://f.example")
        #expect(c.urls.ingestionURL == nil)
    }

    @Test("Each missing required field names itself")
    func missingFields() {
        for (field, json) in [("MeetingId", #"{"MediaPlacement":{"AudioHostUrl":"a","AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}}"#),
                              ("MediaPlacement", #"{"MeetingId":"m"}"#),
                              ("MediaPlacement.TurnControlUrl", #"{"MeetingId":"m","MediaPlacement":{"AudioHostUrl":"a","AudioFallbackUrl":"b","SignalingUrl":"c"}}"#),
                              ("MediaPlacement.AudioHostUrl", #"{"MeetingId":"m","MediaPlacement":{"AudioHostUrl":42,"AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}}"#),
                              ("MediaPlacement.AudioHostUrl", #"{"MeetingId":"m","MediaPlacement":{"AudioHostUrl":"","AudioFallbackUrl":"b","SignalingUrl":"c","TurnControlUrl":"d"}}"#)] {
            #expect(throws: TouchpointError.malformedPayload("ConnectionData.Meeting.\(field)")) {
                _ = try VoiceMeetingConfiguration(meetingJSON: Data(json.utf8), attendeeJSON: VoiceFixtures.attendeeJSON)
            }
        }
        #expect(throws: TouchpointError.malformedPayload("ConnectionData.Attendee.JoinToken")) {
            _ = try VoiceMeetingConfiguration(meetingJSON: VoiceFixtures.meetingJSON, attendeeJSON: Data(#"{"AttendeeId":"x"}"#.utf8))
        }
    }

    @Test("Not JSON, a JSON array, or null is malformedPayload too, and the description carries no payload content")
    func notJSON() {
        for bad in ["jt-SECRET", "[]", "null"] {
            #expect(throws: TouchpointError.malformedPayload("ConnectionData.Meeting")) {
                _ = try VoiceMeetingConfiguration(meetingJSON: Data(bad.utf8), attendeeJSON: VoiceFixtures.attendeeJSON)
            }
        }
    }
}
