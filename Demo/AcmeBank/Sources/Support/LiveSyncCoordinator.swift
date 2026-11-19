import Foundation
import Observation
import UIKit
import TouchpointCore
import TouchpointLiveSync

/// Live Sync for the demo: binds to a live contact and lets the assistant drive the app
/// through the five dispute actions. **No imperative `sendContext` anywhere in the
/// app**: each screen declares its actions with `.touchpointAction`, the `aggregator` collects what
/// is visible, and the context follows navigation on its own. The contact id comes from the app
/// (a deep link, or the chat contact it started); the debug Settings screen keeps manual entry.
@MainActor
@Observable
final class LiveSyncCoordinator {
    struct LogEntry: Identifiable { let id = UUID(); let at = Date(); let text: String }

    private(set) var client: LiveSyncClient?
    /// The customer's real decision. Created with each client; the root presents the SDK's
    /// sheet while `needsPrompt`. Decisions persist per deployment key in the Keychain.
    private(set) var consent: LiveSyncConsentController?
    private let consentKeychain = SecurityFrameworkKeychainStore(service: "com.acmebank.demo")
    /// The live UI tests (keys from the launch environment) decline consent; that decision lives
    /// apart, so it never carries over to someone using the app on the same simulator.
    private let testConsentKeychain = SecurityFrameworkKeychainStore(service: "com.acmebank.demo.uitest")
    static let consentPrompt = ConsentPrompt(
        dataDescription: "which screen you're on and what you can do there",
        recipient: "\(PartnerBrand.bankName)'s voice assistant",
        privacyPolicyURL: URL(string: "https://example.com/acme/privacy"))
    /// The one aggregator for the app's view tree, bound at the root with `.touchpointLiveSync`. It
    /// outlives any client: posts forward to whichever client is current, so the tree declares
    /// actions from launch and a (re)connect advertises the screen already on show.
    let aggregator: TouchpointActionAggregator
    private(set) var state: LiveSyncConnectionState = .idle
    /// Connected, or reconnecting after having been — the stretch in which the assistant can drive
    /// the screens. A rebind (a call starting on top of a chat) also stays active through the new
    /// client's connecting, so the support panel's layout does not flip back and forth.
    var isActive: Bool {
        switch state {
        case .connected, .reconnecting: true
        case .connecting, .idle: rebinding
        case .disconnected: false
        }
    }
    /// Set when a live client is replaced; cleared when the new one settles either way.
    private var rebinding = false
    private(set) var dispatch: DispatchState = .enabled
    private(set) var log: [LogEntry] = []
    var contactID = ""
    /// Debug-only Live Sync keys: typed on the sign-in screen and kept in this device's keychain, or
    /// (the live UI tests) from the launch environment. Never in the package or the scheme's run action.
    private(set) var isConfigured = false
    /// The keys came from the launch environment, so the sign-in screen doesn't ask for them.
    private(set) var keysFromEnvironment = false
    /// True once the saved keys have been read at launch; the sign-in screen waits for it, so it
    /// never shows (or saves) empty fields over keys that simply hadn't loaded yet. Outside
    /// `#if DEBUG` so observation tracks it; a release build has nothing to load.
    private(set) var keysLoaded: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()
    /// A live UI test launched the app (`ACME_UITEST`): its consent decisions stay out of the app's
    /// own keychain, whether or not it passed keys.
    private let isUITest = ProcessInfo.processInfo.environment["ACME_UITEST"] == "1"

    /// The app model the assistant drives. Set by the app at launch.
    weak var app: AppModel?

    /// In force now; the sign-in screen pre-fills from these.
    private(set) var deploymentKey = ""
    private(set) var apiKey = ""
    private var region = "ca-central-1"

    /// Indirection so the aggregator's `post` can target a client created later.
    private final class ClientBox { weak var client: LiveSyncClient? }
    private let box = ClientBox()

