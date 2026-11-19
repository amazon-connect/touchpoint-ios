import Foundation
import Observation
import TouchpointChat
import TouchpointVoice
import TouchpointCore
import UIKit
import UserNotifications

/// Builds and owns the Touchpoint session for the Support dock. This is the integration an app
/// would write: a backend, a broker, a store, a transport, one session — and, the host's own
/// choice, a local notification when support replies while the chat is not on screen.
@MainActor
@Observable
final class SupportCoordinator {
    enum Mode: String, CaseIterable, Identifiable, Codable {
        /// Scripted agent, no network. The default; what the UI test runs against.
        case offline
        /// A real Amazon Connect agent through the demo backend (Demo/backend). Debug builds only.
        case live
        var id: String { rawValue }
        var label: String {
            switch self {
            case .offline: "Offline (scripted agent)"
            case .live: "Live (Amazon Connect)"
            }
        }
    }

    private(set) var session: TouchpointSession? {
        didSet {
            guard session !== oldValue else { return }
            sessionGeneration &+= 1
        }
    }
    /// Bumps whenever `session` becomes a different object; the dock keys its view on it.
    private(set) var sessionGeneration = 0
    private(set) var mode: Mode
    private(set) var lastError: String?
    /// The last chat start failed: the panel shows the error and Try again, not an empty chat.
    private(set) var startFailed = false
    /// Which host screen the customer is on, sent as a contact attribute so the contact flow can
    /// tailor its introduction (design: "Screen introduction"). Live Sync re-advertises on each change.
    var currentScreen = "accounts"

    /// Whether the conversation is on screen right now — the app knows (dock expanded, not mini, no
    /// full-screen call). Set by the app; a reply while it is on screen needs no notification.
    var isConversationOnScreen: @MainActor () -> Bool = { false }
    /// Opens the dock: a notification tap lands the customer in the conversation. Set by the app.
    var onOpenConversation: @MainActor () -> Void = {}
    /// How many local notifications this run has asked the system to post — shown in Settings and
    /// read by a UI test (XCUITest cannot read a banner reliably). A request is counted even when
    /// notifications are off, so the count is the app's policy, not what the system displayed.
    private(set) var requestedNotifications = 0
    /// A notification tap for a conversation the current session does not hold — the app was
    /// relaunched since it was posted. Held until the session exists, then resumed.
    private(set) var pendingResumeContactID: String?
    /// Live Sync rides on the chat contact (the web demo's shape): once a chat starts, its contact id
    /// binds the Live Sync socket. Set by the app at launch.
    weak var liveSync: LiveSyncCoordinator?
    /// Voice calling. Enabled in live mode with a second session over the same broker.
    weak var voice: VoiceCoordinator?
    /// The Connect instance's access URL, for opening Connect Views. Seeded from the launch
    /// environment by `make demo-project`; without it the guide card stays closed.
    let viewRendering: ConnectViewRendering? = {
        guard let url = DemoEnvironment.values["ACME_CONNECT_INSTANCE_URL"], !url.isEmpty else { return nil }
        return try? ConnectViewRendering(instanceURL: url)
    }()
    #if DEBUG
    var liveSettings = LiveDemoBackend.Settings()
    /// The demo user's sign-in, when `make demo-project` seeded the backend's identity pool: the
    /// sign-in screen then signs in for real, and the live backend signs with that user's
    /// credentials. Nil without it (offline, or the older vended-credentials path).
    private(set) var signIn: DemoSignIn?
    /// The Cognito app client's one callback (`Scripts/env/customer-auth.sh`).
    static let authenticationRedirect = URL(string: "acmebank-touchpoint://auth") ?? URL(fileURLWithPath: "/")
    #endif

    private let keychain = SecurityFrameworkKeychainStore(service: "com.acmebank.demo")
    private var store: ConversationStore?
    private var startTask: Task<Void, Never>?

