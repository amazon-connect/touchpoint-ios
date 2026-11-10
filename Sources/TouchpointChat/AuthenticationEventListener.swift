import Foundation

/// A listen-only second participant websocket that hears Connect's sign-in events.
///
/// **Why it exists:** `amazon-connect-chat-ios` (2.0.13 and 3.0.0) names the six authentication content types
/// but drops them — live and in its transcript parsing (`WebsocketManager
/// .processJsonContentAndGetItem`, `default:` returns nil) — and exposes no raw-frame hook. Rejected
/// instead: polling `GetTranscript` (latency against Connect's 60 s window, constant calls); the
/// vendor's debug logger, which carries raw frames (parsing log text, global logging, message
/// content through our logger); reusing the vendor's socket URL (one connection, expires in 100 s);
/// forking the vendor. Delete this when the vendor surfaces the events.
///
/// Connect allows five sockets per participant; this is the second. Its connection is created with
/// type `WEBSOCKET` only, so it mints no connection token and the vendor's stays valid (verified on
/// the wire, also across a vendor reconnect). The driver opens it when the vendor's connection is
/// established or re-established and stops it when the chat ends; between those it reopens itself
/// after a close, a few times in a row at most, since the vendor's own reconnect restarts it anyway.
final class AuthenticationEventListener: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var socket: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .ephemeral)

    static let subscribe = #"{"topic":"aws/subscribe","content":{"topics":["aws/chat"]}}"#
    static let heartbeat = #"{"topic":"aws/heartbeat"}"#
    static let maxConsecutiveFailures = 3

    /// - Parameters:
    ///   - websocketURL: a fresh socket URL (`CreateParticipantConnection`, type `WEBSOCKET`).
    ///   - onOpen: after each subscribe — the driver reads the transcript back for anything missed.
    ///   - onEvent: each sign-in frame.
    func start(websocketURL: @escaping @Sendable () async throws -> URL,
               onOpen: @escaping @Sendable () -> Void,
               onEvent: @escaping @Sendable (AuthenticationFrames.Event) -> Void) {
        stop()
        let run = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled, failures < Self.maxConsecutiveFailures, let self {
                do {
                    let socket = self.session.webSocketTask(with: try await websocketURL())
                    self.lock.withLock { self.socket = socket }
                    socket.resume()
                    try await socket.send(.string(Self.subscribe))
                    onOpen()
                    let beat = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(10))
                            try? await socket.send(.string(Self.heartbeat))
                        }
                    }
                    defer { beat.cancel(); socket.cancel(with: .goingAway, reason: nil) }
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        failures = 0
                        if case .string(let text) = message, let event = AuthenticationFrames.event(fromFrame: text) { onEvent(event) }
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    failures += 1
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
        lock.withLock { task = run }
    }

    func stop() {
        let (task, socket) = lock.withLock { () -> (Task<Void, Never>?, URLSessionWebSocketTask?) in
            defer { self.task = nil; self.socket = nil }
            return (self.task, self.socket)
        }
        task?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)   // ends a pending receive
    }

    deinit { stop() }
}
