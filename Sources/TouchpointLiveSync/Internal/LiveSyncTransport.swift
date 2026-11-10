import Foundation

/// What the socket tells the client. Receive-only: Live Sync never sends on the socket.
enum LiveSyncTransportEvent: Sendable {
    /// The handshake completed. The client treats this as "subscribed" and posts pending context.
    case opened
    /// A text frame, or a UTF-8 binary frame.
    case text(String)
}

/// One socket connection. Production is `WebSocketTransport` over `URLSessionWebSocketTask` (kept
/// deliberately: session-per-connection plus `invalidateAndCancel()` is the leak mitigation, and a
/// third-party socket would add a dependency). Tests inject a scripted one so frames can be driven and
/// the reconnect loop observed without a network.
protocol LiveSyncTransport: AnyObject, Sendable {
    /// Opens the socket; the stream finishes when the socket ends, for whatever reason.
    func open(request: URLRequest) -> AsyncStream<LiveSyncTransportEvent>
    /// Closes the socket and finishes the stream. Safe to call more than once.
    func close()
    /// The error that ended the connection, or `nil` when it closed cleanly or was closed by us.
    var terminationError: LiveSyncError? { get }
}

/// Makes one transport per connection attempt.
protocol LiveSyncTransportFactory: Sendable {
    func makeTransport() -> any LiveSyncTransport
}

struct WebSocketTransportFactory: LiveSyncTransportFactory {
    func makeTransport() -> any LiveSyncTransport { WebSocketTransport() }
}

/// The backoff's sleep, injectable so reconnect tests do not wait real time.
protocol LiveSyncSleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousClockSleeper: LiveSyncSleeping {
    func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
