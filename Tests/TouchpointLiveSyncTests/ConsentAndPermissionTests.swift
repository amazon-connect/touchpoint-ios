import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - Consent decision sourced from the user, revocation, permission denial, manifests

private let prompt = ConsentPrompt(dataDescription: "which screen you are on", recipient: "the assistant",
                                   privacyPolicyURL: URL(string: "https://example.invalid/privacy"))

extension LiveSyncStubBackedSuites {
    @Suite("Consent controller: the real decision behind the gate", .serialized)
    @MainActor
    struct ConsentControllerTests {
        @Test("K1: nothing stored → needsPrompt, client stays held, no POST even when connected with context")
        func nothingStoredHolds() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: InMemoryKeychainStore(), deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl.load()
            #expect(ctl.needsPrompt)
            #expect(client.consent == .held)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            _ = await eventually { client.connectionState == .connected }
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.isEmpty, "consent gates initialisation of the context path")
        }

        @Test("K2: grant → persisted, client granted, held context flushes; a second controller over the same store does not prompt")
        func grantPersists() async throws {
            StubURLProtocol.reset()
            let keychain = InMemoryKeychainStore()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl.load()
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            _ = await eventually { client.connectionState == .connected }
            await ctl.grant()
            #expect(!ctl.needsPrompt)
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })

            let client2 = try makeTestClient(consent: .held)
            let ctl2 = LiveSyncConsentController(client: client2, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl2.load()
            #expect(!ctl2.needsPrompt)
            #expect(client2.consent == .granted)
        }

        @Test("K3: the decision is per deployment — another deployment asks again")
        func perDeployment() async throws {
            let keychain = InMemoryKeychainStore()
            let c1 = try makeTestClient(consent: .held)
            let ctl1 = LiveSyncConsentController(client: c1, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl1.grant()
            let c2 = try makeTestClient(consent: .held)
            let ctl2 = LiveSyncConsentController(client: c2, store: ConsentStore(keychain: keychain, deploymentID: "d2"), prompt: prompt, announce: { _ in })
            await ctl2.load()
            #expect(ctl2.needsPrompt)
            #expect(c2.consent == .held)
        }

        @Test("K4: revoke mid-session tears the socket down, clears the context, persists denied, announces, and a reconnect posts nothing")
        func revokeMidSession() async throws {
            StubURLProtocol.reset()
            let keychain = InMemoryKeychainStore()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            let announced = Capture<[String]>([])
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { announced.value.append($0) })
            await ctl.grant()
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })

            await ctl.deny()
            #expect(t.closed)
            #expect(client.connectionState == .disconnected)
            #expect(!client.hasPendingContext)
            #expect(await ConsentStore(keychain: keychain, deploymentID: "d1").decision() == .denied)
            #expect(announced.value.count == 1)
            client.connect()
            let t2 = try #require(await transports.waitFor(2)); t2.opened()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.count == 1)
        }

        @Test("K5: a stored denial is honoured on load without prompting; declining from the prompt does not announce")
        func storedDenial() async throws {
            let keychain = InMemoryKeychainStore()
            await ConsentStore(keychain: keychain, deploymentID: "d1").record(.denied)
            let client = try makeTestClient(consent: .held)
            let announced = Capture(0)
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in announced.value += 1 })
            await ctl.load()
            #expect(!ctl.needsPrompt)
            #expect(client.consent == .denied)
            await ctl.deny()                       // declining again: no revocation announcement
            #expect(announced.value == 0)
        }

        @Test("K6: reset forgets the decision and asks again")
        func reset() async throws {
            let keychain = InMemoryKeychainStore()
            let client = try makeTestClient(consent: .held)
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl.grant()
            await ctl.reset()
            #expect(ctl.needsPrompt)
            #expect(client.consent == .held)
            #expect(await ConsentStore(keychain: keychain, deploymentID: "d1").decision() == nil)
        }

        @Test("K7: a client created with the debug development default is not overridden by the store")
        func developmentDefaultRespected() async throws {
            #if DEBUG
            let keychain = InMemoryKeychainStore()
            await ConsentStore(keychain: keychain, deploymentID: "d1").record(.denied)
            let client = try makeTestClient(consent: .development)
            let ctl = LiveSyncConsentController(client: client, store: ConsentStore(keychain: keychain, deploymentID: "d1"), prompt: prompt, announce: { _ in })
            await ctl.load()
            #expect(!ctl.needsPrompt)
            #expect(client.consent == .granted)
            #endif
        }
    }
}

