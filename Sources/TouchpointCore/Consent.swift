import Foundation

// MARK: - Consent (App Store guideline 5.1.2(i))

/// What the consent disclosure tells the customer: what is shared, with whom, and where to read
/// more. The SDK renders a default presentation from it; a host whose copy is reviewed by its own
/// legal team substitutes its own view and reads these same fields.
///
/// Putting the disclosure only in a privacy policy **is not sufficient** for 5.1.2(i) — reviewers
/// want in-app disclosure of what is sent and to whom, before it is sent.
public struct ConsentPrompt: Sendable, Equatable {
    /// What is shared, in plain language. E.g. "which screen you are on and what the app can do there".
    public var dataDescription: String
    /// Who receives it. E.g. "Acme Bank's voice assistant, run by Amazon Connect".
    public var recipient: String
    public var privacyPolicyURL: URL?

    public init(dataDescription: String, recipient: String, privacyPolicyURL: URL? = nil) {
        self.dataDescription = dataDescription
        self.recipient = recipient
        self.privacyPolicyURL = privacyPolicyURL
    }
}

/// A persisted record of the customer's Live Sync consent decision, per deployment, so the prompt is
/// shown once and a revocation survives relaunch. Kept in the Keychain (`whenUnlockedThisDeviceOnly`)
/// rather than `UserDefaults`: no required-reason API, and a decision about sharing data with a third
/// party should not travel in a backup to another device.
public actor ConsentStore {
    public enum Decision: String, Sendable, Codable, Equatable {
        case granted, denied
    }

    private let keychain: any KeychainStore
    private let deploymentID: String
    private let now: @Sendable () -> Date

    /// - Parameter deploymentID: identifies the deployment the decision is for — a new deployment
    ///   (a different assistant) asks again.
    public init(keychain: any KeychainStore, deploymentID: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.deploymentID = deploymentID
        self.now = now
    }

    private var key: String { "livesync.consent.v1.\(deploymentID)" }
    private struct Record: Codable { var decision: Decision; var decidedAt: Date }

    /// The stored decision, or `nil` if the customer has not been asked for this deployment.
    public func decision() async -> Decision? {
        guard let data = try? await keychain.get(key) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.decision
    }

    public func decidedAt() async -> Date? {
        guard let data = try? await keychain.get(key) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.decidedAt
    }

    public func record(_ decision: Decision) async {
        guard let data = try? JSONEncoder().encode(Record(decision: decision, decidedAt: now())) else { return }
        try? await keychain.set(data, for: key, accessibility: .whenUnlockedThisDeviceOnly)
    }

    /// Forget the decision so the prompt is shown again (a host "re-present the prompt" affordance).
    public func reset() async {
        try? await keychain.delete(key)
    }
}

// MARK: - Permission denial as a product state

/// Where a permission stands, as the SDK sees it. Mirrors the system's status without importing
/// AVFoundation into Core.
public enum PermissionStatus: Sendable, Equatable {
    /// Never asked. The SDK never asks on its own — see `PermissionPolicy`.
    case notDetermined
    case granted
    /// Denied by the user, or restricted by policy. Settings is the only way back.
    case denied
}

/// The product consequence of a denied permission, so a host shows a state rather than a failure
/// ("voice degrades to chat, offering a Settings deep link").
public struct PermissionDenial: Sendable, Equatable {
    public enum Consequence: Sendable, Equatable {
        /// Microphone: outbound voice is unavailable; chat remains.
        case voiceUnavailableChatRemains
    }

    public let permission: Permission
    public let consequence: Consequence

    public init(_ permission: Permission) {
        self.permission = permission
        switch permission {
        case .microphone: consequence = .voiceUnavailableChatRemains
        }
    }

    /// The system Settings deep link for this app. `nil` only where `UIApplication` is unavailable.
    public var settingsURL: URL? {
        #if canImport(UIKit)
        return URL(string: "app-settings:")
        #else
        return nil
        #endif
    }
}

/// Whether the SDK may ask the system for a permission. **Default: never.** A permission request
/// is a one-shot the host owns — the moment it is asked decides whether it is granted — so the SDK
/// requests only when the host has opted in for that permission ("never request a
/// permission without host opt-in").
public struct PermissionPolicy: Sendable, Equatable {
    public var mayRequest: Set<Permission>

    public init(mayRequest: Set<Permission> = []) { self.mayRequest = mayRequest }

    public static let never = PermissionPolicy()

    public func allows(_ permission: Permission) -> Bool { mayRequest.contains(permission) }
}

/// Asks the system, or does not. Core defines the seam; the modality that needs the permission
/// (voice, for the microphone) supplies the real one, and a test
/// supplies a scripted one. Every requester **must** honour the policy: a request for a permission
/// the policy does not allow returns the current status and asks nothing.
public protocol PermissionRequesting: Sendable {
    func status(of permission: Permission) async -> PermissionStatus
    /// Requests only if `policy.allows(permission)`; otherwise returns `status(of:)` unchanged.
    func requestIfAllowed(_ permission: Permission, policy: PermissionPolicy) async -> PermissionStatus
}

extension PermissionRequesting {
    /// The product state for a permission right now: `nil` when usable (or not yet asked), a denial
    /// when the system has said no.
    public func denial(for permission: Permission) async -> PermissionDenial? {
        await status(of: permission) == .denied ? PermissionDenial(permission) : nil
    }
}
