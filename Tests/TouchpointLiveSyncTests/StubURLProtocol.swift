import Foundation

/// Captures outbound requests and replays a canned response, so context requests can be asserted on
/// without touching the network.
final class StubURLProtocol: URLProtocol {
    struct Stub: Sendable {
        var statusCode: Int = 200
        var body: Data = Data()
        /// Answer with a bare `URLResponse` rather than an `HTTPURLResponse` (defect 2 regression).
        var nonHTTP: Bool = false
    }

    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var stub = Stub()
        private var requests: [URLRequest] = []

        var recordedRequests: [URLRequest] { lock.withLock { requests } }

        func reset(stub: Stub) {
            lock.withLock {
                self.stub = stub
                requests = []
            }
        }

        func record(_ request: URLRequest) -> Stub {
            lock.withLock {
                requests.append(request)
                return stub
            }
        }
    }

    private static let state = State()

    static func reset(statusCode: Int = 200, body: Data = Data(), nonHTTP: Bool = false) {
        state.reset(stub: Stub(statusCode: statusCode, body: body, nonHTTP: nonHTTP))
    }

    static var recordedRequests: [URLRequest] { state.recordedRequests }

    /// The session configuration that routes through this stub.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // `URLProtocol` strips the body from the request it hands us, so read it back from the stream.
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            captured.httpBody = Data(reading: stream)
        }
        let stub = Self.state.record(captured)

        let response: URLResponse = stub.nonHTTP
            ? URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: stub.body.count, textEncodingName: nil)
            : HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension Data {
    fileprivate init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            append(contentsOf: buffer[0..<read])
        }
    }
}
