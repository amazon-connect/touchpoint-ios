import Foundation

/// Whether the customer can share, or is sharing, this app's screen with the agent.
///
/// The agent opens a screen-sharing session in the agent workspace; Connect tells the call, and
/// only then can the customer start. Sharing is Chime's own in-app capture (ReplayKit), so iOS
/// shows its consent prompt and status-bar indicator, and only this app's screen is sent. Host-marked
/// views are blacked out of the shared frame, and a host-marked "secure" view blanks the whole frame
/// — see ``TouchpointScreenShare`` (UIKit) and `touchpointScreenShareRedacted()` /
/// `touchpointScreenShareSecure()` (SwiftUI). **Not in v1:** other apps (a
/// broadcast extension) and the agent sharing back.
public enum ScreenShareState: Sendable, Equatable, Hashable {
    /// No session from the agent, the host did not opt in, or the call is not live.
    case unavailable
    /// The agent opened a session; the customer may start sharing.
    case available
    /// The customer asked to share: iOS's consent prompt, then Chime's content attendee joining.
    case starting
    /// The agent can see the screen.
    case sharing
}

/// Connect's signal, a Chime realtime data message on `AMAZON_CONNECT_SCREEN_SHARING` whose body is
/// `{"message": …}` (the AWS Connect in-app calling sample, `CallManager.swift`).
enum ScreenShareSignal: Equatable, Sendable {
    /// The agent opened a session and this customer may send.
    case started
    /// A session exists but this customer may only view (no `ScreenShare: SEND` capability), or the
    /// agent ended it. Either way the customer must not be sharing.
    case stopped

    static let topic = "AMAZON_CONNECT_SCREEN_SHARING"

    /// `nil` for anything unrecognised: a newer message is ignored rather than misread.
    init?(data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String else { return nil }
        switch message {
        case "ScreenSharingStarted": self = .started
        case "ScreenSharingStartedViewOnly", "ScreenSharingStopped": self = .stopped
        default: return nil
        }
    }
}
