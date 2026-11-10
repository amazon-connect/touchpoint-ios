import Foundation

extension Touchpoint {
    /// `true` only in debug builds — the compile-time witness that `DevelopmentBackend` is absent
    /// from release binaries. Tested in both configurations.
    public static let developmentBackendIsAvailable: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()
}

#if DEBUG
/// Debug-only backend that accepts literal Live Sync keys for a non-production deployment, so the
/// SDK can be exercised before a host backend exists. **Compiled out of release
/// builds**; a production host implements `TouchpointBackend` against its own service.
///
/// Chat and voice are optional closures because a literal participant token cannot be hard-coded —
/// `StartChatContact` must be called per contact — so the development path injects a vendor (a
/// local harness, or a stub) rather than pretending otherwise.
public struct DevelopmentBackend: TouchpointBackend {
    public struct LiveSyncLiterals: Sendable {
        public var deploymentKey: String
        public var apiKey: String
        public init(deploymentKey: String, apiKey: String) {
            self.deploymentKey = deploymentKey
            self.apiKey = apiKey
        }
    }

    public typealias ChatVendor = @Sendable (ChatContactRequest) async throws -> ChatContactCredentials
    public typealias VoiceVendor = @Sendable (VoiceContactRequest) async throws -> VoiceContactCredentials

    private let liveSync: LiveSyncLiterals
    private let chat: ChatVendor?
    private let voice: VoiceVendor?

    public init(liveSync: LiveSyncLiterals, chat: ChatVendor? = nil, voice: VoiceVendor? = nil) {
        self.liveSync = liveSync
        self.chat = chat
        self.voice = voice
    }

    public func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        guard let chat else {
            throw TouchpointError.invalidConfiguration("DevelopmentBackend has no chat vendor; pass `chat:` to start chat contacts")
        }
        return try await chat(request)
    }

    public func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        guard let voice else {
            throw TouchpointError.invalidConfiguration("DevelopmentBackend has no voice vendor; pass `voice:` to start voice contacts")
        }
        return try await voice(request)
    }

    public func liveSyncCredentials() async throws -> LiveSyncCredentials {
        LiveSyncCredentials(deploymentKey: liveSync.deploymentKey, apiKey: liveSync.apiKey, expiresAt: nil)
    }
}
#endif
