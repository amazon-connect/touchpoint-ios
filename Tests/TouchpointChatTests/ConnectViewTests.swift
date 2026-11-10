import Foundation
import Testing
import TouchpointCore
@testable import TouchpointChat

// Connect Views / step-by-step Guides.

private let creds = ChatContactCredentials(contactID: "c1", participantID: "p-me", participantToken: "tok", expiresAt: nil)

private func waitUntil(_ timeout: Duration = .seconds(2), _ cond: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await cond() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await cond()
}

private func json(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: - The outbound envelope (byte-for-byte vs web's submitView)

@Suite("Connect View response envelope (A7)")
struct ConnectViewEnvelopeTests {
    @Test("Web's submitView shape exactly: templateType ViewResource, version 1.0, viewName, action, data")
    func withViewName() throws {
        let response = try InteractiveContent.viewResponse(viewName: "disputeForm", action: "Submit",
                                                           dataJSON: Data(#"{"amount":42,"name":"Sterly","trip":"BLR-JFK"}"#.utf8))
        #expect(response.templateType == "ViewResource")
        let obj = try #require(try JSONSerialization.jsonObject(with: response.rawJSON) as? [String: Any])
        #expect(Set(obj.keys) == ["templateType", "version", "viewName", "action", "data"])
        #expect(obj["templateType"] as? String == "ViewResource")
        #expect(obj["version"] as? String == "1.0")
        #expect(obj["viewName"] as? String == "disputeForm")
        #expect(obj["action"] as? String == "Submit")
        let data = try #require(obj["data"] as? [String: Any])
        #expect(data["amount"] as? Int == 42)
        #expect(data["name"] as? String == "Sterly")
        #expect(data["trip"] as? String == "BLR-JFK")
    }

    @Test("No viewName and non-object data: viewName omitted, data becomes {} (web's data ?? {})")
    func withoutViewName() throws {
        let response = try InteractiveContent.viewResponse(viewName: nil, action: "Next", dataJSON: Data("[1,2,3]".utf8))
        let obj = try #require(try JSONSerialization.jsonObject(with: response.rawJSON) as? [String: Any])
        #expect(Set(obj.keys) == ["templateType", "version", "action", "data"])
        #expect(obj["action"] as? String == "Next")
        #expect((obj["data"] as? [String: Any])?.isEmpty == true)
    }

    @Test("Past Connect's 16 KB limit the submit throws rather than going out truncated")
    func sizeLimit() {
        let big = Data(("{\"x\":\"" + String(repeating: "a", count: 17_000) + "\"}").utf8)
        #expect(throws: TouchpointError.self) {
            _ = try InteractiveContent.viewResponse(viewName: nil, action: "Submit", dataJSON: big)
        }
    }
}

// MARK: - describeView mapping (web's ResolvedView)

@Suite("Connect View definition resolution (A7)")
struct ConnectViewDefinitionTests {
    @Test("Stringified Template/InputSchema are parsed; Actions kept; metadata carried")
    func stringifiedContent() throws {
        let def = ConnectViewDefinition.resolve(
            id: "arn:view", name: "Dispute", version: 3,
            content: ["Actions": ["Submit", "Next"],
                      "Template": #"{"Head":{"Title":"T"}}"#,
                      "InputSchema": #"{"type":"object"}"#])
        #expect(def.id == "arn:view")
        #expect(def.name == "Dispute")
        #expect(def.version == 3)
        #expect(def.actions == ["Submit", "Next"])
        let template = try #require(try JSONSerialization.jsonObject(with: def.template) as? [String: Any])
        #expect((template["Head"] as? [String: Any])?["Title"] as? String == "T")
        let schema = try #require(def.inputSchema.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(schema["type"] as? String == "object")
    }

    @Test("An object-form Template is carried through; a non-JSON string is kept verbatim")
    func objectAndRawForms() throws {
        let def = ConnectViewDefinition.resolve(
            id: nil, name: nil, version: nil,
            content: ["Template": ["Head": ["Title": "X"]], "InputSchema": "not json"])
        let template = try #require(try JSONSerialization.jsonObject(with: def.template) as? [String: Any])
        #expect((template["Head"] as? [String: Any])?["Title"] as? String == "X")
        // A non-JSON string is preserved as a JSON string fragment.
        let schema = try #require(def.inputSchema)
        #expect(String(decoding: schema, as: UTF8.self) == "\"not json\"")
        #expect(def.actions.isEmpty)
    }

    @Test("No content resolves to an empty template and no schema")
    func emptyContent() throws {
        let def = ConnectViewDefinition.resolve(id: nil, name: nil, version: nil, content: nil)
        #expect(def.actions.isEmpty)
        #expect(def.inputSchema == nil)
        #expect(json(def.template).isEmpty)
    }
}

// MARK: - viewReference parsing from the transcript payload

@Suite("ViewResource reference parsing (A7)")
struct ConnectViewReferenceTests {
    private func reference(_ raw: String) -> ConnectViewReference? {
        InteractiveContent(templateType: "ViewResource", rawJSON: Data(raw.utf8)).viewReference
    }

    @Test("viewId, viewToken, viewData object, heading and subheading are read")
    func objectViewData() throws {
        let ref = try #require(reference(#"""
        {"templateType":"ViewResource","data":{"content":{"viewId":"arn:v","viewToken":"TOK",
        "viewData":{"Heading":"Dispute","SubHeading":"Tell us more"}}}}
        """#))
        #expect(ref.viewId == "arn:v")
        #expect(ref.viewToken == "TOK")
        #expect(ref.heading == "Dispute")
        #expect(ref.subheading == "Tell us more")
        #expect(json(ref.viewData ?? Data())["Heading"] as? String == "Dispute")
    }

    @Test("viewData delivered as a JSON string is parsed, as web does")
    func stringViewData() throws {
        let ref = try #require(reference(#"""
        {"templateType":"ViewResource","data":{"content":{"viewToken":"TOK",
        "viewData":"{\"Heading\":\"H\"}"}}}
        """#))
        #expect(ref.heading == "H")
        #expect(ref.viewToken == "TOK")
    }

    @Test("A non-View template has no reference")
    func notAView() {
        #expect(InteractiveContent(templateType: "QuickReply", rawJSON: Data("{}".utf8)).viewReference == nil)
    }
}

// MARK: - Transport & session wiring

@Suite("Connect View transport and session (A7)", .serialized)
@MainActor
struct ConnectViewTransportTests {
    private struct Backend: TouchpointBackend {
        func startChatContact(_ request: ChatContactRequest) async throws -> ChatContactCredentials { creds }
        func startVoiceContact(_ request: VoiceContactRequest) async throws -> VoiceContactCredentials { throw TouchpointError.invalidConfiguration("chat only") }
        func liveSyncCredentials() async throws -> LiveSyncCredentials { throw TouchpointError.invalidConfiguration("none") }
    }

    private func connected() async throws -> (TouchpointSession, FakeChatDriver) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tp-a7-\(UUID().uuidString)")
        let keychain = InMemoryKeychainStore()
        let store = try await ConversationStore(containerURL: dir, keychain: keychain)
        let driver = FakeChatDriver()
        let session = TouchpointSession(broker: CredentialBroker(backend: Backend(), keychain: keychain), store: store,
                                        transports: [.chat: ConnectChatTransport(driver: driver)])
        try await session.startChat(ChatContactRequest(displayName: "a"))
        await driver.fire { $0.onConnected() }
        #expect(await waitUntil { await MainActor.run { session.state == .connected } })
        return (session, driver)
    }

    @Test("Transport.describeView forwards to the driver and maps a failure to TouchpointError")
    func transportDescribe() async throws {
        let driver = FakeChatDriver()
        let transport = ConnectChatTransport(driver: driver)
        try await transport.connect(credentials: creds)
        let def = try await transport.describeView(viewToken: "TOK")
        #expect(await driver.describeRequests == ["TOK"])
        #expect(def.name == "Form")

        await driver.setFailNextDescribe(NSError(domain: "x", code: 7))
        await #expect(throws: TouchpointError.self) { _ = try await transport.describeView(viewToken: "T2") }
    }

    @Test("sendViewResponse goes out as an interactive.response carrying web's envelope, with no customer bubble")
    func sendViewResponse() async throws {
        let (session, driver) = try await connected()
        _ = try await session.sendViewResponse(viewName: "f", action: "Submit", data: Data(#"{"ok":true}"#.utf8))
        #expect(await waitUntil(.seconds(10)) { await driver.sentContentTypes == [ConnectContentType.interactiveResponse] })
        let body = try #require(await driver.sentBodies.first)
        let obj = json(Data(body.utf8))
        #expect(obj["templateType"] as? String == "ViewResource")
        #expect(obj["action"] as? String == "Submit")
        #expect(obj["viewName"] as? String == "f")
        #expect((obj["data"] as? [String: Any])?["ok"] as? Bool == true)
        // No customer bubble: the stored row has an empty body and does not render.
        let last = try #require(try await session.transcript().last)
        #expect(last.body.isEmpty)
        #expect(last.interactive?.templateType == "ViewResource")
        #expect(TranscriptLayout.isRenderable(last) == false)
        await session.end()
    }

    @Test("session.describeView returns the definition; with no active contact it throws")
    func sessionDescribe() async throws {
        let (session, driver) = try await connected()
        await driver.setNextViewDefinition(ConnectViewDefinition(id: "v", name: "Dispute", version: 1,
                                                                 template: Data("{}".utf8), inputSchema: nil, actions: ["Submit"]))
        let def = try await session.describeView(viewToken: "T")
        #expect(def.name == "Dispute")
        #expect(await driver.describeRequests.contains("T"))
        await session.end()
        await #expect(throws: TouchpointError.self) { _ = try await session.describeView(viewToken: "T") }
    }

    @Test("A View response read back from history has no bubble (empty body), matching the live send")
    func readbackHidden() {
        let envelope = #"{"templateType":"ViewResource","version":"1.0","action":"Submit","data":{}}"#
        let (body, content) = ConnectChatTransport.content(contentType: ConnectContentType.interactiveResponse, text: envelope)
        #expect(body.isEmpty)
        #expect(content?.templateType == "ViewResource")
    }
}

// MARK: - Renderer security (pure, platform-neutral)

@Suite("Connect View renderer security (A7)")
struct ConnectViewRenderingTests {
    @Test("Only https Amazon Connect instance hosts are accepted")
    func originValidation() {
        #expect(ConnectViewOrigin.validated(URL(string: "https://acme.my.connect.aws")!) == "https://acme.my.connect.aws")
        #expect(ConnectViewOrigin.validated(URL(string: "https://acme.awsapps.com")!) == "https://acme.awsapps.com")
        // Path/query are dropped; only the origin is kept.
        #expect(ConnectViewOrigin.validated(URL(string: "https://acme.my.connect.aws/connect/home?x=1")!) == "https://acme.my.connect.aws")
        // Rejected: not https, the bare apex, a look-alike suffix, an unrelated host.
        #expect(ConnectViewOrigin.validated(URL(string: "http://acme.my.connect.aws")!) == nil)
        #expect(ConnectViewOrigin.validated(URL(string: "https://my.connect.aws")!) == nil)
        #expect(ConnectViewOrigin.validated(URL(string: "https://acme.my.connect.aws.evil.com")!) == nil)
        #expect(ConnectViewOrigin.validated(URL(string: "https://evil.com")!) == nil)
    }

    @Test("ConnectViewRendering validates up front and exposes the locked origin")
    func renderingConfig() throws {
        let rendering = try ConnectViewRendering(instanceURL: "https://acme.my.connect.aws")
        #expect(rendering.origin == "https://acme.my.connect.aws")
        #expect(throws: TouchpointError.self) { _ = try ConnectViewRendering(instanceURL: "https://evil.com") }
        #expect(throws: TouchpointError.self) { _ = try ConnectViewRendering(instanceURL: "http://acme.my.connect.aws") }
    }

    @Test("Navigation is allowed only to the instance origin and about:blank; everything else is cancelled")
    func navigationPolicy() {
        let origin = "https://acme.my.connect.aws"
        #expect(GuideNavigation.decide(url: URL(string: "https://acme.my.connect.aws/widget/x")!, allowedOrigin: origin) == .allow)
        #expect(GuideNavigation.decide(url: URL(string: "about:blank")!, allowedOrigin: origin) == .allow)
        #expect(GuideNavigation.decide(url: URL(string: "https://evil.com")!, allowedOrigin: origin) == .cancel)
        #expect(GuideNavigation.decide(url: URL(string: "http://acme.my.connect.aws")!, allowedOrigin: origin) == .cancel)
        #expect(GuideNavigation.decide(url: URL(string: "javascript:alert(1)")!, allowedOrigin: origin) == .cancel)
        #expect(GuideNavigation.decide(url: nil, allowedOrigin: origin) == .cancel)
    }

    @Test("Another tenant's Connect instance is refused: the lock is the configured origin, not the allowed suffix")
    func otherTenantRefused() throws {
        let origin = "https://acme.my.connect.aws"
        // Hosts that pass the suffix allowlist, so `ConnectViewRendering` would accept them as
        // configuration, but are not this instance.
        for other in ["https://other.my.connect.aws", "https://other.my.connect.aws/connectwidget/static/views/renderer/latest/index.js",
                      "https://other.awsapps.com", "https://acme.my.connect.aws.other.awsapps.com",
                      "https://acme.my.connect.aws:8443", "https://sub.acme.my.connect.aws"] {
            #expect(GuideNavigation.decide(url: URL(string: other)!, allowedOrigin: origin) == .cancel, "\(other) was allowed")
        }
        #expect(try ConnectViewRendering(instanceURL: "https://other.my.connect.aws").origin != origin)
        // The page's policy names only the configured instance: no fetch, script or frame can reach
        // a sibling tenant either.
        let html = GuideRenderer.htmlShell(origin: origin, scriptURL: try #require(GuideRenderer.scriptURL(origin: origin)),
                                           payloadJSON: Data("{}".utf8), nonce: "n")
        #expect(!html.contains("other.my.connect.aws"))
        #expect(!html.contains("awsapps.com"))
        #expect(!html.contains("*."))
    }

    @Test("The JS→native bridge accepts only the action shape, size-capped")
    func bridgeValidation() throws {
        let submit = try #require(GuideBridge.parse(["Action": "Submit", "Output": ["x": 1]]))
        #expect(submit.action == "Submit")
        #expect(json(submit.data)["x"] as? Int == 1)
        // Web's `Output ?? Data ?? {}` fallback.
        let viaData = try #require(GuideBridge.parse(["Action": "Next", "Data": ["y": 2]]))
        #expect(json(viaData.data)["y"] as? Int == 2)
        let noData = try #require(GuideBridge.parse(["Action": "Go"]))
        #expect(json(noData.data).isEmpty)
        // A JSON-string body is accepted too.
        #expect(GuideBridge.parse(#"{"Action":"S","Output":{}}"#)?.action == "S")
        // Rejected: a status frame (no Action), a non-object, and anything oversized.
        #expect(GuideBridge.parse(["Type": "ready"]) == nil)
        #expect(GuideBridge.parse(42) == nil)
        #expect(GuideBridge.parse(["Action": "S", "Output": ["blob": String(repeating: "a", count: 70_000)]]) == nil)
    }

    @Test("The renderer payload carries Content/InputData and never the viewToken")
    func payload() throws {
        let def = ConnectViewDefinition(id: "v", name: "F", version: 1,
                                        template: Data(#"{"Head":{"Title":"T"}}"#.utf8),
                                        inputSchema: Data(#"{"type":"object"}"#.utf8),
                                        actions: ["Submit", "Next"])
        let payload = GuideRenderer.payloadJSON(definition: def, inputData: Data(#"{"Heading":"Dispute"}"#.utf8))
        let obj = json(payload)
        let content = try #require(obj["Content"] as? [String: Any])
        #expect(content["Actions"] as? [String] == ["Submit", "Next"])
        #expect(((content["Template"] as? [String: Any])?["Head"] as? [String: Any])?["Title"] as? String == "T")
        #expect((content["InputSchema"] as? [String: Any])?["type"] as? String == "object")
        #expect((obj["InputData"] as? [String: Any])?["Heading"] as? String == "Dispute")
        #expect(!String(decoding: payload, as: UTF8.self).contains("viewToken"))
    }

    @Test("The HTML shell loads the instance script, mounts the element, scopes a CSP, and cannot be broken out of")
    func htmlShell() throws {
        let origin = "https://acme.my.connect.aws"
        let scriptURL = try #require(GuideRenderer.scriptURL(origin: origin))
        #expect(scriptURL.absoluteString == "https://acme.my.connect.aws/connectwidget/static/views/renderer/latest/index.js")
        let html = GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL,
                                           payloadJSON: Data(#"{"Content":{},"InputData":{}}"#.utf8))
        #expect(html.contains(scriptURL.absoluteString))
        #expect(html.contains("connect-view-renderer"))
        #expect(html.contains(GuideRenderer.messageHandlerName))
        #expect(html.contains("Content-Security-Policy"))
        // Scripts: the instance and this page's nonced boot script only — never inline or eval.
        let csp = try #require(html.split(separator: "\n").first { $0.contains("Content-Security-Policy") })
        #expect(!csp.contains("script-src 'self' https://acme.my.connect.aws 'unsafe"), "script-src must not allow unsafe-inline/eval")
        #expect(!csp.contains("unsafe-eval"))
        let fixed = GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL, payloadJSON: Data("{}".utf8), nonce: "abc123")
        #expect(fixed.contains("script-src 'self' \(origin) 'nonce-abc123'"))
        #expect(fixed.contains("<script nonce=\"abc123\">"))
        #expect(GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL, payloadJSON: Data("{}".utf8))
                != GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL, payloadJSON: Data("{}".utf8)),
                "a fresh nonce per page")
        #expect(html.contains("connect-src 'self' \(origin)"))

        // A payload that tries to close the script block is escaped and cannot break out.
        #expect(GuideRenderer.escapeForScriptBlock("</script>") == "\\u003c/script\\u003e")
        let hostile = GuideRenderer.htmlShell(origin: origin, scriptURL: scriptURL,
                                              payloadJSON: Data(#"{"x":"</script><img src=x>"}"#.utf8))
        #expect(!hostile.contains("</script><img"))
    }
}
