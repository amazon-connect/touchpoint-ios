import Foundation
import TouchpointCore

/// Connection details for a Live Sync session — the parts that are *not* credentials.
///
/// Credentials (`deploymentKey`, `apiKey`) come from a `LiveSyncCredentialSource` on every
/// connection attempt and every context POST, because the key lives in the socket URL and a rotated
/// key can only reach a new socket. The hosts are derived from `region` and `stage`:
/// `ws.nlu.acxd.connect[-stage].<region>.amazonaws.com` for the receive-only action socket and the
/// same host without the `ws.` prefix for the context API.
public struct LiveSyncConfiguration: Sendable {
    /// AWS region of the Amazon Connect instance, e.g. `us-west-2`.
    public var region: String

    /// Amazon Connect contact ID of the voice conversation to mirror. Sent as `conversationId`.
    public var conversationId: String

    /// The Live Sync channel, derived from a `Locale` (Core canonicalises the tag).
    public var channel: LiveSyncChannel

    /// A non-production stage suffix, for testing the SDK itself. Leave it `nil`: an app always
    /// uses production.
    public var stage: String?

    /// `User-Agent` header sent with the socket handshake and the context request. `nil` leaves the
    /// system default in place.
    public var userAgent: String?

    public init(
        region: String,
        conversationId: String,
        channel: LiveSyncChannel,
        stage: String? = nil,
        userAgent: String? = nil
    ) {
        self.region = region
        self.conversationId = conversationId
        self.channel = channel
        self.stage = stage
        self.userAgent = userAgent
    }
}

extension LiveSyncConfiguration {
    /// `connect-<languageTag>`.
    public var channelKey: String { channel.key }

    var stageSuffix: String {
        guard let stage, !stage.isEmpty else { return "" }
        return "-\(stage)"
    }

    /// Host of the receive-only action socket.
    public var socketHost: String {
        "ws.nlu.acxd.connect\(stageSuffix).\(region).amazonaws.com"
    }

    /// Host of the context API — the socket host without the `ws.` prefix.
    public var apiHost: String {
        "nlu.acxd.connect\(stageSuffix).\(region).amazonaws.com"
    }

    func socketURL(credentials: LiveSyncCredentials) throws -> URL {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = socketHost
        components.path = "/"
        components.queryItems = [
            URLQueryItem(name: "deploymentKey", value: credentials.deploymentKey),
            URLQueryItem(name: "channelKey", value: channelKey),
            URLQueryItem(name: "apiKey", value: credentials.apiKey),
            URLQueryItem(name: "conversationId", value: conversationId),
            URLQueryItem(name: "type", value: "voice-plus"),
        ]
        guard let url = components.url else {
            throw LiveSyncError.invalidConfiguration("Could not build the Live Sync socket URL")
        }
        return url
    }

    func contextURL(credentials: LiveSyncCredentials) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = "/nlu/c/\(credentials.deploymentKey)/\(channelKey)/context"
        guard let url = components.url else {
            throw LiveSyncError.invalidConfiguration("Could not build the Live Sync context URL")
        }
        return url
    }

    func validate(credentials: LiveSyncCredentials) throws {
        let required: [(String, String)] = [
            ("region", region),
            ("deploymentKey", credentials.deploymentKey),
            ("apiKey", credentials.apiKey),
            ("conversationId", conversationId),
        ]
        for (name, value) in required where value.isEmpty {
            throw LiveSyncError.invalidConfiguration("`\(name)` must not be empty")
        }
    }
}
