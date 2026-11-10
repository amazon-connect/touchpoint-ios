import Foundation
import Testing
@testable import TouchpointCore

/// A scripted backend: counts calls, can fail on demand, and vends credentials with a chosen lifetime.
actor ScriptedBackend: TouchpointBackend {
    var chatCalls = 0
    var voiceCalls = 0
    var liveSyncCalls = 0
    var failNext = false
    var lifetime: TimeInterval = 600
    var delay: Duration = .zero

    func setFailNext(_ v: Bool) { failNext = v }
    func setLifetime(_ v: TimeInterval) { lifetime = v }
    func setDelay(_ d: Duration) { delay = d }

    private func gate() async throws {
        if delay > .zero { try await Task.sleep(for: delay) }
        if failNext { failNext = false; throw URLError(.notConnectedToInternet) }
    }

    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        chatCalls += 1
        try await gate()
        return ChatContactCredentials(contactID: "contact-\(chatCalls)", participantID: "p", participantToken: "tok-\(chatCalls)", expiresAt: Date().addingTimeInterval(lifetime))
    }

    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials {
        voiceCalls += 1
        try await gate()
        return VoiceContactCredentials(contactID: "vcontact-\(voiceCalls)", participantID: "p", participantToken: "vtok-\(voiceCalls)", meetingJSON: Data("{}".utf8), attendeeJSON: Data("{}".utf8), expiresAt: Date().addingTimeInterval(lifetime))
    }

    func liveSyncCredentials() async throws -> LiveSyncCredentials {
        liveSyncCalls += 1
        try await gate()
        return LiveSyncCredentials(deploymentKey: "dep", apiKey: "key-\(liveSyncCalls)", expiresAt: Date().addingTimeInterval(lifetime))
    }
}

@Suite("CredentialBroker")
struct CredentialBrokerTests {
    @Test("Vends Live Sync credentials from the backend and caches them")
    func vendsAndCaches() async throws {
        let backend = ScriptedBackend()
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        let a = try await broker.liveSyncCredentials()
        let b = try await broker.liveSyncCredentials()
        #expect(a.apiKey == "key-1")
        #expect(b.apiKey == "key-1")
        #expect(await backend.liveSyncCalls == 1)
    }

