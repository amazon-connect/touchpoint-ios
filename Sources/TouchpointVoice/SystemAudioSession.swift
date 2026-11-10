#if canImport(AVFAudio) && !os(macOS)
import AVFAudio
import Foundation
import TouchpointCore

/// The one real `VoiceAudioSessionControlling`, over `AVAudioSession.sharedInstance()`.
///
/// Sets category and mode only — never `setActive`. The Connect sample calls `setActive(true)` in its
/// `configureAudioSession`, which under CallKit fights the system for the session: the thing
/// not to copy.
final class SystemAudioSession: VoiceAudioSessionControlling, @unchecked Sendable {
    private let session = AVAudioSession.sharedInstance()

    func configureForCall(options: VoiceAudioSessionOptions) throws {
        let avOptions = Self.categoryOptions(options)
        if session.category != .playAndRecord || session.categoryOptions != avOptions || session.mode != .voiceChat {
            try session.setCategory(.playAndRecord, mode: .voiceChat, options: avOptions)
        }
    }

    /// The compiler fork. Same option bit either way; the spelling differs by SDK.
    static func categoryOptions(_ o: VoiceAudioSessionOptions) -> AVAudioSession.CategoryOptions {
        var av: AVAudioSession.CategoryOptions = []
        if o.contains(.defaultToSpeaker) { av.insert(.defaultToSpeaker) }
        if o.contains(.allowBluetoothHandsFree) {
            #if compiler(>=6.2)
            av.insert(.allowBluetoothHFP)
            #else
            av.insert(.allowBluetooth)
            #endif
        }
        if o.contains(.allowBluetoothA2DP) { av.insert(.allowBluetoothA2DP) }
        return av
    }

    func currentOutputName() -> String? {
        session.currentRoute.outputs.first?.portName
    }

    func observe(_ handlers: VoiceAudioSessionHandlers) -> any VoiceAudioObservationToken {
        let center = NotificationCenter.default
        let route = center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: nil) { [session] note in
            let raw = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            handlers.onRouteChange(Self.reason(raw), session.currentRoute.outputs.first?.portName)
        }
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: nil) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                handlers.onInterruptionBegan()
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                handlers.onInterruptionEnded(opts.contains(.shouldResume))
            @unknown default:
                break
            }
        }
        return Token([route, interruption])
    }

    static func reason(_ r: AVAudioSession.RouteChangeReason?) -> VoiceRouteChangeReason {
        switch r {
        case .newDeviceAvailable?: .newDeviceAvailable
        case .oldDeviceUnavailable?: .oldDeviceUnavailable
        case .categoryChange?: .categoryChange
        case .override?: .override
        case .wakeFromSleep?: .wakeFromSleep
        case .noSuitableRouteForCategory?: .noSuitableRouteForCategory
        case .routeConfigurationChange?: .routeConfigurationChange
        default: .unknown
        }
    }

    private final class Token: VoiceAudioObservationToken, @unchecked Sendable {
        private let observers: [NSObjectProtocol]
        init(_ observers: [NSObjectProtocol]) { self.observers = observers }
        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}

/// The microphone permission, through `AVAudioApplication`. Requests only when the host's
/// `PermissionPolicy` allows `.microphone` — the SDK never asks on its own.
public struct MicrophonePermissionRequester: PermissionRequesting {
    public init() {}

    public func status(of permission: Permission) async -> PermissionStatus {
        guard permission == .microphone else { return .notDetermined }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestIfAllowed(_ permission: Permission, policy: PermissionPolicy) async -> PermissionStatus {
        guard permission == .microphone, policy.allows(permission) else { return await status(of: permission) }
        let granted = await AVAudioApplication.requestRecordPermission()
        return granted ? .granted : .denied
    }
}
#endif
