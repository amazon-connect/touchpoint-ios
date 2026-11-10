import Foundation
import Testing
import TouchpointCore

@testable import TouchpointLiveSync

// Inherited from the proof of concept. Mechanical edits only on absorption:
// the import, credentials now come from a source rather than the configuration, `languageCode`
// became a `LiveSyncChannel`, and the Origin assertion inverted (defect 4). Consent is granted here
// so the inherited behaviour is unchanged; the gate has its own suite.
private func makeConfiguration(
    languageCode: String = "en-US",
    stage: String? = nil
) -> LiveSyncConfiguration {
    // `try!` is forbidden in Sources, not in Tests; still, keep it honest with a precondition-free path.
    let channel = (try? LiveSyncChannel(locale: Locale(identifier: languageCode))) ?? (try? LiveSyncChannel(locale: Locale(identifier: "en_US")))
    return LiveSyncConfiguration(
        region: "us-west-2",
        conversationId: "4411ca47-96d8-4bc8-88d8-1b7a6a1dcd98",
        channel: channel ?? LiveSyncChannel.fallbackForTests,
        stage: stage
    )
}

@MainActor
private func makeClient(
    configuration: LiveSyncConfiguration = makeConfiguration(),
    session: URLSession = StubURLProtocol.makeSession()
) -> LiveSyncClient {
    LiveSyncClient(configuration: configuration, credentials: FakeCredentialSource(), consent: .granted,
                   reconnection: .default, autoConnect: false, urlSession: session,
                   transports: FakeTransportFactory(), clock: ManualClock())
}

private let contactInfoAction = JSONValue.object([
    "type": "object",
    "properties": ["fullName": ["type": "string"], "email": ["type": "string"]],
])

extension LiveSyncStubBackedSuites {
    @Suite("Endpoints", .serialized)
    struct EndpointTests {
        @Test("Socket URL matches the documented handshake")
        @MainActor
        func socketRequest() async throws {
            let request = try await makeClient().makeSocketRequest()
            let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
            )