    init(mode: Mode = .offline) {
        var mode = mode
        var seeded: LiveDemoBackend.Settings?
        #if DEBUG
        // Launch-environment seeding for the live test: typing a session token into a field by hand
        // is how a test run gets wasted. Values come in through the process environment only —
        // never the bundle, the repo, or any store — and are held in memory.
        let env = DemoEnvironment.values   // LiveConfig.plist, then the launch environment
        var cognito: DemoSignIn.Configuration?
        if let endpoint = env["ACME_LIVE_ENDPOINT"], !endpoint.isEmpty {
            let region = env["ACME_LIVE_REGION"] ?? "ca-central-1"
            cognito = DemoSignIn.Configuration(env: env, region: region)
            // With the sign-in, no IAM credentials are read at all, even if a host file is named.
            let creds = cognito == nil ? Self.seededCredentials(env: ProcessInfo.processInfo.environment) : nil
            let settings = LiveDemoBackend.Settings(
                endpoint: endpoint, region: region,
                accessKeyID: creds?.key ?? "", secretAccessKey: creds?.secret ?? "", sessionToken: creds?.token ?? "",
                callbackNumber: env["ACME_CALLBACK_NUMBER"] ?? "")
            // Sign-in on the fly wins over seeded credentials: with the identity pool's ids the
            // sign-in screen signs a demo user in, and nobody vends credentials for the app.
            if settings.hasEndpoint, cognito != nil || settings.isComplete { seeded = settings; mode = .live }
        }
        #endif
        self.mode = mode
        #if DEBUG
        if let seeded { liveSettings = seeded }
        if seeded != nil, let cognito { signIn = DemoSignIn(configuration: cognito) }
        #endif
    }

    #if DEBUG
    /// Whether the sign-in screen must sign a demo user in for real: live mode on the identity pool.
    var requiresSignIn: Bool { mode == .live && signIn != nil }
    /// Whether a demo user is signed in now (meaningful only when `requiresSignIn`).
    private(set) var hasSignedInUser = false

    /// Signs a demo user in. Throws with a message for the sign-in screen.
    func signInUser(username: String, password: String) async throws {
        guard let signIn else { return }
        hasSignedInUser = false
        try await signIn.signIn(username: username, password: password)
        hasSignedInUser = true
    }

    /// The Live Sync keys from the backend, as the signed-in demo user.
    func liveSyncKeysFromBackend() async throws -> (deploymentKey: String, apiKey: String) {
        let c = try await liveBackend().liveSyncCredentials()
        return (c.deploymentKey, c.apiKey)
    }

    func signOutUser() async {
        hasSignedInUser = false
        await signIn?.signOut()
    }

    /// The contact flow the live session was built for, and the one it should use now.
    private var builtFlow = ""
    private var desiredFlow: String { liveSync?.isConfigured == true ? "livesync" : "default" }

    /// The live backend, signing as the signed-in user when there is one.
    private func liveBackend() -> LiveDemoBackend {
        var live = LiveDemoBackend(settings: liveSettings)
        live.signIn = signIn
        return live
    }
    #endif

    /// Builds the session at launch so a notification tap that arrives before the user opens
    /// Support resumes at once rather than waiting for the build. Call from the app's `onAppear`.
    func prepare() async {
        _ = try? await ensureSession()
    }

    /// Switches mode. An in-flight start is awaited, then the existing contact, if any, is ended —
    /// a transport belongs to one mode, and an orphaned start would be a real contact nobody owns.
    func setMode(_ newMode: Mode) async {
        guard newMode != mode else { return }
        await startTask?.value
        await session?.end()
        session = nil
        pendingResumeContactID = nil
        await voice?.disable()          // leaving live mode: no instance to call, no stale credentials to reuse
        mode = newMode
        _ = try? await ensureSession()
    }

    /// Starts a chat unless one is live or about to be. Idempotent for the dock's expand action.
    func openChat() async {
        lastError = nil
        startFailed = false
        await startTask?.value
        do {
            var session = try await ensureSession()
            // A held notification tap means a resume is about to run; starting a new contact on top
            // of it would race `resume` on one session.
            guard !session.isActive, pendingResumeContactID == nil else { return }
            #if DEBUG
            // The contact flow is fixed when the session is built, and the showcase needs the Live
            // Sync keys, which can arrive (or go) on the sign-in screen after launch. Only here, about
            // to start a new contact on an idle session, is it safe to rebuild for the other flow:
            // a resume doesn't depend on the flow and keeps the session it started on.
            if mode == .live, builtFlow != desiredFlow {
                self.session = nil
                session = try await ensureSession()
            }
            #endif
            let task = Task { @MainActor [weak self] in
                do {
                    // Ask for notifications in context — the customer has just opened support — and
                    // never as a condition of chatting (App Store 4.5.4): either answer starts the
                    // chat. Declining only loses the "support replied" notification.
                    await Self.requestNotificationPermissionIfUndetermined()
                    try await session.startChat(ChatContactRequest(
                        displayName: DemoData.customerName,
                        attributes: ["screen": self?.currentScreen ?? "", "app": "AcmeBank", "platform": "ios"]))
                    // The contact exists: bind Live Sync to it so the assistant can drive the screens.
                    if let id = session.contactID, let ls = self?.liveSync, ls.isConfigured, self?.mode == .live {
                        ls.bind(contactID: id)
                    }
                } catch {
                    self?.lastError = Self.describe(error)
                    self?.startFailed = true
                    #if DEBUG
                    // A refused refresh signs the session out inside DemoSignIn; follow it here.
                    if let signIn = self?.signIn, !(await signIn.isSignedIn) { self?.hasSignedInUser = false }
                    #endif
                }
            }
            startTask = task
            await task.value
            startTask = nil
        } catch {
            lastError = Self.describe(error)
            startFailed = true
        }
    }

