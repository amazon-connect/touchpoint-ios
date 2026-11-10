#if canImport(AmazonChimeSDK)
import AmazonChimeSDK
import Foundation
import TouchpointCore

/// The one real `ChimeMeetingSessionDriving`: a `DefaultMeetingSession` per call.
///
/// Kept thin on purpose — mapping only. `callKitEnabled` is forced on: the call manager
/// owns `AVAudioSession` activation, and Chime must not activate it itself. Audio only
/// (`AudioDeviceCapabilities.inputAndOutput`, no video), redundancy on, `mono48K` for voice.
final class ChimeMeetingSessionDriver: NSObject, ChimeMeetingSessionDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var session: DefaultMeetingSession?
    private var handlers: VoiceDriverHandlers?
    private var startMuted = false
    /// Screen share. Chime's own capture and content share; this class only starts and
    /// stops them. `wantsShare` is what the customer last asked for: Chime's stops are no-ops while
    /// the consent prompt is up and before the content client connects, so a start that lands after
    /// a stop is caught here and undone.
    private var listensForScreenShare = false
    private var wantsShare = false
    private var capture: InAppScreenCaptureSource?
    /// The redacting wrapper: a `VideoSource` fed from `capture` that masks
    /// host-marked views before Chime encodes the frame. It, not `capture`, is handed to Chime.
    private var redactor: RedactingVideoSource?
    /// Chime's logger prints to the console; we hand it a silent one. Diagnostics come later.
    private let logger = ConsoleLogger(name: "TouchpointVoice", level: .OFF)

    func setHandlers(_ handlers: VoiceDriverHandlers) {
        lock.withLock { self.handlers = handlers }
    }

    func start(_ p: VoiceStartParameters) throws {
        let credentials = MeetingSessionCredentials(attendeeId: p.attendeeID, externalUserId: p.externalUserID, joinToken: p.joinToken)
        let urls = MeetingSessionURLs(audioFallbackUrl: p.urls.audioFallbackURL,
                                      audioHostUrl: p.urls.audioHostURL,
                                      turnControlUrl: p.urls.turnControlURL,
                                      signalingUrl: p.urls.signalingURL,
                                      urlRewriter: URLRewriterUtils.defaultUrlRewriter,
                                      ingestionUrl: p.urls.ingestionURL)
        let configuration = MeetingSessionConfiguration(meetingId: p.meetingID, externalMeetingId: nil,
                                                        credentials: credentials, urls: urls,
                                                        urlRewriter: URLRewriterUtils.defaultUrlRewriter)
        // A session left over from a call that ended on the network side (the transport calls `stop`
        // for that too, but belt and braces): never attach a second set of observers.
        stop()
        let session = DefaultMeetingSession(configuration: configuration, logger: logger)
        lock.withLock { self.session = session; self.startMuted = p.startMuted; self.listensForScreenShare = p.screenShare }
        session.audioVideo.addAudioVideoObserver(observer: self)
        session.audioVideo.addRealtimeObserver(observer: self)
        // Before `start`, as the AWS sample registers them: the signal can arrive with the join.
        if p.screenShare {
            session.audioVideo.addRealtimeDataMessageObserver(topic: ScreenShareSignal.topic, observer: self)
            session.audioVideo.addContentShareObserver(observer: self)
        }
        do {
            try session.audioVideo.start(audioVideoConfiguration: AudioVideoConfiguration(
                audioMode: .mono48K,
                audioDeviceCapabilities: .inputAndOutput,
                callKitEnabled: true,
                enableAudioRedundancy: true,
                videoMaxResolution: .videoDisabled,
                reconnectTimeoutMs: p.reconnectTimeoutMs))
        } catch {
            // A failed start must not leave a session with observers attached for the next attempt.
            session.audioVideo.removeAudioVideoObserver(observer: self)
            session.audioVideo.removeRealtimeObserver(observer: self)
            if p.screenShare {
                session.audioVideo.removeRealtimeDataMessageObserverFromTopic(topic: ScreenShareSignal.topic)
                session.audioVideo.removeContentShareObserver(observer: self)
            }
            lock.withLock { self.session = nil }
            throw error
        }
    }

    /// Stops and detaches. The transport is reusable (`connect` is allowed again after `.ended`), so
    /// a second call creates a second `DefaultMeetingSession`; the first one's observers must not
    /// still be attached or its asynchronous stop callback would land on the new contact.
    func stop() {
        // Content share first: `audioVideo.stop()` leaves it, and the process-wide screen recorder,
        // running — the agent's tile would outlive the call.
        stopScreenShare()
        let (session, listened): (DefaultMeetingSession?, Bool) = lock.withLock {
            let current = (self.session, self.listensForScreenShare)
            self.session = nil
            self.listensForScreenShare = false
            return current
        }
        guard let session else { return }
        session.audioVideo.removeAudioVideoObserver(observer: self)
        session.audioVideo.removeRealtimeObserver(observer: self)
        if listened {
            session.audioVideo.removeRealtimeDataMessageObserverFromTopic(topic: ScreenShareSignal.topic)
            session.audioVideo.removeContentShareObserver(observer: self)
        }
        session.audioVideo.stop()
    }

    func startScreenShare() {
        let source = InAppScreenCaptureSource(logger: logger)
        // Interpose the redactor as the in-app source's sink; Chime is handed the redactor instead
        // of the raw capture, so every frame passes through the mask (I3).
        let redactor = RedactingVideoSource(contentHint: source.videoContentHint, store: .shared)
        source.addVideoSink(sink: redactor)
        let previous: (InAppScreenCaptureSource?, RedactingVideoSource?) = lock.withLock {
            let old = (self.capture, self.redactor)
            self.capture = source
            self.redactor = redactor
            self.wantsShare = true
            return old
        }
        if let old = previous.0 {
            old.removeCaptureSourceObserver(observer: self)
            if let oldRedactor = previous.1 { old.removeVideoSink(sink: oldRedactor) }
            old.stop()
        }
        setRedactionCapturing(true)
        source.addCaptureSourceObserver(observer: self)
        source.start()
    }

    func stopScreenShare() {
        let (session, source, redactor): (DefaultMeetingSession?, InAppScreenCaptureSource?, RedactingVideoSource?) = lock.withLock {
            let current = (self.session, self.capture, self.redactor)
            self.wantsShare = false
            self.capture = nil
            self.redactor = nil
            return current
        }
        setRedactionCapturing(false)
        if let source {
            source.removeCaptureSourceObserver(observer: self)
            if let redactor { source.removeVideoSink(sink: redactor) }
            source.stop()
        }
        session?.audioVideo.stopContentShare()
    }

    /// Start / stop the main-actor view-snapshot loop that feeds the mask. No-op where UIKit is
    /// unavailable (it is always present on the iOS build that links Chime).
    private func setRedactionCapturing(_ on: Bool) {
        #if canImport(UIKit)
        Task { @MainActor in RedactionCoordinator.shared.setCapturing(on) }
        #endif
    }

    func setMuted(_ muted: Bool) -> Bool {
        guard let session = lock.withLock({ self.session }) else { return false }
        return muted ? session.audioVideo.realtimeLocalMute() : session.audioVideo.realtimeLocalUnmute()
    }

    func setPlaybackMuted(_ muted: Bool) {
        guard let session = lock.withLock({ self.session }) else { return }
        _ = muted ? session.audioVideo.realtimePlaybackMute() : session.audioVideo.realtimePlaybackUnmute()
    }

    func listAudioDevices() -> [VoiceAudioDevice] {
        guard let session = lock.withLock({ self.session }) else { return [] }
        return session.audioVideo.listAudioDevices().map { Self.map($0) }
    }

    func chooseAudioDevice(_ device: VoiceAudioDevice) {
        guard let session = lock.withLock({ self.session }) else { return }
        if let match = session.audioVideo.listAudioDevices().first(where: { Self.map($0) == device }) {
            session.audioVideo.chooseAudioDevice(mediaDevice: match)
        }
    }

    private var h: VoiceDriverHandlers? { lock.withLock { handlers } }

    static func map(_ d: MediaDevice) -> VoiceAudioDevice {
        let kind: VoiceAudioDevice.Kind
        switch d.type {
        case .audioBluetooth: kind = .bluetooth
        case .audioWiredHeadset: kind = .wiredHeadset
        case .audioBuiltInSpeaker: kind = .speaker
        case .audioHandset: kind = .handset
        default: kind = .other
        }
        return VoiceAudioDevice(label: d.label, kind: kind)
    }

    static func map(_ status: MeetingSessionStatus) -> VoiceSessionStatus {
        switch status.statusCode {
        case .ok: .ok
        case .audioDisconnected: .audioDisconnected
        case .connectionHealthReconnect: .connectionHealthReconnect
        case .networkBecomePoor: .networkBecomePoor
        case .audioServerHungup: .audioServerHungup
        case .audioJoinedFromAnotherDevice: .audioJoinedFromAnotherDevice
        case .audioInternalServerError: .audioInternalServerError
        case .audioAuthenticationRejected: .audioAuthenticationRejected
        case .audioCallAtCapacity: .audioCallAtCapacity
        case .audioServiceUnavailable: .audioServiceUnavailable
        case .audioDisconnectAudio: .audioDisconnectAudio
        case .audioCallEnded: .audioCallEnded
        case .audioInputDeviceNotResponding: .audioInputDeviceNotResponding
        case .audioOutputDeviceNotResponding: .audioOutputDeviceNotResponding
        default: .unknown(status.statusCode.rawValue)
        }
    }
}