            #expect(components.scheme == "wss")
            // Derived, not spelled out: the rule under test is "ws." + the API host; production has no stage suffix.
            #expect(components.host == "ws." + makeConfiguration().apiHost)
            #expect(makeConfiguration().apiHost.hasSuffix(".us-west-2.amazonaws.com"))
            #expect(makeConfiguration().stageSuffix.isEmpty)                 // production: no stage in the host
            #expect(components.path == "/")
            #expect(query["deploymentKey"] == "deployment-key")
            #expect(query["channelKey"] == "connect-en-US")
            #expect(query["apiKey"] == "test-api-key-placeholder")
            #expect(query["conversationId"] == "4411ca47-96d8-4bc8-88d8-1b7a6a1dcd98")
            #expect(query["type"] == "voice-plus")
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)   // defect 4: no hardcoded Origin
        }

        @Test("A stage suffixes both hosts, and the language code drives the channel")
        @MainActor
        func stageAndLanguage() async throws {
            let client = makeClient(configuration: makeConfiguration(languageCode: "de-DE", stage: "example"))

            let staged = makeConfiguration(languageCode: "de-DE", stage: "example")
            #expect(try await client.makeSocketRequest().url?.host == staged.socketHost)
            #expect(staged.socketHost.contains("-example.us-west-2."))      // the stage lands between service and region
            #expect(staged.socketHost == "ws." + staged.apiHost)
            let contextURL = try await client.makeContextRequest().url!
            #expect(contextURL.host == staged.apiHost)
            #expect(contextURL.path == "/nlu/c/deployment-key/connect-de-DE/context")
        }

        @Test("An empty required value is rejected before any connection is attempted")
        @MainActor
        func missingConfiguration() async throws {
            var configuration = makeConfiguration()
            configuration.conversationId = ""
            await #expect(throws: LiveSyncError.invalidConfiguration("`conversationId` must not be empty")) {
                _ = try await makeClient(configuration: configuration).makeSocketRequest()
            }
        }
    }

    @Suite("sendContext", .serialized)
    struct SendContextTests {
        @Test("Posts the vpContext envelope with the API key header")
        @MainActor
        func postsEnvelope() async throws {
            StubURLProtocol.reset()
            let client = makeClient()

            try await client.sendContext(
                scopes: ["booking"],
                actions: [
                    LiveSyncAction(
                        "set_contact_info",
                        description: "Set the customer's name and email",
                        schema: contactInfoAction
                    ),
                    LiveSyncAction("search_flights", description: "Run the flight search"),
                ]
            )
            try await client.postContext()

            let request = try #require(StubURLProtocol.recordedRequests.last)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.host == makeConfiguration().apiHost)
            #expect(request.url?.path == "/nlu/c/deployment-key/connect-en-US/context")
            #expect(request.value(forHTTPHeaderField: "nlx-api-key") == "test-api-key-placeholder")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")

            let body = try JSONDecoder().decode(
                JSONValue.self,
                from: try #require(request.httpBody)
            )
            #expect(body["conversationId"]?.stringValue == "4411ca47-96d8-4bc8-88d8-1b7a6a1dcd98")

            let vpContext = try #require(body["context"]?["nlx:vpContext"])
            #expect(vpContext["scopes"] == .array([.string("booking")]))
            #expect(
                vpContext["actions"]
                    == .array([
                        .object([
                            "action": "set_contact_info",
                            "description": "Set the customer's name and email",
                            "schema": contactInfoAction,
                        ]),
                        .object([
                            "action": "search_flights",
                            "description": "Run the flight search",
                        ]),
                    ])
            )
        }

        @Test("Each call replaces the previous context rather than merging into it")
        @MainActor
        func replaces() async throws {
            StubURLProtocol.reset()
            let client = makeClient()

            try await client.sendContext(
                scopes: ["booking"],
                actions: [LiveSyncAction("search_flights", description: "Run the search")]
            )
            try await client.sendContext(scopes: ["checkout"])

            let body = try JSONDecoder().decode(JSONValue.self, from: client.contextRequestBody())
            let vpContext = try #require(body["context"]?["nlx:vpContext"])
            #expect(vpContext["scopes"] == .array([.string("checkout")]))
            #expect(vpContext["actions"] == .array([]))
        }

        @Test("Omitted scopes are left out of the request")
        @MainActor
        func scopesAreOptional() async throws {
            StubURLProtocol.reset()
            let client = makeClient()

            try await client.sendContext(
                actions: [LiveSyncAction("search_flights", description: "Run the search")]
            )

            let body = try JSONDecoder().decode(JSONValue.self, from: client.contextRequestBody())
            let vpContext = try #require(body["context"]?["nlx:vpContext"])
            #expect(vpContext["scopes"] == nil)
            #expect(vpContext["actions"]?[0]?["action"]?.stringValue == "search_flights")
        }

        @Test("Context sent before the socket opens is held rather than posted")
        @MainActor
        func deferredUntilConnected() async throws {
            StubURLProtocol.reset()
            let client = makeClient()

            try await client.sendContext(scopes: ["booking"])

            #expect(StubURLProtocol.recordedRequests.isEmpty)
            #expect(client.connectionState == .idle)
        }

        @Test("A rejected request throws with the status and body")
        @MainActor
        func rejectedRequest() async throws {
            StubURLProtocol.reset(statusCode: 403, body: Data(#"{"message":"Forbidden"}"#.utf8))
            let client = makeClient()
            try await client.sendContext(scopes: ["booking"])

            await #expect(
                throws: LiveSyncError.httpFailure(
                    statusCode: 403,
                    responseBody: #"{"message":"Forbidden"}"#
                )
            ) {
                try await client.postContext()
            }
        }
    }


    @Suite("Action dispatch", .serialized)
    struct DispatchTests {
        private struct ContactInfo: Decodable, Equatable {
            let fullName: String
            let email: String
        }

        @Test("Every invocation reaches onAction with its name and payload")
        @MainActor
        func onActionReceivesNameAndPayload() {
            let client = makeClient()
            client.advertiseForTesting("search_flights", "set_contact_info")
            let received = Box<[LiveSyncActionInvocation]>([])
            client.onAction = { received.value.append($0) }

            client.ingest(
                """
                {"conversationId":"ea03d952","classification":"custom","action":"set_contact_info",\
                "payload":{"fullName":"sterly","email":"sterly@example.com"}}
                """
            )
            client.ingest(#"{"classification":"custom","action":"search_flights"}"#)

            #expect(received.value.map(\.action) == ["set_contact_info", "search_flights"])
            #expect(received.value.first?.payload["email"]?.stringValue == "sterly@example.com")
            #expect(received.value.last?.payload == .object([:]))
        }

        @Test("A payload decodes into a model inside the handler")
        @MainActor
        func decodesPayload() throws {
            let client = makeClient()
            client.advertiseForTesting("set_contact_info")
            let received = Box<ContactInfo?>(nil)
            client.onAction = { invocation in
                switch invocation.action {
                case "set_contact_info": received.value = try invocation.decode(ContactInfo.self)
                default: break
                }
            }

            client.ingest(
                """
                {"classification":"custom","action":"set_contact_info",\
                "payload":{"fullName":"chirag","email":"chirag@example.com"}}
                """
            )

            #expect(received.value == ContactInfo(fullName: "chirag", email: "chirag@example.com"))
        }

        @Test("An error thrown by the handler is reported, not crashed")
        @MainActor
        func handlerThrows() {
            let client = makeClient()
            client.advertiseForTesting("set_contact_info")
            let errors = Box<[LiveSyncError]>([])
            client.onError = { errors.value.append($0) }
            client.onAction = { _ = try $0.decode(ContactInfo.self) }

            client.ingest(#"{"classification":"custom","action":"set_contact_info","payload":{}}"#)

            #expect(errors.value.count == 1)
            guard case .actionHandlerFailed(let action, _) = errors.value.first else {
                Issue.record("Expected an actionHandlerFailed error, got \(errors.value)")
                return
            }
            #expect(action == "set_contact_info")
        }

        @Test("An action the app never advertised is rejected on the device and never reaches the handler")
        @MainActor
        func unadvertisedActionRejected() {
            let client = makeClient()
            client.advertiseForTesting("search_flights")
            let seen = Box<[String]>([])
            let errors = Box<[LiveSyncError]>([])
            client.onAction = { seen.value.append($0.action) }
            client.onError = { errors.value.append($0) }

            client.ingest(#"{"classification":"custom","action":"set_extras","payload":{"extras":[]}}"#)

            #expect(seen.value.isEmpty)
            #expect(errors.value == [.invalidPayload(action: "set_extras", description: "not in the advertised context")])
            #expect(client.diagnostics.rejectedInvocations == 1)
        }

        @Test("The handler outlives the contexts it was registered before")
        @MainActor
        func handlerSurvivesContextChanges() async throws {
            StubURLProtocol.reset()
            let client = makeClient()
            let calls = Box(0)
            client.onAction = { _ in calls.value += 1 }

            try await client.sendContext(actions: [
                LiveSyncAction("step_one", description: "First step")
            ])
            try await client.sendContext(actions: [
                LiveSyncAction("step_one", description: "First step"),
                LiveSyncAction("step_two", description: "Second step"),
            ])

            client.ingest(#"{"classification":"custom","action":"step_one"}"#)
            client.ingest(#"{"classification":"custom","action":"step_two"}"#)

            #expect(calls.value == 2)
        }

        @Test("Invocations are also published on the observation stream")
        @MainActor
        func invocationStream() async throws {
            let client = makeClient()
            client.advertiseForTesting("search_flights")
            var iterator = client.invocations().makeAsyncIterator()

            client.ingest(#"{"classification":"custom","action":"search_flights"}"#)

            let invocation = await iterator.next()
            #expect(
                invocation == LiveSyncActionInvocation(action: "search_flights", payload: .object([:]))
            )
        }

        @Test("A malformed frame is reported and does not stop later invocations")
        @MainActor
        func malformedFrame() {
            let client = makeClient()
            client.advertiseForTesting("search_flights")
            let errors = Box(0)
            let ran = Box(false)
            client.onError = { _ in errors.value += 1 }
            client.onAction = { _ in ran.value = true }

            client.ingest("}{")
            client.ingest(#"{"classification":"custom","action":"search_flights"}"#)

            #expect(errors.value == 1)
            #expect(ran.value)
        }
    }

}

/// Mutable capture box for assertions made from `@MainActor` handlers.
@MainActor
private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
