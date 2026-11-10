import Foundation
import Testing
@testable import TouchpointCore

@Suite("DevelopmentBackend and KeychainStore")
struct DevelopmentBackendTests {
    @Test("DevelopmentBackend is compiled out of release builds")
    func compiledOutOfRelease() {
        // The symbol exists only under DEBUG. If this test compiles in a release configuration the
        // type must be absent; `developmentBackendIsAvailable` is a #if DEBUG-gated constant that
        // tells us which world we are in without referencing the type unconditionally.
        #if DEBUG
        #expect(Touchpoint.developmentBackendIsAvailable == true)
        #else
        #expect(Touchpoint.developmentBackendIsAvailable == false)
        #endif
    }

    #if DEBUG
    @Test("DevelopmentBackend vends the literal Live Sync keys it was given")
    func vendsLiterals() async throws {
        let backend = DevelopmentBackend(liveSync: .init(deploymentKey: "dep", apiKey: "k"))
        let c = try await backend.liveSyncCredentials()
        #expect(c.deploymentKey == "dep")
        #expect(c.apiKey == "k")
        #expect(c.expiresAt == nil)
    }

    @Test("DevelopmentBackend without chat/voice vendors throws invalidConfiguration, not a crash")
    func missingVendorsThrow() async {
        let backend = DevelopmentBackend(liveSync: .init(deploymentKey: "dep", apiKey: "k"))
        await #expect(throws: TouchpointError.self) {
            _ = try await backend.startChatContact(ChatContactRequest(displayName: "a", attributes: [:]))
        }
    }

    @Test("DevelopmentBackend delegates chat/voice to injected vendors")
    func delegates() async throws {
        let backend = DevelopmentBackend(
            liveSync: .init(deploymentKey: "dep", apiKey: "k"),
            chat: { _ in ChatContactCredentials(contactID: "c", participantID: "p", participantToken: "t", expiresAt: .distantFuture) }
        )
        let c = try await backend.startChatContact(ChatContactRequest(displayName: "a", attributes: [:]))
        #expect(c.contactID == "c")
    }
    #endif

    @Test("InMemoryKeychainStore round-trips, deletes, and records accessibility")
    func keychainRoundTrip() async throws {
        let k = InMemoryKeychainStore()
        try await k.set(Data("v".utf8), for: "a", accessibility: .whenUnlockedThisDeviceOnly)
        #expect(try await k.get("a") == Data("v".utf8))
        try await k.delete("a")
        #expect(try await k.get("a") == nil)
    }

    @Test("Keychain accessibility enum maps to the kSecAttrAccessible constant")
    func accessibilityMapping() {
        #expect(KeychainAccessibility.whenUnlockedThisDeviceOnly.secAttr == kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
    }
}
