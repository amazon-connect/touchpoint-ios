import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - The four defects

extension LiveSyncStubBackedSuites {
    @Suite("Live Sync defects fixed on absorption", .serialized)
    @MainActor
    struct LiveSyncDefectTests {
        @Test("D1: after the socket loop ends on its own, connect() works again (it used to be a silent no-op)")
        func reconnectAfterSelfTerminatedLoop() async throws {
            let transports = FakeTransportFactory()
            var policy = ReconnectionPolicy.default
            policy.maxAttempts = 0                          // give up at once, so the loop self-terminates
            let client = try makeTestClient(transports: transports, reconnection: policy)
            client.connect()
            let first = try #require(await transports.waitFor(1))
            first.opened()
            first.end(error: .socketFailure(description: "server went away"))
            #expect(await eventually { client.connectionState == .disconnected })
            client.connect()                                // must start a new loop
            #expect(await transports.waitFor(2) != nil, "connect() after a self-terminated loop did nothing")
            #expect(client.connectionState != .disconnected)
        }

        @Test("D1b: a configuration error ends the loop; fixing it and calling connect() runs again")
        func reconnectAfterConfigurationError() async throws {
            let transports = FakeTransportFactory()
            let credentials = FakeCredentialSource(deploymentKey: "")   // invalid until rotated
            let client = try makeTestClient(credentials: credentials, transports: transports)
            let errors = Capture<[LiveSyncError]>([])
            client.onError = { errors.value.append($0) }
            client.connect()
            #expect(await eventually { client.connectionState == .disconnected })
            #expect(errors.value.count == 1)
            await credentials.rotate(to: "test-api-key-placeholder")
            await credentials.setDeploymentKey("deployment-key")
            client.connect()
            #expect(await transports.waitFor(1) != nil)
        }

        @Test("D2: a non-HTTP response to the context POST is a failure, not success")
        func nonHTTPResponseIsFailure() async throws {
            StubURLProtocol.reset(nonHTTP: true)
            let client = try makeTestClient()
            try await client.sendContext(scopes: ["booking"])
            await #expect(throws: LiveSyncError.self) { try await client.postContext() }
        }

        @Test("D3: backoff never collapses toward zero — jitter is one-sided, and the floor is the base delay")
        func oneSidedJitter() {
            let policy = ReconnectionPolicy.default
            for attempt in 1...20 {
                let low = policy.delay(forAttempt: attempt, random: 0)
                let high = policy.delay(forAttempt: attempt, random: 1)
                #expect(low >= policy.initialDelay, "attempt \(attempt) went below the initial delay")
                #expect(high >= low)
                #expect(high <= policy.maxDelay * (1 + policy.jitterFactor) + .milliseconds(1))
            }
            #expect(policy.delay(forAttempt: 2, random: 0) > policy.delay(forAttempt: 1, random: 0))
        }

        @Test("D3b: Live Sync does not give up — attempts past maxAttempts keep the capped delay, the loop keeps running")
        func unboundedReconnect() async throws {
            let transports = FakeTransportFactory()
            let clock = ManualClock()
            var policy = ReconnectionPolicy.default
            policy.maxAttempts = 2
            let client = try makeTestClient(transports: transports, reconnection: policy, clock: clock)
            client.connect()
            for n in 1...4 {
                let t = try #require(await transports.waitFor(n))
                t.end(error: .socketFailure(description: "drop \(n)"))
            }
            #expect(await transports.waitFor(5) != nil, "the loop stopped after maxAttempts; Live Sync must outlive the policy's cap")
            #expect(clock.slept.count >= 4)
            #expect(clock.slept.last ?? .zero <= policy.maxDelay * (1 + policy.jitterFactor))
        }

        @Test("D4: no Origin header on the socket handshake")
        func noOriginHeader() async throws {
            let client = try makeTestClient()
            let request = try await client.makeSocketRequest()
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        }
    }

    // MARK: - Credentials through the broker