    @Test("Refreshes when less than the configured fraction of lifetime remains")
    func refreshesBeforeExpiry() async throws {
        let backend = ScriptedBackend()
        await backend.setLifetime(10)
        // refresh when < 90% of lifetime remains, i.e. almost immediately
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore(), refreshFraction: 0.9)
        _ = try await broker.liveSyncCredentials()
        try await Task.sleep(for: .milliseconds(1_100))
        let b = try await broker.liveSyncCredentials()
        #expect(b.apiKey == "key-2")
        #expect(await backend.liveSyncCalls == 2)
    }

    @Test("Expired credentials are never returned from cache")
    func expiredNeverReturned() async throws {
        let backend = ScriptedBackend()
        await backend.setLifetime(0.05)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore(), refreshFraction: 0)
        _ = try await broker.liveSyncCredentials()
        try await Task.sleep(for: .milliseconds(100))
        let b = try await broker.liveSyncCredentials()
        #expect(b.apiKey == "key-2")
    }

    @Test("Concurrent requests coalesce into one backend call")
    func coalesces() async throws {
        let backend = ScriptedBackend()
        await backend.setDelay(.milliseconds(100))
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<20 { group.addTask { try await broker.liveSyncCredentials().apiKey } }
            var keys = Set<String>()
            for try await k in group { keys.insert(k) }
            #expect(keys == ["key-1"])
        }
        #expect(await backend.liveSyncCalls == 1)
    }

    @Test("A failed vend is not cached and the next call retries")
    func failureNotCached() async throws {
        let backend = ScriptedBackend()
        await backend.setFailNext(true)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        await #expect(throws: TouchpointError.self) { try await broker.liveSyncCredentials() }
        let ok = try await broker.liveSyncCredentials()
        #expect(ok.apiKey == "key-2")
    }

    @Test("Vend failure is mapped to credentialVendingFailed")
    func mapsError() async {
        let backend = ScriptedBackend()
        await backend.setFailNext(true)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        do {
            _ = try await broker.liveSyncCredentials()
            Issue.record("expected throw")
        } catch let e as TouchpointError {
            guard case .credentialVendingFailed = e else { Issue.record("wrong case \(e)"); return }
        } catch { Issue.record("wrong error type \(error)") }
    }

    @Test("Coalesced waiters receive the same mapped TouchpointError as the originator (C1)")
    func coalescedWaitersGetMappedError() async {
        let backend = ScriptedBackend()
        await backend.setDelay(.milliseconds(80)); await backend.setFailNext(true)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        var kinds = Set<String>()
        await withTaskGroup(of: String.self) { group in
            for _ in 0..<5 { group.addTask { do { _ = try await broker.liveSyncCredentials(); return "ok" } catch let e as TouchpointError { if case .credentialVendingFailed = e { return "mapped" } else { return "other-tp" } } catch { return "raw:\(type(of: error))" } } }
            for await k in group { kinds.insert(k) }
        }
        #expect(kinds == ["mapped"])
    }

    @Test("invalidate during an in-flight vend wins: the stale result is not cached (m1)")
    func invalidateBeatsInflight() async throws {
        let backend = ScriptedBackend()
        await backend.setDelay(.milliseconds(150))
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        let first = Task { try await broker.liveSyncCredentials() }
        try await Task.sleep(for: .milliseconds(30))
        await broker.invalidateLiveSyncCredentials()
        _ = try await first.value                      // returns key-1 to its caller
        let next = try await broker.liveSyncCredentials()
        #expect(next.apiKey == "key-2")               // but key-1 was not cached past the invalidate
    }

    @Test("A caller arriving after invalidate does not join the stale in-flight vend")
    func postInvalidateCallerRevends() async throws {
        let backend = ScriptedBackend()
        await backend.setDelay(.milliseconds(150))
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        let first = Task { try await broker.liveSyncCredentials() }
        try await Task.sleep(for: .milliseconds(30))
        await broker.invalidateLiveSyncCredentials()
        let second = try await broker.liveSyncCredentials()   // arrives while key-1 vend is still running
        _ = try await first.value
        #expect(second.apiKey == "key-2")
        #expect(await backend.liveSyncCalls == 2)
    }

    @Test("Early-refresh failure returns the still-valid cached credential instead of throwing")
    func earlyRefreshFailureFallsBack() async throws {
        let backend = ScriptedBackend()
        await backend.setLifetime(10)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore(), refreshFraction: 0.99)
        let a = try await broker.liveSyncCredentials()
        try await Task.sleep(for: .milliseconds(200))       // now inside the refresh window, not expired
        await backend.setFailNext(true)
        let b = try await broker.liveSyncCredentials()       // refresh fails → cached value, no throw
        #expect(b.apiKey == a.apiKey)
        let c = try await broker.liveSyncCredentials()       // next call retries and succeeds
        #expect(c.apiKey == "key-3")                          // call 2 was the failed refresh
        #expect(await backend.liveSyncCalls == 3)
    }

    @Test("Coalesced waiters also get the early-refresh fallback")
    func coalescedWaitersGetFallback() async throws {
        let backend = ScriptedBackend()
        await backend.setLifetime(10)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore(), refreshFraction: 0.99)
        let a = try await broker.liveSyncCredentials()
        try await Task.sleep(for: .milliseconds(150))
        await backend.setDelay(.milliseconds(100)); await backend.setFailNext(true)
        var keys = Set<String>()
        await withTaskGroup(of: String.self) { g in
            for _ in 0..<5 { g.addTask { (try? await broker.liveSyncCredentials().apiKey) ?? "THREW" } }
            for await k in g { keys.insert(k) }
        }
        #expect(keys == [a.apiKey])
    }

    @Test("The fallback never returns a credential that expired during the failed vend")
    func fallbackNeverReturnsExpired() async throws {
        let backend = ScriptedBackend()
        await backend.setLifetime(0.25)
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore(), refreshFraction: 0.99)
        _ = try await broker.liveSyncCredentials()
        try await Task.sleep(for: .milliseconds(50))          // in the refresh window, still valid
        await backend.setDelay(.milliseconds(300)); await backend.setFailNext(true)   // expires mid-vend
        await #expect(throws: TouchpointError.self) { _ = try await broker.liveSyncCredentials() }
    }

    @Test("Contact credentials are per-contact, never cached across starts")
    func contactCredentialsNotCached() async throws {
        let backend = ScriptedBackend()
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        let a = try await broker.startChatContact(ChatContactRequest(displayName: "a", attributes: [:]))
        let b = try await broker.startChatContact(ChatContactRequest(displayName: "a", attributes: [:]))
        #expect(a.contactID != b.contactID)
        #expect(await backend.chatCalls == 2)
    }

    @Test("Live Sync credentials persist to the keychain and survive a new broker")
    func persistsToKeychain() async throws {
        let keychain = InMemoryKeychainStore()
        let backend = ScriptedBackend()
        _ = try await CredentialBroker(backend: backend, keychain: keychain).liveSyncCredentials()
        let second = CredentialBroker(backend: backend, keychain: keychain)
        let c = try await second.liveSyncCredentials()
        #expect(c.apiKey == "key-1")
        #expect(await backend.liveSyncCalls == 1)
        #expect(await keychain.allAccessibility().allSatisfy { $0 == .whenUnlockedThisDeviceOnly })
    }

    @Test("Invalidate forces the next call to re-vend (rotation)")
    func invalidate() async throws {
        let backend = ScriptedBackend()
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        _ = try await broker.liveSyncCredentials()
        await broker.invalidateLiveSyncCredentials()
        let b = try await broker.liveSyncCredentials()
        #expect(b.apiKey == "key-2")
    }

    @Test("Refresh-failure policy: chat keeps going, voice ends the contact")
    func refreshFailurePolicy() {
        #expect(CredentialBroker.refreshFailurePolicy(for: .chat) == .retainAndReconnect)
        #expect(CredentialBroker.refreshFailurePolicy(for: .voice) == .endContact)
    }

    @Test("Credential values never appear in a description or log string")
    func noCredentialInDescription() {
        let c = ChatContactCredentials(contactID: "c1", participantID: "p1", participantToken: "SECRET-TOKEN", expiresAt: .distantFuture)
        let s = String(describing: c) + String(reflecting: c) + "\(c)"
        #expect(!s.contains("SECRET-TOKEN"))
        let ls = LiveSyncCredentials(deploymentKey: "dep", apiKey: "SECRET-KEY", expiresAt: nil)
        #expect(!"\(ls)".contains("SECRET-KEY"))
    }

    // MARK: Contact credentials persist for resume

    @Test("Chat contact credentials persist to the Keychain under the contact id and come back for resume")
    func chatCredentialsPersistForResume() async throws {
        let keychain = InMemoryKeychainStore()
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        let c = try await broker.startChatContact(ChatContactRequest(displayName: "a"))
        #expect(await broker.storedChatCredentials(contactID: c.contactID) == c)
        // A fresh broker over the same keychain (process restart) still finds them.
        let later = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        #expect(await later.storedChatCredentials(contactID: c.contactID) == c)
        await later.forgetContactCredentials(contactID: c.contactID)
        #expect(await later.storedChatCredentials(contactID: c.contactID) == nil)
        #expect(await broker.storedChatCredentials(contactID: "never") == nil)
    }

    @Test("Persisted contact credentials are stored whenUnlockedThisDeviceOnly and never in plain JSON of the public type")
    func chatCredentialsKeychainPosture() async throws {
        let keychain = InMemoryKeychainStore()
        let broker = CredentialBroker(backend: ScriptedBackend(), keychain: keychain)
        let c = try await broker.startChatContact(ChatContactRequest(displayName: "a"))
        _ = c
        let classes = await keychain.allAccessibility()
        #expect(!classes.isEmpty && classes.allSatisfy { $0 == .whenUnlockedThisDeviceOnly })
    }
}

/// A backend whose chat contacts carry no participant token (web's `customChatClient`).
actor TokenlessBackend: TouchpointBackend {
    func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials {
        ChatContactCredentials(contactID: "c-tokenless", participantID: "p", participantToken: nil, expiresAt: nil)
    }
    func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw URLError(.unsupportedURL) }
    func liveSyncCredentials() async throws -> LiveSyncCredentials { throw URLError(.unsupportedURL) }
}

extension CredentialBrokerTests {
    @Test("Custom chat client: a contact with no participant token persists and resumes as such")
    func tokenlessChatPersists() async throws {
        let keychain = InMemoryKeychainStore()
        let broker = CredentialBroker(backend: TokenlessBackend(), keychain: keychain)
        let c = try await broker.startChatContact(ChatContactRequest(displayName: "a"))
        #expect(c.participantToken == nil)
        let later = CredentialBroker(backend: TokenlessBackend(), keychain: keychain)
        let stored = await later.storedChatCredentials(contactID: c.contactID)
        #expect(stored == c && stored?.participantToken == nil)
    }
}
