import Foundation
import Testing
import TouchpointCore
@testable import TouchpointLiveSync

extension LiveSyncStubBackedSuites {
    @Suite("Context-POST refusal backoff", .serialized)
    @MainActor
    struct LiveSyncAuthBackoffTests {
        @Test("Consecutive context-POST refusals floor the backoff, even when a frame resets the attempt count")
        func refusalsFloorBackoff() async throws {
            StubURLProtocol.reset(statusCode: 403, body: Data(#"{"message":"Forbidden"}"#.utf8))
            let transports = FakeTransportFactory()
            let clock = ManualClock()
            // Deterministic, jitter-free exponential backoff so the delays can be compared directly.
            let policy = ReconnectionPolicy(maxAttempts: 10, totalBudget: .seconds(600),
                                            initialDelay: .milliseconds(100), maxDelay: .seconds(100), jitterFactor: 0)
            let client = try makeTestClient(transports: transports, reconnection: policy, clock: clock)
            try await client.sendContext(scopes: ["accounts"])   // held until the socket opens
            client.advertiseForTesting("noop")
            client.connect()
            // Each cycle: the socket opens and delivers a frame — which resets `attempt` — then the
            // context POST is refused (403) and closes the socket, handing the loop to its backoff.
            for n in 1...4 {
                guard let t = await transports.waitFor(n) else { break }
                t.opened()
                t.frame(#"{"classification":"custom","action":"noop"}"#)
            }
            #expect(await eventually { clock.slept.count >= 3 })
            let delays = clock.slept
            // Without the refusal floor, the frame resets `attempt` every cycle and the delay stays
            // at the first-retry value (100 ms); the floor makes it grow with each refusal.
            #expect(delays[2] > delays[0], "backoff must grow across consecutive context refusals: \(delays)")
            client.disconnect()
        }
    }
}
