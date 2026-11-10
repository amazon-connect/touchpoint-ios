import Foundation
import TouchpointCore

// The seam between `TouchpointCallManager` and CallKit.
//
// CallKit is iOS-only and its classes cannot be driven in a unit test, so the manager's logic —
// the ordering rule, the state machine, the end-reason mapping — sits behind these two protocols and
// is tested on macOS against a fake. The one real conformance, `CallKitCallSystem`, wraps
// `CXProvider` + `CXCallController` and compiles only where CallKit can be imported. The shape
// follows the Connect in-app-calling sample's CallKitManager/CallKitCallController split.

/// What the manager asks the system to do. Mirrors `CXStartCallAction` / `CXEndCallAction` /
/// `CXSetMutedCallAction`, requested through a `CXCallController` so the system call UI and ours
/// agree.
public enum CallSystemRequest: Sendable, Equatable {
    case start(UUID, handle: String)
    case end(UUID)
    case setMuted(UUID, Bool)
}

/// What the manager tells the system happened.
public enum CallSystemReport: Sendable, Equatable {
    case outgoingStartedConnecting(UUID)
    case outgoingConnected(UUID)
    case ended(UUID, CallEndedReason)
}

/// `CXCallEndedReason`, minus the inbound-only cases this SDK never produces.
public enum CallEndedReason: Sendable, Equatable {
    case remoteEnded
    case failed
    /// Ended before it connected and not by the far side — the system or the host gave up.
    case unanswered
}

/// `CXProviderConfiguration` as the manager sets it. Exposed so a test asserts the policy
/// (no hold, no video, one call) rather than trusting it.
public struct CallProviderConfiguration: Sendable, Equatable {
    public enum HandleType: Sendable, Equatable { case generic }
    public var supportsHolding = false
    public var supportsVideo = false
    public var maximumCallGroups = 1
    public var maximumCallsPerCallGroup = 1
    public var supportedHandleTypes: Set<HandleType> = [.generic]
    public var ringtoneSound: String? = nil
    public var iconTemplateImageData: Data? = nil
    /// Whether calls appear in Phone › Recents (and sync via iCloud). **Off by default**: a call to a
    /// bank is a relationship the customer may not want on a shared device, and tapping the entry
    /// would send an intent this app does not handle. A host opts in.
    public var includesCallsInRecents = false
}

/// The system's side of the conversation: `CXProviderDelegate`, reduced to what we handle. Each
/// `perform…` returns whether the action was fulfilled (`true`) or failed.
@MainActor
public protocol CallProviderDelegate: AnyObject {
    func performStartCall(_ id: UUID) async -> Bool
    func performEndCall(_ id: UUID) async -> Bool
    func performSetMuted(_ id: UUID, _ muted: Bool) async -> Bool
    func audioSessionDidActivate() async
    func audioSessionDidDeactivate() async
    func providerDidReset() async
    /// CallKit gave up waiting for an action to be fulfilled (the main thread was busy).
    func actionTimedOut(_ id: UUID) async
}

/// `CXProvider`: reports and the delegate.
@MainActor
public protocol CallProviding: AnyObject {
    var configuration: CallProviderConfiguration? { get set }
    func setDelegate(_ delegate: any CallProviderDelegate)
    func report(_ report: CallSystemReport)
}

/// `CXCallController`: requests.
@MainActor
public protocol CallControlling: AnyObject {
    func request(_ request: CallSystemRequest) async throws
}

/// What the manager drives when the system says so. Supplied by whoever owns the transport and the
/// audio session (the host, or the SDK's own wiring).
public struct CallActions: Sendable {
    /// Set the audio session category and mode. Called inside the start action, **before** it is
    /// fulfilled, and never activates the session: CallKit does that, and `startMedia` follows.
    public var configureAudioSession: @MainActor () throws -> Void
    /// Start media — vend credentials, join the meeting. Called from `didActivateAudioSession`,
    /// downstream of CallKit granting the audio session. Must not block: it is a fire-and-forget
    /// kick to an async pipeline.
    public var startMedia: @MainActor () -> Void
    /// End the contact. Async so the transport's stop can be awaited before the action is fulfilled.
    public var endCall: @MainActor () async -> Void
    /// Mute or unmute. Throwing fails the `CXSetMutedCallAction` honestly — `VoiceTransport.setMuted`
    /// throws when Chime refuses, and that must reach the system UI rather than be swallowed.
    public var setMuted: @MainActor (Bool) async throws -> Void

    public init(configureAudioSession: @escaping @MainActor () throws -> Void,
                startMedia: @escaping @MainActor () -> Void,
                endCall: @escaping @MainActor () async -> Void,
                setMuted: @escaping @MainActor (Bool) async throws -> Void) {
        self.configureAudioSession = configureAudioSession
        self.startMedia = startMedia
        self.endCall = endCall
        self.setMuted = setMuted
    }
}