extension ChimeMeetingSessionDriver: AudioVideoObserver {
    func audioSessionDidStartConnecting(reconnecting: Bool) { h?.onConnecting(reconnecting) }
    func audioSessionDidStart(reconnecting: Bool) {
        // Synchronously, before the transport hears about it: the audio client starts unmuted.
        let (session, muted) = lock.withLock { (self.session, self.startMuted) }
        if muted, let session { _ = session.audioVideo.realtimeLocalMute() }
        h?.onStarted(reconnecting)
    }
    func audioSessionDidDrop() { h?.onDropped() }
    func audioSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) { h?.onStopped(Self.map(sessionStatus)) }
    func audioSessionDidCancelReconnect() { h?.onCancelledReconnect() }
    func connectionDidRecover() {}
    func connectionDidBecomePoor() {}
    func videoSessionDidStartConnecting() {}
    func videoSessionDidStartWithStatus(sessionStatus: MeetingSessionStatus) {}
    func videoSessionDidStopWithStatus(sessionStatus: MeetingSessionStatus) {}
    func remoteVideoSourcesDidBecomeAvailable(sources: [RemoteVideoSource]) {}
    func remoteVideoSourcesDidBecomeUnavailable(sources: [RemoteVideoSource]) {}
    func cameraSendAvailabilityDidChange(available: Bool) {}
}