    @Suite("Live Sync credentials come from the broker", .serialized)
    @MainActor
    struct LiveSyncCredentialTests {
        @Test("C1: the socket URL carries the key the source vended, and the deployment key too")
        func socketCarriesVendedKey() async throws {
            let client = try makeTestClient(credentials: FakeCredentialSource(deploymentKey: "dep-1", apiKey: "key-one"))
            let request = try await client.makeSocketRequest()
            let q = Dictionary(uniqueKeysWithValues: (URLComponents(url: try #require(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            #expect(q["apiKey"] == "key-one")
            #expect(q["deploymentKey"] == "dep-1")
        }

        @Test("C2: every reconnect asks the source again, so a rotated key reaches the next socket")
        func reconnectUsesFreshKey() async throws {
            let credentials = FakeCredentialSource(apiKey: "key-A")
            let transports = FakeTransportFactory()
            let client = try makeTestClient(credentials: credentials, transports: transports)
            client.connect()
            let first = try #require(await transports.waitFor(1))
            #expect(first.request?.url?.query?.contains("apiKey=key-A") == true)
            await credentials.rotate(to: "key-B")
            first.end(error: .socketFailure(description: "drop"))
            let second = try #require(await transports.waitFor(2))
            #expect(second.request?.url?.query?.contains("apiKey=key-B") == true)
            #expect(await credentials.vends >= 2)
        }

        @Test("C3: rotateCredentials() invalidates the broker's cache and reconnects with the new key")
        func explicitRotation() async throws {
            let credentials = FakeCredentialSource(apiKey: "key-A")
            let transports = FakeTransportFactory()
            let client = try makeTestClient(credentials: credentials, transports: transports)
            client.connect()
            let first = try #require(await transports.waitFor(1))
            first.opened()
            await credentials.rotate(to: "key-B")
            await client.rotateCredentials()
            #expect(await credentials.invalidations == 1)
            #expect(first.closed)
            let second = try #require(await transports.waitFor(2))
            #expect(second.request?.url?.query?.contains("apiKey=key-B") == true)
        }

        @Test("C4: a 401/403 on the context POST invalidates the credentials and reconnects")
        func authFailureInvalidates() async throws {
            StubURLProtocol.reset(statusCode: 403, body: Data(#"{"message":"Forbidden"}"#.utf8))
            let credentials = FakeCredentialSource()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(credentials: credentials, transports: transports)
            try await client.sendContext(scopes: ["booking"])
            client.connect()
            let first = try #require(await transports.waitFor(1))
            first.opened()                                       // replays the context → 403
            #expect(await eventually { await credentials.invalidations == 1 })
            #expect(await transports.waitFor(2) != nil, "no reconnect after the auth failure")
        }

        @Test("C5: a vend failure is reported and retried with backoff, not terminal")
        func vendFailureRetries() async throws {
            let credentials = FakeCredentialSource()
            await credentials.fail(.credentialVendingFailed(underlying: "URLError(-1009)"))
            let transports = FakeTransportFactory()
            let clock = ManualClock()
            let client = try makeTestClient(credentials: credentials, transports: transports, clock: clock)
            let errors = Capture<[LiveSyncError]>([])
            client.onError = { errors.value.append($0) }
            client.connect()
            #expect(await eventually { clock.slept.count >= 2 })
            #expect(errors.value.contains { if case .credentialVendingFailed = $0 { true } else { false } })
            #expect(transports.count == 0)                        // never opened a socket without a key
            await credentials.fail(nil)
            #expect(await transports.waitFor(1) != nil)           // recovers once the vend works
        }

        @Test("C6: the channel comes from Core's LiveSyncChannel — canonical BCP 47 in the socket query and the context path")
        func channelFromCore() async throws {
            let config = try LiveSyncConfiguration(region: "us-west-2", conversationId: "c1",
                                                   channel: LiveSyncChannel(locale: Locale(identifier: "de_DE")))
            let client = try makeTestClient(configuration: config)
            #expect(try await client.makeSocketRequest().url?.query?.contains("channelKey=connect-de-DE") == true)
            #expect(try await client.makeContextRequest().url?.path == "/nlu/c/deployment-key/connect-de-DE/context")
        }
    }

    // MARK: - Consent gate: no context POST before consent is granted

    @Suite("Consent gates every context POST", .serialized)
    @MainActor
    struct LiveSyncConsentTests {
        @Test("S1: the default decision is held — sendContext while connected posts nothing and keeps the context")
        func heldByDefault() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { client.connectionState == .connected })
            let before = StubURLProtocol.recordedRequests.count
            try await client.sendContext(scopes: ["accounts"])
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.count == before)
            #expect(client.hasPendingContext)
        }

        @Test("S2: the replay on socket open is gated too")
        func replayIsGated() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { client.connectionState == .connected })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.isEmpty)
        }