    func endChat() async {
        await startTask?.value
        await session?.end()
    }

    /// The system prompt once, the first time a chat starts; later chats see the stored answer.
    /// Declining only loses notifications: chat works the same. Under `-uiTesting` it is asked only
    /// when the launch passes `-promptNotifications`: a system alert over the composer would stall
    /// every other test on a fresh simulator.
    static func requestNotificationPermissionIfUndetermined() async {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uiTesting"), !args.contains("-promptNotifications") { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Web's reset (`App.tsx:688-713`): end whatever contact there is and start a new one. Backs
    /// both the header's restart and the "Start new conversation" button an ended chat shows. The
    /// SDK view reloads its transcript for the new contact, so the old conversation does not linger
    /// under the new greeting.
    func restartChat() async {
        await endChat()
        await openChat()
    }

    // MARK: - New-message notifications (the host's decision; the SDK only reports)

    /// `TouchpointSession.onIncomingMessages`: support replied. The SDK posts nothing; this app's
    /// policy is one generic local notification — never the message text, which would show on the
    /// lock screen — unless the conversation is on screen in the foreground, where the transcript
    /// already shows it. A catch-up batch (replies missed while the connection was down) is one
    /// notification too.
    private func handleIncoming(_ incoming: IncomingMessages) {
        let active = UIApplication.shared.applicationState == .active
        guard Self.shouldNotify(appIsActive: active, conversationOnScreen: isConversationOnScreen()) else { return }
        requestedNotifications += 1
        let content = UNMutableNotificationContent()
        content.title = PartnerBrand.bankName
        content.body = String(localized: "notification.chat.body")
        content.threadIdentifier = incoming.contactID
        content.userInfo = [Self.contactIDKey: incoming.contactID]
        // One request per contact: a newer reply replaces the older banner rather than stacking.
        let request = UNNotificationRequest(identifier: "chat-\(incoming.contactID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    /// Pure, so a unit test pins the policy: notify unless the app is in the foreground with the
    /// conversation showing.
    nonisolated static func shouldNotify(appIsActive: Bool, conversationOnScreen: Bool) -> Bool {
        !(appIsActive && conversationOnScreen)
    }

    /// The key the demo puts the contact id under in its notifications' `userInfo`.
    nonisolated static let contactIDKey = "acmeContactId"

    /// A tap on one of this app's notifications. The conversation on screen → just open it. The
    /// app relaunched since it was posted (no live session for that contact) → hold the id until a
    /// session exists, resume it from the store, then open. Never starts a new contact.
    func openFromNotification(contactID: String) async {
        lastError = nil
        await startTask?.value
        if let session, session.isActive, session.contactID == contactID {
            onOpenConversation()
            return
        }
        // One reopen at a time: two quick taps would otherwise both resume, and the second's connect
        // would supersede the first's on the same session. A tap for another conversation in that
        // moment is dropped — fine for a demo; a real app might queue it.
        guard pendingResumeContactID == nil else { return }
        pendingResumeContactID = contactID
        defer { pendingResumeContactID = nil }
        do {
            let session = try await ensureSession()
            if session.isActive, session.contactID != contactID {
                lastError = "A different conversation is open; end it to go back to the one you were notified about."
                return
            }
            if !session.isActive { try await session.resume(contactID: contactID) }
            if mode == .live, let ls = liveSync, ls.isConfigured { ls.bind(contactID: contactID) }
            onOpenConversation()
        } catch {
            lastError = Self.describe(error)
            // A contact this session already knew has ended: open the dock on its transcript and
            // "Start new conversation". After a relaunch, a conversation that cannot be resumed (its
            // token is gone) leaves the session idle, and an idle dock is a composer with no contact
            // behind it — so the tap lands on the app as it is, and never starts a new contact.
            if case .ended = session?.state { onOpenConversation() }
        }
    }

    /// A debug affordance for the relaunch path: the session object is dropped without ending the
    /// contact (what a kill does — the token stays in the Keychain, the transcript stays in the
    /// store), then the conversation is reopened the way a tap on its notification would after a
    /// relaunch: a fresh session, resumed from the store before any network reply.
    func simulateRelaunch() async {
        await startTask?.value
        guard let session, let contactID = session.contactID, session.isActive else {
            lastError = "Start a chat first, so there is a conversation to reopen."
            return
        }
        self.session = nil                      // deinit cancels the pump; nothing is ended
        await openFromNotification(contactID: contactID)
    }

    #if DEBUG
    /// Minimal INI reader for `~/.aws/credentials`-shaped files: `[profile]` then `key = value`.
    /// Temporary credentials for the demo backend, from the launch environment.
    ///
    /// A simulator process can read a host path, so `ACME_LIVE_CREDS_FILE` keeps the values out of
    /// the scheme entirely and is tried first. A device cannot read the host filesystem, so there
    /// the values arrive directly instead — which is why this exists at all. That path is DEBUG
    /// only, lands solely in the generated (gitignored) scheme, carries credentials narrowed to
    /// `execute-api:Invoke` on this one backend, and is held in memory for the run. A production
    /// app never carries IAM credentials; its own backend vends the participant token.
    private static func seededCredentials(env: [String: String]) -> (key: String, secret: String, token: String)? {
        if let path = env["ACME_LIVE_CREDS_FILE"], !path.isEmpty,
           let fromFile = readAWSCredentials(path: path, profile: env["ACME_LIVE_PROFILE"] ?? "fm-test") {
            return fromFile
        }
        guard let key = env["ACME_LIVE_ACCESS_KEY_ID"], !key.isEmpty,
              let secret = env["ACME_LIVE_SECRET_ACCESS_KEY"], !secret.isEmpty,
              let token = env["ACME_LIVE_SESSION_TOKEN"], !token.isEmpty else { return nil }
        return (key, secret, token)
    }

    private static func readAWSCredentials(path: String, profile: String) -> (key: String, secret: String, token: String)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var inProfile = false
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inProfile = line == "[\(profile)]"; continue }
            guard inProfile, let eq = line.firstIndex(of: "=") else { continue }
            values[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        guard let k = values["aws_access_key_id"], let s = values["aws_secret_access_key"], let t = values["aws_session_token"] else { return nil }
        return (k, s, t)
    }
    #endif

    // MARK: - Assembly

    /// How long the scripted agent waits before replying. `-scriptedReplyDelayMs <n>` under
    /// `-uiTesting` stretches it, which is the only way to photograph a transient state: the
    /// default 900ms elapses while XCUITest is still typing and tapping, so a capture of the
    /// assistant-working indicator raced it and lost. A launch argument rather than a sleep in the
    /// test, so the window is deterministic instead of merely longer.
    private static var scriptedReplyDelay: Duration {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-uiTesting"), let i = args.firstIndex(of: "-scriptedReplyDelayMs"),
              i + 1 < args.endIndex, let ms = Int(args[i + 1]) else { return .milliseconds(900) }
        return .milliseconds(ms)
    }

    /// Settings → "Slow motion": the scripted agent takes three times as long over everything, so a
    /// screen recording for design review catches each transient state. Stored, so it survives a
    /// relaunch mid-recording. Never under `-uiTesting`, whose timing `-scriptedReplyDelayMs` owns.
    nonisolated static let slowMotionKey = "demo.slowMotion"
    nonisolated static let slowMotionFactor = 3.0
    nonisolated static func scriptedPace() -> Double {
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") { return 1 }
        return UserDefaults.standard.bool(forKey: slowMotionKey) ? slowMotionFactor : 1
    }

    /// Concurrent callers (`prepare` from the app, `openChat` from the dock, `openFromNotification`
    /// from a tap) await one build rather than each constructing a session across the `await` gap.
    private var sessionBuild: Task<TouchpointSession, Error>?

    private func ensureSession() async throws -> TouchpointSession {
        if let session { return session }
        if let sessionBuild { return try await sessionBuild.value }
        let build = Task { @MainActor in try await self.buildSession() }
        sessionBuild = build
        defer { sessionBuild = nil }
        return try await build.value
    }

    private func buildSession() async throws -> TouchpointSession {
        if let session { return session }
        let store = try await ensureStore()
        let backend: any TouchpointBackend
        let transport: any ContactTransport
        switch mode {
        case .offline:
            backend = OfflineBackend()
            transport = ScriptedChatTransport(replyDelay: Self.scriptedReplyDelay, pace: Self.scriptedPace)
        case .live:
            #if DEBUG
            var live = liveBackend()
            live.flow = desiredFlow
            builtFlow = live.flow
            // The showcase flow opens on a menu of everything the SDK draws — cards, the Live Sync
            // dispute (same assistant, same keys), sign-in, a form, an agent. It replaces the
            // dispute-only flow once Live Sync is configured; without it, plain chat to the queue.
            backend = live
            // Sign-in on the showcase flow's "Sign in": Cognito's hosted login comes back on the
            // app's own scheme, and the demo backend hands the result to Connect.
            transport = try ConnectChatTransport.live(regionName: liveSettings.region,
                                                      authentication: ChatAuthentication(redirectURI: Self.authenticationRedirect, relay: live))
            #else
            throw TouchpointError.invalidConfiguration("live mode is available in debug builds only")
            #endif
        }
        let broker = CredentialBroker(backend: backend, keychain: keychain)
        let session = TouchpointSession(broker: broker, store: store, transports: [.chat: transport])
        self.session = session
        session.onIncomingMessages = { [weak self] in self?.handleIncoming($0) }
        #if DEBUG
        if mode == .live {
            // Voice gets its own session (one active contact per session; chat may be mid-conversation)
            // over the same broker and store. Built lazily so a chat-only run never touches Chime.
            let voiceStore = store
            voice?.enable { @MainActor in
                let transport = VoiceTransport()
                return (TouchpointSession(broker: broker, store: voiceStore, transports: [.voice: transport]), transport)
            }
            // "Call us" creates the contact, so bind Live Sync to it the moment it exists — the
            // same handoff `openChat` does. Nobody types a contact id; the debug field in Settings
            // is only for a contact this app did not start (a call placed from the system dialer).
            // Ring-my-phone (Settings): the same contact handoff, but Connect dials the phone.
            voice?.enablePhoneCall { [weak self] in
                guard let self else { throw TouchpointError.invalidConfiguration("support went away") }
                return try await self.liveBackend()
                    .startOutboundCall(to: self.liveSettings.callbackNumber,
                                       attributes: ["screen": self.currentScreen, "app": "AcmeBank", "platform": "ios"])
            }
            voice?.usesPhone = { [weak self] in self?.liveSettings.callsPhone ?? false }
            voice?.onContactStarted = { [weak self] id in
                guard let self, self.mode == .live, let ls = self.liveSync, ls.isConfigured else { return }
                ls.bind(contactID: id)
            }
        }
        #endif
        return session
    }

    private var storeBuild: Task<ConversationStore, Error>?

    private func ensureStore() async throws -> ConversationStore {
        if let store { return store }
        if let storeBuild { return try await storeBuild.value }
        let build = Task { @MainActor in try await self.buildStore() }
        storeBuild = build
        defer { storeBuild = nil }
        return try await build.value
    }

    private func buildStore() async throws -> ConversationStore {
        if let store { return store }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let store = try await ConversationStore(containerURL: base.appending(path: "Touchpoint", directoryHint: .isDirectory), keychain: keychain)
        self.store = store
        return store
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? TouchpointError {
            switch e {
            case .invalidConfiguration(let why): return why
            case .contactNotFound: return "That conversation is no longer on this device."
            case .httpFailure(let code, _): return "The demo backend refused the request (HTTP \(code)). Its README's Troubleshooting section lists the causes."
            case .transportFailure(let why): return why
            default: return "Something went wrong (\(String(describing: e).prefix(60)))."
            }
        }
        return String(describing: type(of: error))
    }
}
