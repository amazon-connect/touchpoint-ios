#if canImport(CallKit) && !os(macOS)
import AVFAudio
import CallKit
import Foundation
import TouchpointCore

/// The one real `CallProviding` + `CallControlling`: a `CXProvider` and a `CXCallController`.
///
/// Lifted from the Connect in-app-calling sample's `CallKitManager` and `CallKitCallController`,
/// with the delegate reduced to a forwarding shell: every decision lives in `TouchpointCallManager`,
/// which is tested without CallKit. Two deliberate differences from the sample: `supportsVideo` is
/// off (audio only) and there is no PushKit (outbound only). The host still declares the `voip`
/// background mode: CallKit refuses an outbound start without it.
@MainActor
public final class CallKitCallSystem: NSObject, CallProviding, CallControlling {
    private var cxProvider: CXProvider
    private let cxController = CXCallController()
    private weak var delegate: (any CallProviderDelegate)?

    public var configuration: CallProviderConfiguration? {
        didSet {
            guard let configuration else { return }
            cxProvider.configuration = Self.cxConfiguration(configuration)
        }
    }

    /// The system call UI shows the app's own name (iOS 14+ `CXProviderConfiguration()`); the
    /// contact centre's name is the call's *handle*, supplied per call by the manager.
    public override init() {
        self.cxProvider = CXProvider(configuration: Self.cxConfiguration(CallProviderConfiguration()))
        super.init()
    }

    public func setDelegate(_ delegate: any CallProviderDelegate) {
        self.delegate = delegate
        // nil queue: callbacks on the main queue, where the manager lives.
        cxProvider.setDelegate(self, queue: nil)
    }

    public func report(_ report: CallSystemReport) {
        switch report {
        case .outgoingStartedConnecting(let id):
            cxProvider.reportOutgoingCall(with: id, startedConnectingAt: Date())
        case .outgoingConnected(let id):
            cxProvider.reportOutgoingCall(with: id, connectedAt: Date())
        case .ended(let id, let reason):
            let cx: CXCallEndedReason
            switch reason { case .remoteEnded: cx = .remoteEnded; case .failed: cx = .failed; case .unanswered: cx = .unanswered }
            cxProvider.reportCall(with: id, endedAt: Date(), reason: cx)
        }
    }

    public func request(_ request: CallSystemRequest) async throws {
        let action: CXAction
        switch request {
        case .start(let id, let handle):
            action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: handle))
        case .end(let id):
            action = CXEndCallAction(call: id)
        case .setMuted(let id, let muted):
            action = CXSetMutedCallAction(call: id, muted: muted)
        }
        try await cxController.request(CXTransaction(action: action))
    }

    static func cxConfiguration(_ c: CallProviderConfiguration) -> CXProviderConfiguration {
        let config = CXProviderConfiguration()
        config.supportsVideo = c.supportsVideo
        config.maximumCallGroups = c.maximumCallGroups
        config.maximumCallsPerCallGroup = c.maximumCallsPerCallGroup
        config.supportedHandleTypes = Set(c.supportedHandleTypes.map { _ in CXHandle.HandleType.generic })
        config.iconTemplateImageData = c.iconTemplateImageData
        config.ringtoneSound = c.ringtoneSound
        config.includesCallsInRecents = c.includesCallsInRecents
        return config
    }
}

extension CallKitCallSystem: CXProviderDelegate {
    // `setDelegate(self, queue: nil)` delivers every callback on the main queue. The CXAction and
    // CXProvider objects are not Sendable and the compiler will not let them cross into a main-actor
    // closure even though we are already on main, so they are driven here, in the nonisolated
    // callback, and only Sendable values (the UUID, a Bool) reach the manager. The action itself is
    // parked in a `@unchecked Sendable` box so the fulfil/fail happens on main once the manager answers.
    // `self` is a main-actor class and so Sendable; the delegate is read inside the main-actor task.

    public nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in await self.delegate?.providerDidReset() }
    }

    public nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        // The sample reports supportsHolding/DTMF off via a CXCallUpdate here; ours also comes from
        // the provider configuration, so the update carries the handle and the same denials.
        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.localizedCallerName = action.handle.value
        update.supportsHolding = false
        update.supportsDTMF = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.hasVideo = false
        provider.reportCall(with: action.callUUID, updated: update)
        let id = action.callUUID, outcome = ActionOutcome(action)
        Task { @MainActor in outcome.settle(await self.delegate?.performStartCall(id) == true) }
    }

    public nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let id = action.callUUID, outcome = ActionOutcome(action)
        Task { @MainActor in outcome.settle(await self.delegate?.performEndCall(id) == true) }
    }

    public nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let id = action.callUUID, muted = action.isMuted, outcome = ActionOutcome(action)
        Task { @MainActor in outcome.settle(await self.delegate?.performSetMuted(id, muted) == true) }
    }

    public nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // CallKit has resolved the action itself; our pending outcome for it must not settle it again.
        ActionOutcome.cancel(action)
        let id = (action as? CXCallAction)?.callUUID
        Task { @MainActor in if let id { await self.delegate?.actionTimedOut(id) } }
    }

    public nonisolated func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // No hold: Chime has no hold primitive. The configuration says so; refuse anyway.
        action.fail()
    }

    public nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in await self.delegate?.audioSessionDidActivate() }
    }

    public nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in await self.delegate?.audioSessionDidDeactivate() }
    }
}

/// Parks a `CXAction` until the manager has answered, then fulfils or fails it — **once**. CallKit
/// requires exactly one `fulfill`/`fail`; a timeout resolves the action on CallKit's side, after which
/// our late answer must be dropped, not delivered. Pending outcomes are tracked by action identity
/// so the timeout callback can cancel the matching one.
private final class ActionOutcome: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: ActionOutcome] = [:]

    private let action: CXAction
    private var settled = false

    init(_ action: CXAction) {
        self.action = action
        Self.lock.withLock { Self.pending[ObjectIdentifier(action)] = self }
    }

    @MainActor func settle(_ fulfilled: Bool) {
        let first: Bool = Self.lock.withLock {
            defer { Self.pending[ObjectIdentifier(action)] = nil }
            if settled { return false }
            settled = true
            return true
        }
        guard first else { return }
        fulfilled ? action.fulfill() : action.fail()
    }

    /// CallKit resolved this action itself (timeout). Mark it settled so a late answer is dropped.
    static func cancel(_ action: CXAction) {
        lock.withLock {
            pending[ObjectIdentifier(action)]?.settled = true
            pending[ObjectIdentifier(action)] = nil
        }
    }
}
#endif