        @Test("S3: granting consent flushes the held context exactly once")
        func grantFlushes() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .held)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { client.connectionState == .connected })
            await client.setConsent(.granted)
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.count == 1)
        }

        @Test("S4: denied posts nothing and reports consentNotGranted once")
        func deniedReportsOnce() async throws {
            StubURLProtocol.reset()
            let client = try makeTestClient(consent: .denied)
            let errors = Capture<[LiveSyncError]>([])
            client.onError = { errors.value.append($0) }
            try await client.sendContext(scopes: ["accounts"])
            try await client.sendContext(scopes: ["transactions"])
            #expect(StubURLProtocol.recordedRequests.isEmpty)
            #expect(errors.value == [.consentNotGranted])
        }

        @Test("S5: revoking consent closes the socket, clears the advertised context, and a later open posts nothing")
        func revokeTearsDown() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports, consent: .granted)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })
            await client.setConsent(.denied)
            #expect(t.closed)
            #expect(!client.hasPendingContext)
            #expect(client.connectionState == .disconnected)
            client.connect()                                     // the host reconnects for some reason
            let t2 = try #require(await transports.waitFor(2)); t2.opened()
            try? await Task.sleep(for: .milliseconds(50))
            #expect(StubURLProtocol.recordedRequests.count == 1)
        }

        @Test("S6: the development default is granted only in debug builds, and only when asked for")
        func developmentDefault() throws {
            #expect(ConsentDecision.default == .held)
            #if DEBUG
            #expect(ConsentDecision.development == .granted)
            #else
            // In release there is no development default to reach for; the only way to post is a real grant.
            #expect(ConsentDecision.default == .held)
            #endif
        }
    }

    // MARK: - Transport injection

    @Suite("Injected transport drives dispatch", .serialized)
    @MainActor
    struct LiveSyncTransportTests {
        @Test("T1: frames from the transport reach onAction in order")
        func framesDispatchInOrder() async throws {
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.advertiseForTesting("filter_transactions", "open_account")
            let seen = Capture<[String]>([])
            client.onAction = { seen.value.append($0.action) }
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            t.frame(#"{"classification":"custom","action":"open_account"}"#)
            t.frame(#"{"classification":"custom","action":"filter_transactions","payload":{"amount":240}}"#)
            #expect(await eventually { seen.value == ["open_account", "filter_transactions"] })
        }

        @Test("T2: a malformed frame between two good ones is reported and does not stop the stream")
        func malformedFrameMidStream() async throws {
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.advertiseForTesting("a", "b")
            let seen = Capture<[String]>([]); let errors = Capture(0)
            client.onAction = { seen.value.append($0.action) }
            client.onError = { _ in errors.value += 1 }
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            t.frame(#"{"classification":"custom","action":"a"}"#)
            t.frame("}{")
            t.frame(#"{"classification":"custom","action":"b"}"#)
            #expect(await eventually { seen.value == ["a", "b"] })
            #expect(errors.value == 1)
        }

        @Test("T3: a transport failure is reported and a reconnect follows after the backoff")
        func failureReconnects() async throws {
            let transports = FakeTransportFactory()
            let clock = ManualClock()
            let client = try makeTestClient(transports: transports, clock: clock)
            let errors = Capture<[LiveSyncError]>([])
            client.onError = { errors.value.append($0) }
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            t.end(error: .socketFailure(description: "code 1006"))
            #expect(await transports.waitFor(2) != nil)
            #expect(errors.value.contains(.socketFailure(description: "code 1006")))
            #expect(clock.slept.count == 1)
            #expect(client.connectionState == .reconnecting(attempt: 1) || client.connectionState == .connecting)
        }

        @Test("T4: disconnect() closes the transport, settles on .disconnected, and does not reconnect")
        func disconnectStops() async throws {
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { client.connectionState == .connected })
            client.disconnect()
            #expect(t.closed)
            #expect(client.connectionState == .disconnected)
            try? await Task.sleep(for: .milliseconds(100))
            #expect(transports.count == 1)
        }

        @Test("T5: deallocating the client closes the socket (the leak mitigation path)")
        func deinitCloses() async throws {
            let transports = FakeTransportFactory()
            var client: LiveSyncClient? = try makeTestClient(transports: transports)
            client?.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            client = nil
            #expect(await eventually { t.closed })
        }

        @Test("T7 (M1): a disconnect that lands while credentials are being fetched does not leave a socket open")
        func disconnectDuringVendOpensNothing() async throws {
            let credentials = FakeCredentialSource()
            await credentials.delayNextVend(.milliseconds(200))
            let transports = FakeTransportFactory()
            let client = try makeTestClient(credentials: credentials, transports: transports)
            client.connect()
            try? await Task.sleep(for: .milliseconds(50))     // inside the vend
            client.disconnect()
            try? await Task.sleep(for: .milliseconds(400))    // the vend returns after the cancel
            #expect(transports.count == 0, "a socket was opened by a cancelled loop")
            #expect(client.connectionState == .disconnected)
        }

        @Test("T8 (M2): a 403 on the context POST invalidates and backs off in place — no restart, attempts keep growing")
        func authFailureBacksOffInPlace() async throws {
            StubURLProtocol.reset(statusCode: 403, body: Data(#"{"message":"Forbidden"}"#.utf8))
            let credentials = FakeCredentialSource()
            let transports = FakeTransportFactory()
            let clock = ManualClock()
            let client = try makeTestClient(credentials: credentials, transports: transports, clock: clock)
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            for n in 1...3 {
                let t = try #require(await transports.waitFor(n)); t.opened()   // replay → 403 → loop closes socket
                #expect(await eventually { await credentials.invalidations == n })
            }
            #expect(clock.slept.count >= 3)
            #expect(clock.slept[2] > clock.slept[0], "backoff did not grow across auth failures")
        }

        @Test("T9 (M3): a refused handshake (HTTP 403) invalidates the cached key before the retry")
        func handshakeRefusedInvalidates() async throws {
            let credentials = FakeCredentialSource()
            let transports = FakeTransportFactory()
            let client = try makeTestClient(credentials: credentials, transports: transports)
            client.connect()
            let t = try #require(await transports.waitFor(1))
            t.end(error: .httpFailure(statusCode: 403, responseBody: nil))
            #expect(await eventually { await credentials.invalidations == 1 })
            #expect(await transports.waitFor(2) != nil)
        }

        @Test("T10 (m8): frames queued before disconnect() do not reach the host after it")
        func noFramesAfterDisconnect() async throws {
            let transports = FakeTransportFactory()
            let client = try makeTestClient(transports: transports)
            client.advertiseForTesting("a", "b")
            let seen = Capture(0)
            client.onAction = { _ in seen.value += 1 }
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { client.connectionState == .connected })
            t.frame(#"{"classification":"custom","action":"a"}"#)
            #expect(await eventually { seen.value == 1 })               // a lands before the disconnect
            client.disconnect()
            t.frame(#"{"classification":"custom","action":"b"}"#)   // buffered before the stream notices
            try? await Task.sleep(for: .milliseconds(100))
            #expect(seen.value == 1, "a frame reached the host after disconnect()")
        }

        @Test("T6: a URLError's description never carries the socket URL (the API key lives in it) — only its type and code")
        func errorDescriptionsCarryNoURL() {
            let url = URL(string: "wss://example.invalid/?apiKey=SECRET")
            let e = URLError(.cannotConnectToHost, userInfo: [NSURLErrorFailingURLErrorKey: url as Any, NSURLErrorFailingURLStringErrorKey: url?.absoluteString as Any])
            let described = LiveSyncError.describe(e)
            #expect(!described.contains("SECRET"))
            #expect(!described.contains("example.invalid"))
            #expect(described.contains("-1004"))
        }
    }

}