extension ChimeMeetingSessionDriver: DataMessageObserver {
    func dataMessageDidReceived(dataMessage: DataMessage) {
        guard dataMessage.topic == ScreenShareSignal.topic else { return }
        h?.onScreenShareSignal(dataMessage.data)
    }
}

extension ChimeMeetingSessionDriver: CaptureSourceObserver {
    /// The customer allowed capture: hand Chime's own source to Chime's content share — unless the
    /// customer stopped while the prompt was up.
    func captureDidStart() {
        let (session, source, redactor, wanted) = lock.withLock { (self.session, self.capture, self.redactor, self.wantsShare) }
        guard wanted, let session, let source else {
            source?.stop()
            return
        }
        let content = ContentShareSource()
        // Chime encodes from the redactor, never the raw capture (I3).
        content.videoSource = redactor ?? source
        session.audioVideo.startContentShare(source: content)
    }

    func captureDidStop() {}

    /// Includes "Don't Allow" on the consent prompt.
    func captureDidFail(error: CaptureSourceError) {
        let (session, source, redactor): (DefaultMeetingSession?, InAppScreenCaptureSource?, RedactingVideoSource?) = lock.withLock {
            let current = (self.session, self.capture, self.redactor)
            self.capture = nil
            self.redactor = nil
            self.wantsShare = false
            return current
        }
        setRedactionCapturing(false)
        source?.removeCaptureSourceObserver(observer: self)
        if let source, let redactor { source.removeVideoSink(sink: redactor) }
        session?.audioVideo.stopContentShare()
        h?.onScreenShareStopped(true)
    }
}

extension ChimeMeetingSessionDriver: ContentShareObserver {
    func contentShareDidStart() {
        let (session, wanted) = lock.withLock { (self.session, self.wantsShare) }
        guard wanted else {
            session?.audioVideo.stopContentShare()
            return
        }
        h?.onScreenShareStarted()
    }

    func contentShareDidStop(status: ContentShareStatus) {
        let (source, redactor): (InAppScreenCaptureSource?, RedactingVideoSource?) = lock.withLock {
            let current = (self.capture, self.redactor)
            self.capture = nil
            self.redactor = nil
            self.wantsShare = false
            return current
        }
        setRedactionCapturing(false)
        if let source {
            source.removeCaptureSourceObserver(observer: self)
            if let redactor { source.removeVideoSink(sink: redactor) }
            source.stop()
        }
        h?.onScreenShareStopped(status.statusCode != .ok)
    }
}

extension ChimeMeetingSessionDriver: RealtimeObserver {
    func attendeesDidJoin(attendeeInfo: [AttendeeInfo]) { h?.onAttendeesJoined(attendeeInfo.map { VoiceAttendee(id: $0.attendeeId, externalUserID: $0.externalUserId) }) }
    func attendeesDidLeave(attendeeInfo: [AttendeeInfo]) { h?.onAttendeesLeft(attendeeInfo.map { VoiceAttendee(id: $0.attendeeId, externalUserID: $0.externalUserId) }) }
    func attendeesDidDrop(attendeeInfo: [AttendeeInfo]) { h?.onAttendeesLeft(attendeeInfo.map { VoiceAttendee(id: $0.attendeeId, externalUserID: $0.externalUserId) }) }
    func attendeesDidMute(attendeeInfo: [AttendeeInfo]) {}
    func attendeesDidUnmute(attendeeInfo: [AttendeeInfo]) {}
    func volumeDidChange(volumeUpdates: [VolumeUpdate]) {
        h?.onVolumeChanged(volumeUpdates.map {
            VoiceVolume(attendeeID: $0.attendeeInfo.attendeeId,
                        isAudible: VoiceVolume.isAudible(level: $0.volumeLevel.rawValue))
        })
    }
    func signalStrengthDidChange(signalUpdates: [SignalUpdate]) {}
}
#endif
