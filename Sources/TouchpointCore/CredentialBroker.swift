import Foundation

/// Sits between the SDK and the host's `TouchpointBackend`.
///
/// - Live Sync credentials are **cached**: coalesced across concurrent callers, refreshed when less
///   than `refreshFraction` of their lifetime remains, and persisted only to the Keychain with
///   `whenUnlockedThisDeviceOnly`.
/// - Contact credentials (chat, voice) are **per contact** and are never cached for *starting*:
///   each `start` mints a new contact. Chat credentials are **persisted under their contact id**
///   so `resume(contactID:)` can reconnect after process death; they are forgotten when the
///   contact ends (a dead token has no business staying in the Keychain).
/// What Live Sync needs from a credential provider: a current key pair, and a way to say the one it
/// was given no longer works. `CredentialBroker` is the production conformer; a test fake is the other.
/// Declared in Core so `TouchpointLiveSync` depends on the seam, not the broker's full surface.
public protocol LiveSyncCredentialSource: Sendable {
    func liveSyncCredentials() async throws -> LiveSyncCredentials
    func invalidateLiveSyncCredentials() async
}

public actor CredentialBroker: LiveSyncCredentialSource {
    /// What a modality does when a mid-session refresh fails.
    public enum RefreshFailurePolicy: Sendable, Equatable {
        /// Chat: emit `failed(.credentialVendingFailed)`, go to `reconnecting`, keep the outbox.
        case retainAndReconnect
        /// Voice: a dead Chime meeting cannot be rejoined on new credentials; end the contact.
        case endContact
    }

    public static func refreshFailurePolicy(for modality: Modality) -> RefreshFailurePolicy {
        switch modality {
        case .chat: .retainAndReconnect
        case .voice: .endContact
        }
    }

    private let backend: any TouchpointBackend
    private let keychain: any KeychainStore
    private let refreshFraction: Double
    private let now: @Sendable () -> Date

    private static let liveSyncKey = "livesync.credentials.v1"

    private var liveSync: Cached<LiveSyncCredentials>?
    private var inFlight: Task<LiveSyncCredentials, Error>?
    private var generation: UInt = 0

    /// - Parameter refreshFraction: Refresh when *less than* this fraction of the credential's
    ///   lifetime remains. `0.2` means "refresh in the last 20%". `0` disables early refresh;
    ///   expired credentials are still never returned.
    public init(
        backend: any TouchpointBackend,
        keychain: any KeychainStore,
        refreshFraction: Double = 0.2,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.backend = backend
        self.keychain = keychain
        self.refreshFraction = min(max(refreshFraction, 0), 1)
        self.now = now
    }

    // MARK: Contact credentials — pass-through, error-mapped

    public func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        let c = try await vend { try await backend.startChatContact(request) }
        await persistChat(c)
        return c
    }

    /// The persisted chat credentials for a contact started on this device, if still held.
    public func storedChatCredentials(contactID: String) async -> ChatContactCredentials? {
        guard let data = try? await keychain.get(Self.contactKey(contactID)),
              let m = try? JSONDecoder().decode(StoredChat.self, from: data) else { return nil }
        return ChatContactCredentials(contactID: m.c, participantID: m.p, participantToken: m.t, expiresAt: m.e)
    }

    public func forgetContactCredentials(contactID: String) async {
        try? await keychain.delete(Self.contactKey(contactID))
    }

    public func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        try await vend { try await backend.startVoiceContact(request) }
    }

    // MARK: Live Sync credentials — cached and coalesced

    public func liveSyncCredentials() async throws -> LiveSyncCredentials {
        if liveSync == nil { liveSync = await loadFromKeychain() }
        if let cached = liveSync, isFresh(cached) { return cached.value }

        // Every waiter — originator or coalesced — receives the same mapped error (C1), and every
        // waiter gets the same early-refresh fallback: a refresh failure must not turn a credential
        // that is still valid into a failed call. The fallback is re-read at failure time so a
        // credential that expired during the vend, or was invalidated during it, is never returned.
        if let inFlight {
            do { return try await inFlight.value } catch { return try stillValidCachedValue(or: error) }
        }
        let generation = self.generation
        let task = Task<LiveSyncCredentials, Error> { [backend] in
            do { return try await backend.liveSyncCredentials() } catch { throw Self.map(error) }
        }
        inFlight = task
        defer { if inFlight == task { inFlight = nil } }
        let fresh: LiveSyncCredentials
        do { fresh = try await task.value } catch { return try stillValidCachedValue(or: error) }
        // An invalidate that raced this vend bumps the generation; the stale result is returned to
        // its caller but never cached (m1).
        if generation == self.generation {
            let cached = Cached(value: fresh, issuedAt: now())
            liveSync = cached
            await persist(cached)
        }
        return fresh
    }

    /// Drop the cached Live Sync credentials so the next call re-vends. Used on deliberate rotation;
    /// the transport reconnects to pick the new key up.
    public func invalidateLiveSyncCredentials() async {
        generation &+= 1
        liveSync = nil
        inFlight = nil   // post-invalidate callers must re-vend, not join the stale vend (nil, not cancel: the originator still gets its result)
        try? await keychain.delete(Self.liveSyncKey)
    }

    // MARK: Internals

    private struct Cached<T: Codable & Sendable>: Codable, Sendable {
        var value: T
        var issuedAt: Date
    }

    /// Private Codable mirror: `ChatContactCredentials` is deliberately not Codable, so the
    /// one place that serialises it — into the Keychain, never a log — does so explicitly.
    private struct StoredChat: Codable { var c: String; var p: String; var t: String?; var e: Date? }

    private static func contactKey(_ contactID: String) -> String { "contact.chat.v1.\(contactID)" }

    private func persistChat(_ c: ChatContactCredentials) async {
        guard let data = try? JSONEncoder().encode(StoredChat(c: c.contactID, p: c.participantID, t: c.participantToken, e: c.expiresAt)) else { return }
        try? await keychain.set(data, for: Self.contactKey(c.contactID), accessibility: .whenUnlockedThisDeviceOnly)
    }

    /// Early-refresh failure path: the cached credential if it is still unexpired *now*, else rethrow.
    private func stillValidCachedValue(or error: Error) throws -> LiveSyncCredentials {
        if let cached = liveSync, !isExpired(cached) { return cached.value }
        throw error
    }

    private func isExpired(_ cached: Cached<LiveSyncCredentials>) -> Bool {
        guard let expiresAt = cached.value.expiresAt else { return false }
        return now() >= expiresAt
    }

    private func isFresh(_ cached: Cached<LiveSyncCredentials>) -> Bool {
        guard let expiresAt = cached.value.expiresAt else { return true }
        let t = now()
        guard t < expiresAt else { return false }
        let lifetime = expiresAt.timeIntervalSince(cached.issuedAt)
        guard lifetime > 0 else { return false }
        let remainingFraction = expiresAt.timeIntervalSince(t) / lifetime
        return remainingFraction >= refreshFraction
    }

    private func loadFromKeychain() async -> Cached<LiveSyncCredentials>? {
        guard let data = try? await keychain.get(Self.liveSyncKey) else { return nil }
        return try? JSONDecoder().decode(Cached<LiveSyncCredentials>.self, from: data)
    }

    private func persist(_ cached: Cached<LiveSyncCredentials>) async {
        guard let data = try? JSONEncoder().encode(cached) else { return }
        try? await keychain.set(data, for: Self.liveSyncKey, accessibility: .whenUnlockedThisDeviceOnly)
    }

    private func vend<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.map(error) }
    }

    private static func map(_ error: Error) -> TouchpointError {
        if let e = error as? TouchpointError { return e }
        // Only the type and code are kept: an underlying description could carry a URL with a key in it.
        return .credentialVendingFailed(underlying: "\(type(of: error))(\((error as NSError).code))")
    }
}