    init() {
        let box = self.box
        aggregator = TouchpointActionAggregator(
            // Whichever actions the tree marks `confirmationRequired` the current client holds.
            confirmations: { [box] in box.client?.confirmationRequirements = $0 },
            post: { [box] in try await box.client?.sendContext($0) })
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        deploymentKey = env["ACME_LIVESYNC_DEPLOYMENT_KEY"] ?? ""
        apiKey = env["ACME_LIVESYNC_API_KEY"] ?? ""
        region = DemoEnvironment.values["ACME_LIVE_REGION"] ?? region
        isConfigured = !deploymentKey.isEmpty && !apiKey.isEmpty
        keysFromEnvironment = isConfigured
        // A contact id in the environment binds at launch — the live test's path —
        // straight away with environment keys, otherwise once `loadSavedKeys` has the saved ones.
        if let id = env["ACME_LIVESYNC_CONTACT_ID"], !id.isEmpty {
            contactID = id
            if keysFromEnvironment { Task { @MainActor in self.connect() } }
        }
        #endif
    }

    #if DEBUG
    /// One keychain item holding both keys, so a failed write can't leave half a pair.
    private static let keysItem = "demo.livesync.keys.v1"
    private struct SavedKeys: Codable { let deploymentKey: String; let apiKey: String }

    /// The keys saved from the sign-in screen, unless the launch environment supplied its own.
    func loadSavedKeys() async {
        defer { keysLoaded = true }
        guard !keysFromEnvironment else { return }
        if let data = try? await consentKeychain.get(Self.keysItem),
           let saved = try? JSONDecoder().decode(SavedKeys.self, from: data) {
            apply(deploymentKey: saved.deploymentKey, apiKey: saved.apiKey)
        }
        // A contact id in the environment binds once the keys are in (it used to race them).
        if isConfigured, !contactID.isEmpty { connect() }
    }

    enum KeyProblem: Error, LocalizedError {
        case onlyOne, malformed(String)
        var errorDescription: String? {
            switch self {
            case .onlyOne: "Enter both Live Sync keys."
            case .malformed(let which): "That \(which) doesn't look right: letters, digits, _ and - only."
            }
        }
    }

    /// Keys typed on the sign-in screen: checked for shape only, kept in this device's keychain
    /// (unlocked, this device only). Both fields empty keeps the saved keys; `forgetKeys` drops them.
    /// Returns whether anything changed.
    @discardableResult
    func setKeys(deploymentKey newDeployment: String, apiKey newAPI: String) async throws -> Bool {
        guard !keysFromEnvironment else { return false }
        let d = newDeployment.trimmingCharacters(in: .whitespacesAndNewlines)
        let a = newAPI.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty, a.isEmpty { return false }
        guard !d.isEmpty, !a.isEmpty else { throw KeyProblem.onlyOne }
        guard d.wholeMatch(of: /[A-Za-z0-9_-]{8,64}/) != nil else { throw KeyProblem.malformed("deployment key") }
        guard a.wholeMatch(of: /[A-Za-z0-9_-]{16,128}/) != nil else { throw KeyProblem.malformed("API key") }
        guard d != deploymentKey || a != apiKey else { return false }
        let data = try JSONEncoder().encode(SavedKeys(deploymentKey: d, apiKey: a))
        try await consentKeychain.set(data, for: Self.keysItem, accessibility: .whenUnlockedThisDeviceOnly)
        replaceKeys(deploymentKey: d, apiKey: a)
        return true
    }

    /// Drops the saved keys; Live Sync is off until new ones are entered.
    func forgetKeys() async {
        guard !keysFromEnvironment else { return }
        try? await consentKeychain.delete(Self.keysItem)
        replaceKeys(deploymentKey: "", apiKey: "")
    }

    /// New keys mean a different deployment: a client bound with the old ones is closed (including
    /// one on a running call), and its consent controller, which was for the old deployment, goes
    /// with it. The next contact binds with the new keys.
    private func replaceKeys(deploymentKey d: String, apiKey a: String) {
        client?.onConnectionStateChange = nil
        client?.disconnect()
        client = nil
        box.client = nil
        consent = nil
        state = .idle
        rebinding = false
        apply(deploymentKey: d, apiKey: a)
    }

