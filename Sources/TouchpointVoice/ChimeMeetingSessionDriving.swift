import Foundation
import TouchpointCore

// The seam between `VoiceTransport` and the Amazon Chime SDK.
//
// Chime ships iOS-only binaries, so the transport's logic — credential decode, the call state
// machine, participant mapping, mute, device choice — lives behind this protocol and is tested on
// macOS against a fake. The one real conformer, `ChimeMeetingSessionDriver`, compiles only where
// `AmazonChimeSDK` can be imported. Mirrors `ChatSessionDriving` in TouchpointChat.

/// What the transport needs from a meeting session. Deliberately smaller than `AudioVideoFacade`.
protocol ChimeMeetingSessionDriving: Sendable {
    func setHandlers(_ handlers: VoiceDriverHandlers)
    /// Joins the meeting. `callKitEnabled` is always `true` here: the call manager owns the
    /// audio session activation, and Chime must not activate it itself.
    func start(_ parameters: VoiceStartParameters) throws
    func stop()
    /// Mutes or unmutes the local attendee. Returns whether the SDK accepted it.
    func setMuted(_ muted: Bool) -> Bool
    /// Mutes or unmutes **remote playback** — the audio the customer hears, not their microphone.
    /// Chime's `realtimePlaybackMute` / `realtimePlaybackUnmute`; the Speakers control (VO-4). Its
    /// boolean result is not surfaced: unlike the microphone, a refused playback mute is not a
    /// privacy concern, and both UIs already reflect the requested state.
    func setPlaybackMuted(_ muted: Bool)
    /// Only meaningful after the audio session has started: before the category is set the
    /// Bluetooth route is invisible.
    func listAudioDevices() -> [VoiceAudioDevice]
    func chooseAudioDevice(_ device: VoiceAudioDevice)
    /// Starts Chime's in-app screen capture and, once it is running, content share. Returns at once:
    /// iOS's consent prompt and the content attendee's join report back through the handlers.
    func startScreenShare()
    /// Stops capture and content share, including one still waiting on the consent prompt.
    func stopScreenShare()
}

/// Callbacks a driver raises, in Chime's own vocabulary. All `@Sendable`; the transport hops onto
/// its own actor.
struct VoiceDriverHandlers: Sendable {
    var onConnecting: @Sendable (_ reconnecting: Bool) -> Void
    var onStarted: @Sendable (_ reconnecting: Bool) -> Void
    var onDropped: @Sendable () -> Void
    var onCancelledReconnect: @Sendable () -> Void
    var onStopped: @Sendable (VoiceSessionStatus) -> Void
    var onAttendeesJoined: @Sendable ([VoiceAttendee]) -> Void
    var onAttendeesLeft: @Sendable ([VoiceAttendee]) -> Void
    /// Audio levels, reduced to audibility. Chime raises these several times a second while anyone
    /// is talking; the transport collapses them to two booleans and reports only changes.
    var onVolumeChanged: @Sendable ([VoiceVolume]) -> Void
    /// A raw data message on Connect's `AMAZON_CONNECT_SCREEN_SHARING` topic. Parsed by the transport.
    var onScreenShareSignal: @Sendable (Data) -> Void = { _ in }
    /// Chime's content share is live: the agent can see the screen.
    var onScreenShareStarted: @Sendable () -> Void = {}
    /// Capture or content share ended. `failed` covers a declined consent prompt too: iOS reports
    /// "Don't Allow" as a capture failure, indistinguishable from any other.
    var onScreenShareStopped: @Sendable (_ failed: Bool) -> Void = { _ in }
}

/// One attendee's audio level, reduced to the only question the UI asks: are they audible? A level
/// rather than an amplitude, because the ripple is on or off — nothing reads a magnitude.
struct VoiceVolume: Sendable, Equatable {
    var attendeeID: String
    var isAudible: Bool

    /// Maps Chime's `VolumeLevel` raw value: `muted` (-1) and `notSpeaking` (0) are silence; `low`
    /// (1), `medium` (2) and `high` (3) are speech. An unrecognised level is silence rather than a
    /// ripple that never stops.
    static func isAudible(level: Int) -> Bool { (1...3).contains(level) }
}

/// Everything `DefaultMeetingSession` needs, flattened. Built from `VoiceMeetingConfiguration`.
struct VoiceStartParameters: Sendable, Equatable {
    var meetingID: String
    var attendeeID: String
    /// Connect's attendee carries no external user id; Chime requires a non-optional string. `""`.
    var externalUserID: String
    var joinToken: String
    var urls: VoiceMeetingURLs
    var reconnectTimeoutMs: Int
    var callKitEnabled: Bool
    /// Applied by the driver inside `audioSessionDidStart`, before the event is forwarded, so a mute
    /// requested before the join never leaves the microphone live for the actor hop.
    var startMuted: Bool = false
    /// Listen for Connect's screen-sharing signal. Only when the host opted in, so a call without it
    /// registers nothing it never asked for.
    var screenShare: Bool = false
}

// The join token is a credential. Default reflection would print it in a test failure diff
// or a `dump`; these redact it the way Core's credential types do.
extension VoiceStartParameters: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "VoiceStartParameters(meetingID: \(meetingID), attendeeID: \(attendeeID), joinToken: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["meetingID": meetingID, "attendeeID": attendeeID, "joinToken": "<redacted>"]) }
}

struct VoiceMeetingURLs: Sendable, Equatable {
    var audioHostURL: String
    var audioFallbackURL: String
    var signalingURL: String
    var turnControlURL: String
    /// Chime client telemetry endpoint. Deliberately `nil`: forwarding it switches on Chime's own
    /// event ingestion from the device.
    var ingestionURL: String?
}

struct VoiceAttendee: Sendable, Equatable {
    var id: String
    var externalUserID: String
}

/// `MeetingSessionStatusCode`, minus video and content-share cases this SDK never sees.
enum VoiceSessionStatus: Sendable, Equatable, Hashable {
    case ok
    case audioDisconnected
    case connectionHealthReconnect
    case networkBecomePoor
    case audioServerHungup
    case audioJoinedFromAnotherDevice
    case audioInternalServerError
    case audioAuthenticationRejected
    case audioCallAtCapacity
    case audioServiceUnavailable
    case audioDisconnectAudio
    case audioCallEnded
    case audioInputDeviceNotResponding
    case audioOutputDeviceNotResponding
    case unknown(UInt32)
}

/// An audio route, in the SDK's words rather than Chime's or AVFoundation's.
public struct VoiceAudioDevice: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable, Comparable {
        // Order is preference order, lowest first: Bluetooth wins, then wired, then the speaker,
        // then the handset earpiece.
        case other
        case handset
        case speaker
        case wiredHeadset
        case bluetooth
    }
    public let label: String
    public let kind: Kind

    public init(label: String, kind: Kind) {
        self.label = label
        self.kind = kind
    }
}
