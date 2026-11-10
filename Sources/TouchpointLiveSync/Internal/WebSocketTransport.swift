import Foundation

/// Bridges a `URLSessionWebSocketTask` to an `AsyncStream` of events.
///
/// The Live Sync socket is receive-only, so this is deliberately one-directional: it opens the
/// connection, forwards text frames, and finishes the stream when the socket closes or fails. The
/// class is its own `URLSession` delegate, which is how the `opened` event is observed — the client
/// needs it to know when the backend has an active subscriber for the contact and context may be
/// posted.
final class WebSocketTransport: NSObject, LiveSyncTransport, @unchecked Sendable {
    typealias Event = LiveSyncTransportEvent

    /// Guards the mutable state below, which is touched from the delegate queue, the receive loop
    /// and the caller.
    private let lock = NSLock()
    private var continuation: AsyncStream<Event>.Continuation?
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var closeReason: LiveSyncError?
    private var isFinished = false

    /// The error that ended the connection, or `nil` when it closed cleanly.
    var terminationError: LiveSyncError? {
        lock.withLock { closeReason }
    }

    /// Opens the socket and returns the event stream. The stream finishes once the socket ends, for
    /// whatever reason.
    func open(request: URLRequest) -> AsyncStream<Event> {
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .unbounded)
        // Default timeouts, deliberately: `timeoutIntervalForRequest` is an *idle* timer that resets
        // on each received byte, and this socket is receive-only — the server pushes nothing until the
        // assistant acts, so any value here would churn the connection on every quiet half-minute of a
        // live call. Liveness is the zombie-socket guard's job, measured against the lease.
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)

        lock.withLock {
            self.continuation = continuation
            self.session = session
            self.task = task
        }

        task.resume()
        Task.detached { [weak self] in
            await self?.receiveFrames(from: task)
        }
        return stream
    }

    /// Closes the socket and finishes the stream. Safe to call more than once.
    func close() {
        finish(with: nil)
    }

    private func receiveFrames(from task: URLSessionWebSocketTask) async {
        while true {
            do {
                switch try await task.receive() {
                case .string(let text):
                    yield(.text(text))
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) {
                        yield(.text(text))
                    }
                @unknown default:
                    continue
                }
            } catch {
                // A deliberate `close()` also lands here; `finish` ignores it because the stream has
                // already been terminated. A rejected handshake lands here too, racing
                // `didCompleteWithError`; both classify from the task's response so whichever wins
                // reports the HTTP status and the client can tell "key refused" from "network down".
                finish(with: Self.classify(error, response: task.response))
                return
            }
        }
    }

    private func yield(_ event: Event) {
        let continuation = lock.withLock { self.continuation }
        continuation?.yield(event)
    }

    private func finish(with error: LiveSyncError?) {
        let continuation: AsyncStream<Event>.Continuation? = lock.withLock {
            guard !isFinished else { return nil }
            isFinished = true
            closeReason = error
            let continuation = self.continuation
            self.continuation = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            session?.invalidateAndCancel()
            session = nil
            return continuation
        }
        continuation?.finish()
    }
}

extension WebSocketTransport: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        yield(.opened)
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let detail = reason.flatMap { String(data: $0, encoding: .utf8) }
        let error: LiveSyncError? =
            closeCode == .normalClosure || closeCode == .goingAway
            ? nil
            : .socketFailure(
                description: "closed with code \(closeCode.rawValue)"
                    + (detail.map { ": \($0)" } ?? "")
            )
        finish(with: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        // Handshake rejections (e.g. a 403 from an expired API key) complete the task with an error
        // and no `didCloseWith`; `receiveFrames` also throws for them. Same classification in both.
        guard let error else { return }
        finish(with: Self.classify(error, response: task.response))
    }

    /// An HTTP status on the task's response means the server answered the handshake and refused it;
    /// that is the one failure that must not be retried with the same key.
    private static func classify(_ error: any Error, response: URLResponse?) -> LiveSyncError {
        if let status = (response as? HTTPURLResponse)?.statusCode, status >= 400 {
            return .httpFailure(statusCode: status, responseBody: nil)
        }
        return .socketFailure(description: LiveSyncError.describe(error))
    }
}
