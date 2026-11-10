import Foundation
import TouchpointCore

// The seam between the SDK and `AVAudioSession`.
//
// Chime *splits* audio-session ownership rather than taking it: there is no `setCategory`, `setMode`
// or `setActive` anywhere in its Swift layer. So the host — this SDK — sets the
// category and mode, **inside the CXStartCallAction handler before fulfilling**, and never calls
// `setActive`: CallKit activates the session, and by the time `didActivate` fires it has activated
// whatever category was in effect. A literal "configure in didActivate" design produces no audio.
//
// The seam exists so the ordering, the Bluetooth option fork, and the observers are tested on
// macOS; `SystemAudioSession` is the one real conformer.

/// What the voice stack needs from the audio session. Deliberately has no `setActive`.
protocol VoiceAudioSessionControlling: Sendable {
    /// `.playAndRecord`, `.voiceChat`, with the options the call needs. Idempotent.
    func configureForCall(options: VoiceAudioSessionOptions) throws
    /// The current output route's description, for the announcement.
    func currentOutputName() -> String?
    /// Route-change and interruption observation. The returned token ends observation when released.
    func observe(_ handlers: VoiceAudioSessionHandlers) -> any VoiceAudioObservationToken
}

protocol VoiceAudioObservationToken: AnyObject, Sendable {}

struct VoiceAudioSessionHandlers: Sendable {
    var onRouteChange: @Sendable (VoiceRouteChangeReason, _ outputName: String?) -> Void
    var onInterruptionBegan: @Sendable () -> Void
    var onInterruptionEnded: @Sendable (_ shouldResume: Bool) -> Void
}

/// `AVAudioSession.RouteChangeReason`, in the SDK's words. `.categoryChange` and `.override` are the
/// two that fire most under CallKit and the two Chime's own observer drops.
public enum VoiceRouteChangeReason: Sendable, Equatable {
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRouteForCategory
    case routeConfigurationChange
    case unknown
}

/// The category options the call sets. Bluetooth hands-free is the one with history: `.allowBluetooth`
/// was deprecated and renamed `.allowBluetoothHFP` only in the iOS 26 SDK, so at the iOS 17 floor it
/// is a compiler fork, not a flat swap — `#if compiler(>=6.2)` selects the new spelling; on iOS 17–25
/// at runtime the option bit is the same.
public struct VoiceAudioSessionOptions: Sendable, Equatable, OptionSet {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let defaultToSpeaker = VoiceAudioSessionOptions(rawValue: 1 << 0)
    /// Bluetooth hands-free profile (HFP) — headsets and car kits.
    public static let allowBluetoothHandsFree = VoiceAudioSessionOptions(rawValue: 1 << 1)
    /// Bluetooth A2DP — output-only; useful for a speaker, useless for a call's microphone.
    public static let allowBluetoothA2DP = VoiceAudioSessionOptions(rawValue: 1 << 2)

    /// What a voice call wants: speaker by default (the phone is not at the ear in an app call), and
    /// Bluetooth hands-free so a headset or a car carries both directions.
    public static let call: VoiceAudioSessionOptions = [.defaultToSpeaker, .allowBluetoothHandsFree]
}