    private func apply(deploymentKey d: String, apiKey a: String) {
        deploymentKey = d
        apiKey = a
        isConfigured = !d.isEmpty && !a.isEmpty
    }
    #endif

    /// Binds to the chat contact the app just started.
    func bind(contactID: String) {
        self.contactID = contactID
        connect()
    }

    /// The deep-link scheme/host this demo accepts. Reference resolver only: the
    /// production recommendation is host-backend resolution, because an unauthenticated link is a
    /// bearer credential for the conversation.
    static let deepLinkScheme = "acmebank", deepLinkHost = "support", deepLinkPath = "/livesync"

    /// Binds to the contact a deep link names, if the link is well-formed; anything else is noted
    /// and ignored. Manual entry remains available on the debug Settings screen.
    func bind(url: URL) {
        Task {
            let resolver = DeepLinkContactIDResolver(url: url, scheme: Self.deepLinkScheme, host: Self.deepLinkHost, pathPrefix: Self.deepLinkPath)
            guard let id = try? await resolver.resolveContactID() else { note("deep link ignored: not a Live Sync link"); return }
            bind(contactID: id)
        }
    }

    func connect() {
        guard isConfigured, !contactID.isEmpty else { note("not configured or no contact id"); return }
        // Detach before disconnecting: the old client's `.disconnected` would otherwise land here
        // and drop `isActive` for the moment before the new one reports.
        rebinding = isActive
        client?.onConnectionStateChange = nil
        client?.disconnect()
        #if DEBUG
        let backend = DevelopmentBackend(liveSync: .init(deploymentKey: deploymentKey, apiKey: apiKey))
        let broker = CredentialBroker(backend: backend, keychain: InMemoryKeychainStore())
        do {
            let config = try LiveSyncConfiguration(region: region, conversationId: contactID,
                                                   channel: LiveSyncChannel(locale: Locale(identifier: "en_US")))
            // Consent starts held; the controller loads the stored decision or shows the sheet.
            let c = LiveSyncClient(configuration: config, credentials: broker, consent: .held, autoConnect: false)
            consent = LiveSyncConsentController(client: c, store: ConsentStore(keychain: isUITest || keysFromEnvironment ? testConsentKeychain : consentKeychain, deploymentID: deploymentKey), prompt: Self.consentPrompt)
            c.onConnectionStateChange = { [weak self] s in
                guard let self else { return }
                self.state = s
                if s != .connecting, s != .idle { self.rebinding = false }
                self.note("state → \(s)")
            }
            c.onDispatchStateChange = { [weak self] s, reason in self?.dispatch = s; self?.note("dispatch → \(s) (\(reason.map { "\($0)" } ?? "resumed"))") }
            c.onError = { [weak self] e in
                guard let self else { return }
                // A new client that cannot get going never reports `.disconnected` while it retries.
                switch e {
                case .credentialVendingFailed, .invalidConfiguration: self.rebinding = false
                default: break
                }
                self.note("error: \(e)")
            }
            c.onNavigation = { [weak self] nav in self?.note("navigation \(nav.kind) \(nav.destination ?? "")") }
            // The view tree's declarations route through the one aggregator; the new client
            // advertises the screen already on show.
            c.onAction = { [aggregator] in try aggregator.route($0) }
            // Consent revoked then granted again (Settings → Ask me again) leaves the client with no
            // context, and it rejects every action it has not been told about: advertise the screen.
            c.onContextNeeded = { [aggregator] in aggregator.readvertise() }
            box.client = c
            client = c
            // The old client's last state no longer describes anything; only `rebinding` carries
            // `isActive` until this one reports.
            state = .idle
            aggregator.readvertise()
            c.connect()
            note("connecting for contact \(contactID.prefix(8))…")
        } catch {
            // The old client was already disconnected above; nothing is live.
            state = .disconnected
            rebinding = false
            client = nil
            box.client = nil
            note("configuration error: \(error)")
        }
        #endif
    }

    func disconnect() { client?.disconnect(); note("disconnected by user") }

    private func note(_ text: String) {
        log.append(LogEntry(text: text))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