/// A scripted requester, as a modality's real one must behave: asks only when the policy allows.
private actor ScriptedRequester: PermissionRequesting {
    var statuses: [Permission: PermissionStatus]
    var requests: [Permission] = []
    init(_ s: [Permission: PermissionStatus]) { statuses = s }
    func status(of permission: Permission) async -> PermissionStatus { statuses[permission] ?? .notDetermined }
    func requestIfAllowed(_ permission: Permission, policy: PermissionPolicy) async -> PermissionStatus {
        guard policy.allows(permission) else { return statuses[permission] ?? .notDetermined }
        requests.append(permission)
        statuses[permission] = .granted
        return .granted
    }
}

@Suite("Permission denial as a product state")
struct PermissionDenialTests {
    @Test("M1: the default policy never requests; opting in requests exactly that permission")
    func policy() async {
        let r = ScriptedRequester([.microphone: .notDetermined])
        #expect(await r.requestIfAllowed(.microphone, policy: .never) == .notDetermined)
        #expect(await r.requests.isEmpty, "no permission request occurs without opt-in")
        #expect(await r.requestIfAllowed(.microphone, policy: PermissionPolicy(mayRequest: [.microphone])) == .granted)
        #expect(await r.requests == [.microphone])
    }

    @Test("M2: a denial maps to its product consequence and carries a Settings link")
    func consequences() async {
        let r = ScriptedRequester([.microphone: .denied])
        let mic = await r.denial(for: .microphone)
        #expect(mic?.consequence == .voiceUnavailableChatRemains)
        #if canImport(UIKit)
        #expect(mic?.settingsURL?.scheme == "app-settings")
        #else
        #expect(mic?.settingsURL == nil, "no Settings app to deep-link to off iOS")
        #endif
        #expect(await ScriptedRequester([.microphone: .granted]).denial(for: .microphone) == nil)
        #expect(await ScriptedRequester([:]).denial(for: .microphone) == nil, "not yet asked is not a denial")
    }

    @Test("M3: the denial copy and the consent copy resolve from the catalog, with no raw keys leaking")
    func stringsResolve() {
        for p in Permission.allCases {
            #expect(!TouchpointStrings.permissionTitle(p).hasPrefix("touchpoint."))
            #expect(!TouchpointStrings.permissionBody(p).hasPrefix("touchpoint."))
        }
        #expect(!TouchpointStrings.consentTitle.hasPrefix("touchpoint."))
        let body = TouchpointStrings.consentBody(data: "DATA", recipient: "RECIPIENT")
        #expect(body.contains("DATA") && body.contains("RECIPIENT"))
        #expect(!TouchpointStrings.openSettings.hasPrefix("touchpoint."))
    }
}

@Suite("Privacy manifests")
struct PrivacyManifestTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test("every target's manifest is a valid plist with tracking off, and Live Sync declares what it sends")
    func manifests() throws {
        for target in ["TouchpointCore/Resources", "TouchpointChat", "TouchpointVoice", "TouchpointLiveSync"] {
            let url = root.appendingPathComponent("Sources/\(target)/PrivacyInfo.xcprivacy")
            let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any], "\(target)")
            #expect(plist["NSPrivacyTracking"] as? Bool == false, "\(target)")
            #expect(plist["NSPrivacyAccessedAPITypes"] as? [Any] != nil, "\(target)")
            #expect((plist["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true, "\(target)")
        }
        let ls = try #require(try PropertyListSerialization.propertyList(
            from: Data(contentsOf: root.appendingPathComponent("Sources/TouchpointLiveSync/PrivacyInfo.xcprivacy")), format: nil) as? [String: Any])
        let types = try #require(ls["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        #expect(types.count == 1)
        #expect(types[0]["NSPrivacyCollectedDataType"] as? String == "NSPrivacyCollectedDataTypeProductInteraction")
        #expect(types[0]["NSPrivacyCollectedDataTypeLinked"] as? Bool == false)
        #expect(types[0]["NSPrivacyCollectedDataTypeTracking"] as? Bool == false)
    }
}
