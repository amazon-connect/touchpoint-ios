import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

// MARK: - Contact-ID resolution and the stale-contact diagnostic

@Suite("Deep-link contact ID resolver")
struct DeepLinkResolverTests {
    private let id = "4411ca47-96d8-4bc8-88d8-1b7a6a1dcd98"
    private func parse(_ s: String, prefix: String? = "/livesync") -> String? {
        DeepLinkContactIDResolver.contactID(from: URL(string: s)!, scheme: "acmebank", host: "support", pathPrefix: prefix)
    }

    @Test("P1: the ID as the last path component")
    func pathForm() {
        #expect(parse("acmebank://support/livesync/\(id)") == id)
    }

    @Test("P2: the ID as a query item, any accepted spelling, beating a positional component")
    func queryForm() {
        #expect(parse("acmebank://support/livesync?contactId=\(id)") == id)
        #expect(parse("acmebank://support/livesync?contact_id=\(id)") == id)
        #expect(parse("acmebank://support/livesync?contactID=\(id)") == id)
        #expect(parse("acmebank://support/livesync/00000000-0000-0000-0000-000000000000?contactId=\(id)") == id)
    }

    @Test("P3: the ID is normalised to lowercase")
    func normalised() {
        #expect(parse("acmebank://support/livesync/\(id.uppercased())") == id)
    }

    @Test("H1: hostile and malformed URLs resolve to nil — wrong scheme, wrong host, credentials, port, bad ID, traversal, injection")
    func hostile() {
        #expect(parse("https://support/livesync/\(id)") == nil)
        #expect(parse("acmebank://evil/livesync/\(id)") == nil)
        #expect(parse("acmebank://support@evil/livesync/\(id)") == nil)
        #expect(parse("acmebank://support:8080/livesync/\(id)") == nil)
        #expect(parse("acmebank://support/livesync/not-a-uuid") == nil)
        #expect(parse("acmebank://support/livesync/\(id)&apiKey=x") == nil)
        #expect(parse("acmebank://support/livesync/%2e%2e/\(id)") == nil, "relative segments are refused")
        #expect(parse("acmebank://support/livesync/../livesync/\(id)") == nil)
        #expect(parse("acmebank://support/other/\(id)") == nil, "path prefix is enforced")
        #expect(parse("acmebank://support/livesyncx/\(id)") == nil, "prefix must be a whole segment")
        #expect(parse("acmebank://support/livesync") == nil)
        #expect(parse("acmebank://support") == nil)
        #expect(parse("acmebank://support/livesync?contactId=") == nil)
        #expect(parse("acmebank://support/livesync?contactId=\(id)%0aapiKey") == nil)
    }

    @Test("H2: with no path prefix any path is accepted, but the ID rule still holds")
    func noPrefix() {
        #expect(parse("acmebank://support/anything/\(id)", prefix: nil) == id)
        #expect(parse("acmebank://support/anything/x", prefix: nil) == nil)
    }

    @Test("S1: resolver substitution — the protocol is the seam; a static resolver and the deep-link one are interchangeable")
    func substitution() async throws {
        let resolvers: [any TouchpointContactIDResolver] = [
            StaticContactIDResolver(id),
            DeepLinkContactIDResolver(url: URL(string: "acmebank://support/livesync/\(id)"), scheme: "acmebank", host: "support"),
        ]
        for r in resolvers { #expect(try await r.resolveContactID() == id) }
        #expect(try await StaticContactIDResolver(nil).resolveContactID() == nil)
        #expect(try await DeepLinkContactIDResolver(url: nil, scheme: "acmebank", host: "support").resolveContactID() == nil)
    }
}

extension LiveSyncStubBackedSuites {
    @Suite("Stale-contact diagnostic", .serialized)
    @MainActor
    struct StaleContactTests {
        @Test("Q1: connected, context posted, silence past the threshold → contactMayBeStale reported once")
        func staleFires() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory(); let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, staleContactThreshold: .seconds(45))
            let errors = Capture<[LiveSyncError]>([]); client.onError = { errors.value.append($0) }
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 1 })
            #expect(await eventually { idle.pending == 1 })
            #expect(idle.requested == [.seconds(45)])
            idle.fire()
            #expect(await eventually { client.contactMayBeStale })
            #expect(errors.value == [.contactMayBeStale(quietFor: .seconds(45))])
            #expect(client.diagnostics.staleContactWarnings == 1)
            #expect(client.connectionState == .connected, "the socket is healthy; the diagnosis is about the contact")
        }

        @Test("Q2: a frame before the threshold disarms it, and a frame after clears the flag")
        func frameDisarms() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory(); let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, staleContactThreshold: .seconds(45))
            let errors = Capture<[LiveSyncError]>([]); client.onError = { errors.value.append($0) }
            try await client.sendContext(scopes: ["accounts"])
            client.advertiseForTesting("open_account")
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            #expect(await eventually { idle.pending == 1 })
            t.frame(#"{"classification":"custom","action":"open_account"}"#)
            #expect(await eventually { idle.pending == 0 })
            idle.fire()
            try? await Task.sleep(for: .milliseconds(30))
            #expect(errors.value.isEmpty)
            #expect(!client.contactMayBeStale)
        }

        @Test("Q3: no context posted (consent held) → the diagnostic does not arm; silence is expected then")
        func notArmedWithoutContext() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory(); let idle = HeldClock()
            let client = try makeTestClient(transports: transports, consent: .held, idleClock: idle, staleContactThreshold: .seconds(45))
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t = try #require(await transports.waitFor(1)); t.opened()
            _ = await eventually { client.connectionState == .connected }
            try? await Task.sleep(for: .milliseconds(30))
            #expect(idle.requested.isEmpty)
        }

        @Test("Q4: disconnect disarms; a reconnect re-arms after the replay")
        func reconnectRearms() async throws {
            StubURLProtocol.reset()
            let transports = FakeTransportFactory(); let idle = HeldClock()
            let client = try makeTestClient(transports: transports, idleClock: idle, staleContactThreshold: .seconds(45))
            try await client.sendContext(scopes: ["accounts"])
            client.connect()
            let t1 = try #require(await transports.waitFor(1)); t1.opened()
            #expect(await eventually { idle.pending == 1 })
            client.disconnect()
            #expect(await eventually { idle.pending == 0 })
            client.connect()
            let t2 = try #require(await transports.waitFor(2)); t2.opened()
            #expect(await eventually { idle.pending == 1 })
            #expect(await eventually { StubURLProtocol.recordedRequests.count == 2 })
        }
    }
}
