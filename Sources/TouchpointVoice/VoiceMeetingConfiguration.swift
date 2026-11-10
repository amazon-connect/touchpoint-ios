import Foundation
import TouchpointCore

/// Connect's `StartWebRTCContact` `ConnectionData`, decoded field by field into what Chime's
/// `MeetingSessionConfiguration` requires.
///
/// The four `MediaPlacement` URLs are optional in Connect's response and required by Chime, so each
/// absence is a typed `malformedPayload` naming the field — never a silent `nil`.
/// Error descriptions name fields only, never values: the join token is a credential.
struct VoiceMeetingConfiguration: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let meetingID: String
    let mediaRegion: String?
    let attendeeID: String
    let joinToken: String
    let urls: VoiceMeetingURLs

    init(meetingJSON: Data, attendeeJSON: Data) throws {
        guard let meeting = (try? JSONSerialization.jsonObject(with: meetingJSON)) as? [String: Any] else {
            throw TouchpointError.malformedPayload("ConnectionData.Meeting")
        }
        guard let attendee = (try? JSONSerialization.jsonObject(with: attendeeJSON)) as? [String: Any] else {
            throw TouchpointError.malformedPayload("ConnectionData.Attendee")
        }
        func required(_ object: [String: Any], _ key: String, at path: String) throws -> String {
            guard let value = object[key] as? String, !value.isEmpty else {
                throw TouchpointError.malformedPayload("\(path).\(key)")
            }
            return value
        }
        meetingID = try required(meeting, "MeetingId", at: "ConnectionData.Meeting")
        mediaRegion = meeting["MediaRegion"] as? String
        guard let placement = meeting["MediaPlacement"] as? [String: Any] else {
            throw TouchpointError.malformedPayload("ConnectionData.Meeting.MediaPlacement")
        }
        let p = "ConnectionData.Meeting.MediaPlacement"
        urls = VoiceMeetingURLs(
            audioHostURL: try required(placement, "AudioHostUrl", at: p),
            audioFallbackURL: try required(placement, "AudioFallbackUrl", at: p),
            signalingURL: try required(placement, "SignalingUrl", at: p),
            turnControlURL: try required(placement, "TurnControlUrl", at: p),
            ingestionURL: nil
        )
        attendeeID = try required(attendee, "AttendeeId", at: "ConnectionData.Attendee")
        joinToken = try required(attendee, "JoinToken", at: "ConnectionData.Attendee")
    }

    var description: String { "VoiceMeetingConfiguration(meetingID: \(meetingID), attendeeID: \(attendeeID), joinToken: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["meetingID": meetingID, "attendeeID": attendeeID, "joinToken": "<redacted>"]) }

    func startParameters(reconnectTimeoutMs: Int) -> VoiceStartParameters {
        VoiceStartParameters(meetingID: meetingID, attendeeID: attendeeID, externalUserID: "",
                             joinToken: joinToken, urls: urls,
                             reconnectTimeoutMs: reconnectTimeoutMs, callKitEnabled: true)
    }
}
