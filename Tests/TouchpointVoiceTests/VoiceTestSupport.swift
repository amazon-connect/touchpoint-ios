import Foundation
import TouchpointCore
@testable import TouchpointVoice

/// A scripted Chime meeting session. Records what the transport asked for and lets a test raise the
/// observer callbacks a real `DefaultMeetingSession` would. Mirrors the real driver's shape:
/// `stop` detaches, devices are visible only while a session exists, and `started` applies the
/// requested initial mute before forwarding, as `audioSessionDidStart` does.
final class FakeMeetingSession: ChimeMeetingSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var _started: [VoiceStartParameters] = []
    private var _stopCount = 0
    private var _muteCalls: [Bool] = []
    private var _playbackMuteCalls: [Bool] = []
    private var _chosenDevices: [VoiceAudioDevice] = []
    private var _devices: [VoiceAudioDevice] = []
    private var _failStart: Error?
    private var _muteResult = true
    private var handlers: VoiceDriverHandlers?
    private var live = false

    var started: [VoiceStartParameters] { lock.withLock { _started } }
    var stopCount: Int { lock.withLock { _stopCount } }
    var muteCalls: [Bool] { lock.withLock { _muteCalls } }
    /// Remote-playback mute requests, in order — the Speakers control (VO-4).
    var playbackMuteCalls: [Bool] { lock.withLock { _playbackMuteCalls } }
    var chosenDevices: [VoiceAudioDevice] { lock.withLock { _chosenDevices } }
    var devices: [VoiceAudioDevice] { get { lock.withLock { _devices } } set { lock.withLock { _devices = newValue } } }
    var failStart: Error? { get { lock.withLock { _failStart } } set { lock.withLock { _failStart = newValue } } }
    /// What `setMuted` reports back, as `realtimeLocalMute` can refuse.
    var muteResult: Bool { get { lock.withLock { _muteResult } } set { lock.withLock { _muteResult = newValue } } }

    func setHandlers(_ h: VoiceDriverHandlers) { lock.withLock { handlers = h } }
    func start(_ p: VoiceStartParameters) throws {
        if let e = failStart { throw e }
        lock.withLock { _started.append(p); live = true }
    }
    func stop() { lock.withLock { if live { _stopCount += 1 }; live = false } }
    func setMuted(_ muted: Bool) -> Bool {
        lock.withLock { _muteCalls.append(muted) }
        return muteResult
    }
    func setPlaybackMuted(_ muted: Bool) {
        lock.withLock { _playbackMuteCalls.append(muted) }
    }
    func listAudioDevices() -> [VoiceAudioDevice] { lock.withLock { live ? _devices : [] } }
    func chooseAudioDevice(_ d: VoiceAudioDevice) { lock.withLock { _chosenDevices.append(d) } }
    private var _shareStarts = 0
    private var _shareStops = 0
    var shareStarts: Int { lock.withLock { _shareStarts } }
    var shareStops: Int { lock.withLock { _shareStops } }
    func startScreenShare() { lock.withLock { _shareStarts += 1 } }
    func stopScreenShare() { lock.withLock { _shareStops += 1 } }

    // Scripting
    private var h: VoiceDriverHandlers? { lock.withLock { handlers } }
    func connecting(reconnecting: Bool = false) { h?.onConnecting(reconnecting) }
    func started(reconnecting: Bool = false) {
        if let p = lock.withLock({ _started.last }), p.startMuted, !reconnecting { _ = setMuted(true) }
        h?.onStarted(reconnecting)
    }
    func dropped() { h?.onDropped() }
    func cancelledReconnect() { h?.onCancelledReconnect() }
    func stopped(_ status: VoiceSessionStatus) { h?.onStopped(status) }
    func join(_ id: String, externalUserID: String) { h?.onAttendeesJoined([VoiceAttendee(id: id, externalUserID: externalUserID)]) }
    func leave(_ id: String, externalUserID: String = "") { h?.onAttendeesLeft([VoiceAttendee(id: id, externalUserID: externalUserID)]) }
    func volume(_ updates: [VoiceVolume]) { h?.onVolumeChanged(updates) }
    /// Connect's data message on `AMAZON_CONNECT_SCREEN_SHARING`, as `{"message": …}`.
    func shareSignal(_ message: String) { h?.onScreenShareSignal(Data(#"{"message":"\#(message)"}"#.utf8)) }
    func shareSignalRaw(_ data: Data) { h?.onScreenShareSignal(data) }
    func shareStarted() { h?.onScreenShareStarted() }
    func shareStopped(failed: Bool) { h?.onScreenShareStopped(failed) }
}

enum VoiceFixtures {
    static let meetingJSON = Data("""
    {"MeetingId":"m-1","MediaRegion":"ca-central-1","MediaPlacement":{"AudioHostUrl":"a.example:3478","AudioFallbackUrl":"wss://f.example","SignalingUrl":"wss://s.example","TurnControlUrl":"https://t.example","EventIngestionUrl":"https://i.example"}}
    """.utf8)
    static let attendeeJSON = Data(#"{"AttendeeId":"att-local","JoinToken":"jt-1"}"#.utf8)
    static let meetingMissingHost = Data("""
    {"MeetingId":"m-1","MediaRegion":"ca-central-1","MediaPlacement":{"AudioFallbackUrl":"wss://f.example","SignalingUrl":"wss://s.example","TurnControlUrl":"https://t.example"}}
    """.utf8)

    static func credentials(meeting: Data = meetingJSON, attendee: Data = attendeeJSON) -> VoiceContactCredentials {
        VoiceContactCredentials(contactID: "c-1", participantID: "p-1", participantToken: "tok",
                                meetingJSON: meeting, attendeeJSON: attendee, expiresAt: nil)
    }
}

/// Collects transport events with a bounded wait.
actor TransportEventLog {
    private(set) var events: [TransportEvent] = []
    func add(_ e: TransportEvent) { events.append(e) }
    func waitFor(_ n: Int, timeout: Duration = .seconds(2)) async -> [TransportEvent] {
        let deadline = ContinuousClock.now + timeout
        while events.count < n, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        return events
    }
}

func attachLog(_ transport: VoiceTransport) -> (TransportEventLog, Task<Void, Never>) {
    let log = TransportEventLog()
    let stream = transport.events
    let pump = Task { for await e in stream { await log.add(e) } }
    return (log, pump)
}

/// Polls a condition instead of sleeping a fixed time: the actor hop's latency is not a constant.
func eventually(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

/// The same, for main-actor state (`TouchpointSession`).
@MainActor
func eventuallyOnMain(_ timeout: Duration = .seconds(2), _ cond: @MainActor () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await cond()
}

/// A sleeper that suspends the first-join timeout until a test explicitly `fire()`s it, so VO-5 is
/// proven without waiting 30 s. Mirrors `HeldClock` in the Live Sync tests.
final class HeldVoiceClock: VoiceSleeping, @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var _requested: [Duration] = []
    private var order: [UUID] = []
    var requested: [Duration] { lock.withLock { _requested } }
    var pending: Int { lock.withLock { waiters.count } }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        lock.withLock { _requested.append(duration); order.append(id) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                lock.withLock { waiters[id] = c }
            }
        } onCancel: {
            let w = lock.withLock { waiters.removeValue(forKey: id) }
            w?.resume(throwing: CancellationError())
        }
    }

    /// Lets only the timeout scheduled first elapse, so a stale timer can be told from a current one.
    func fireOldest() {
        let w: CheckedContinuation<Void, any Error>? = lock.withLock {
            guard let id = order.first(where: { waiters[$0] != nil }) else { return nil }
            order.removeAll { $0 == id }
            return waiters.removeValue(forKey: id)
        }
        w?.resume()
    }

    /// Lets every pending timeout elapse.
    func fire() {
        let ws = lock.withLock { let w = Array(waiters.values); waiters = [:]; return w }
        for w in ws { w.resume() }
    }

    func waitForPending(_ timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if pending > 0 { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return pending > 0
    }
}

