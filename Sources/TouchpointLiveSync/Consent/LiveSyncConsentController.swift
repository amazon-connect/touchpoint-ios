import Foundation
import TouchpointCore

/// Drives the consent decision for one Live Sync client: reads the persisted decision, decides
/// whether the prompt must be shown, applies the customer's answer to the client and the store.
///
/// The *gate* is in `LiveSyncClient`; this is the part that produces a real
/// decision from the user instead of the debug `.development` default. A host that substitutes its
/// own consent UI calls `grant()` / `deny()` from it.
@MainActor
@Observable
public final class LiveSyncConsentController {
    public let prompt: ConsentPrompt
    /// `true` while the customer has not decided for this deployment and must be asked.
    public private(set) var needsPrompt = false
    /// The decision in effect, mirrored from the client.
    public private(set) var decision: ConsentDecision

    private let client: LiveSyncClient
    private let store: ConsentStore
    private let announce: @MainActor (String) -> Void

    /// - Parameters:
    ///   - client: the client whose consent this governs. Its current `consent` is the starting
    ///     point; if it is `.held` the store is consulted.
    ///   - store: the persisted decision for this deployment.
    ///   - announce: VoiceOver announcement hook; the default posts a UIAccessibility announcement.
    public init(client: LiveSyncClient, store: ConsentStore, prompt: ConsentPrompt,
                announce: @escaping @MainActor (String) -> Void = LiveSyncConsentController.defaultAnnounce) {
        self.client = client
        self.store = store
        self.prompt = prompt
        self.decision = client.consent
        self.announce = announce
    }

    /// Loads the stored decision and applies it. Call once after creating the client (and before
    /// `connect()` if the socket should wait for a grant). With nothing stored, `needsPrompt` becomes
    /// `true` and the client stays `.held` — nothing is posted.
    public func load() async {
        guard client.consent == .held else { decision = client.consent; return }
        switch await store.decision() {
        case .granted?: await client.setConsent(.granted); decision = .granted
        case .denied?: await client.setConsent(.denied); decision = .denied
        case nil: needsPrompt = true
        }
    }

    /// The customer agreed. Persisted; the client flushes any held context.
    public func grant() async {
        await store.record(.granted)
        await client.setConsent(.granted)
        decision = .granted
        needsPrompt = false
    }

    /// The customer declined, or revoked. Persisted; the client tears the socket down and clears
    /// what it advertised (revocation is immediate). Chat and voice are unaffected.
    public func deny() async {
        let wasGranted = decision == .granted
        await store.record(.denied)
        await client.setConsent(.denied)
        decision = .denied
        needsPrompt = false
        if wasGranted { announce(TouchpointStrings.consentRevokedAnnouncement) }
    }

    /// Forget the stored decision and ask again (a host "re-present the prompt" affordance).
    public func reset() async {
        await store.reset()
        await client.setConsent(.held)
        decision = .held
        needsPrompt = true
    }

    public static let defaultAnnounce: @MainActor (String) -> Void = { text in
        #if canImport(UIKit) && !os(watchOS)
        UIAccessibility.post(notification: .announcement, argument: text)
        #endif
    }
}

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
