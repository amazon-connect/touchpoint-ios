import Observation
import SwiftUI
import TouchpointChat
import TouchpointCore
import TouchpointLiveSync
import UserNotifications

/// Session state for the demo: who is signed in and whether the support dock is open. Synthetic —
/// the sign-in models the authenticated session a real app would already have, which is what backs
/// the recommended contact-ID resolution for Live Sync later.
@MainActor
@Observable
final class AppModel {
    var isSignedIn = false
    var supportExpanded = false
    /// The chat window size the customer picked in the chat's settings; nil follows the default —
    /// half while Live Sync is driving the screens, full otherwise.
    var chatWindowPick: TouchpointChatWindowMode?
    /// Whether the chat gets out of the way when the assistant acts on the app (Settings).
    var collapseOnAssistantAction = true
    /// The voice call full screen (`TouchpointVoiceView`), opened from the rail's menu.
    var voiceFullScreen = false
    /// Demo switches for the SDK's customization options, so a device test can see them.
    /// On by default (D5): QA reviewed the chat with names, avatars and the assistant's bubble.
    var showParticipantInfo = true
    var assistantBubble = true
    var messageTimestamps = false
    /// Partner-style brand header: a dark green bar with light controls (web's `headerStyle`).
    var brandHeader = false
    /// Settings → "Partner bank look": the chat as a partner bank's web configuration draws it —
    /// its theme, font, light mode, white bordered bubbles, times, names and avatars, the dark
    /// header with no restart and an added close that asks before ending, a recording notice and
    /// its words for the end confirmation. Turning it on also turns on the switches it implies, so
    /// Settings shows what is in force.
    var partnerLook = false {
        didSet {
            // Kept across launches, for a presentation; never read or written by a UI test run.
            if !isUITesting { UserDefaults.standard.set(partnerLook, forKey: Self.partnerLookKey) }
            if partnerLook, !oldValue { turnOnPartnerLookSwitches() }
        }
    }
    static let partnerLookKey = "demo.partnerLook"

    private func turnOnPartnerLookSwitches() {
        showParticipantInfo = true
        assistantBubble = true
        messageTimestamps = true
        brandHeader = true
    }

    init() {
        if !isUITesting, UserDefaults.standard.bool(forKey: Self.partnerLookKey) {
            partnerLook = true
            turnOnPartnerLookSwitches()
        }
    }
    /// What the chat header leads with (design review's header row): nothing, Acme's wide logo
    /// alone, or the square mark beside the name.
    enum HeaderBrand: String, CaseIterable, Identifiable {
        case none, logo, logoAndName
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: "None"
            case .logo: "Logo"
            case .logoAndName: "Logo + name"
            }
        }
    }
    var headerBrand = HeaderBrand.none
    /// The assistant's avatar under participant info: the SDK's glyph, or Acme's mark.
    var assistantAvatarIsLogo = false
    var squareAvatars = false
    /// Settings → "Slow motion" (design review): stored where the scripted agent reads it.
    var slowMotion = UserDefaults.standard.bool(forKey: SupportCoordinator.slowMotionKey) {
        didSet { UserDefaults.standard.set(slowMotion, forKey: SupportCoordinator.slowMotionKey) }
    }
    var chatOptions: TouchpointChatOptions {
        var options = TouchpointChatOptions(agentMessageBubble: assistantBubble, showParticipantInfo: showParticipantInfo,
                                            assistantName: "\(PartnerBrand.bankShortName) Assistant",
                                            assistantIcon: assistantAvatarIsLogo ? AcmeBrand.avatar : nil,
                                            avatarShape: squareAvatars ? .square : .round,
                                            brandIcon: headerBrandIcon,
                                            userMessageTimestamp: messageTimestamps, agentMessageTimestamp: messageTimestamps,
                                            headerStyle: brandHeader
                                                ? TouchpointHeaderStyle(background: Palette.Partner.header,
                                                                        foreground: .white, colorScheme: .dark)
                                                : nil)
        guard partnerLook else { return options }
        // The partner's `userMessageBubbleStyle` / `agentMessageBubbleStyle`: white, a #ccc
        // hairline, black text.
        let bubble = TouchpointBubbleStyle(fill: .white, textColor: .black,
                                           border: TouchpointBubbleBorder(color: Palette.Partner.bubbleBorder))
        options.userMessageBubble = true
        options.userMessageBubbleStyle = bubble
        options.agentMessageBubbleStyle = bubble
        let brand = PartnerBrand.current
        options.assistantName = brand.assistantName
        options.assistantIcon = brand.assistantAvatar
        options.brandIcon = brand.headerMark
        options.hiddenElements = [.headerRestart]
        options.addedElements = [.headerClose]
        // The words in the partner's reference image.
        options.copy = TouchpointChatCopy(endConversationConfirm: .init(
            body: "You are about to end this conversation. This action can't be undone. You should download "
                + "your transcript from the Settings menu before you proceed if you want to keep a copy of "
                + "what was said in this chat.",
            confirm: "Yes, end conversation",
            cancel: "No, continue conversation"))
        return options
    }
    /// The chat's colours: Acme's accent, or the partner's whole theme.
    var chatTheme: TouchpointTheme { partnerLook ? Palette.Partner.chatTheme : Palette.chatTheme }
    /// The chat's theme for the dock's own chrome — the footer and the strip under the home
    /// indicator, which sit outside the SDK view — with the decorative depth turned off. The SDK
    /// view paints a surface of its own inside this one, and web draws the sheen, shade and grain
    /// once per surface, not once per nesting level.
    var dockChromeTheme: TouchpointTheme {
        var theme = chatTheme
        theme.backgroundDepthLayer = false
        return theme
    }
    /// The header's name: only with "Logo + name" — web's header carries none. The partner look
    /// names the chat beside its mark and adds the recording notice under the bar.
    var chatHeader: ChatHeader {
        if partnerLook {
            return ChatHeader(title: PartnerBrand.current.chatTitle, closeStyle: .minimise,
                              notice: "Please note that this chat is being recorded.")
        }
        return ChatHeader(title: headerBrand == .logoAndName ? PartnerBrand.bankName : nil, closeStyle: .minimise)
    }
    private var headerBrandIcon: Image? {
        switch headerBrand {
        case .none: nil
        case .logo: AcmeBrand.wideLogo
        case .logoAndName: AcmeBrand.mark
        }
    }
    func chatWindowMode(liveSyncActive: Bool) -> TouchpointChatWindowMode {
        chatWindowPick ?? (liveSyncActive ? .half : .full)
    }
    /// Whether the conversation is actually showing: the dock open, not shrunk to the mini window,
    /// and not covered by the full-screen call. A reply then needs no notification.
    var conversationOnScreen: Bool { supportExpanded && !voiceFullScreen && chatWindowPick != .mini }
    /// Navigation state the assistant can drive (Live Sync) as well as taps.
    var path = NavigationPath()
    /// A filter the assistant applied to the transaction list; nil shows everything.
    var transactionFilter: TransactionFilter?
    /// Dispute form state the assistant can fill. Submit is the customer's alone.
    var disputeOpen = false
    // Field names follow the action contract (Scripts/env/fixtures/action-contract) exactly: the
    // assistant can only send what the schema declares, so the app listens for those names and no
    // others. The web demo imports the same file for both sides; here the schemas are bundled.
    var disputeReason: String?            // not_recognized | duplicate | incorrect_amount | cancelled_service | not_received | other
    var disputeCardPossession: String?    // have_card | lost | stolen
    var disputeAuthorized: Bool?
    var disputeDetails: String?
    let accounts = DemoData.accounts()

    func account(ofKind kind: String) -> Account? {
        switch kind {
        case "credit_card": accounts.first { $0.kind == .creditCard }
        case "checking", "chequing": accounts.first { $0.kind == .chequing }
        case "savings": accounts.first { $0.kind == .savings }
        default: nil
        }
    }

    /// Where the current list screen's account comes from. The view tree sets it, so `select_transaction` acts on the account
    /// the customer is actually looking at.
    var visibleAccount: Account?

    /// Fires the accessibility announcement and haptic for an assistant-driven change (a form
    /// that fills itself silently is disorienting). Injectable so tests observe it.
    var assistantFeedback: @MainActor (String) -> Void = AssistantFeedback.announce

    // MARK: Live Sync handlers — one per declared action, typed by the contract

    func openAccount(_ p: OpenAccount) {
        let acct = p.accountId.flatMap { id in accounts.first { $0.id == id } }
            ?? account(ofKind: p.accountType ?? "credit_card")
        guard let acct else { return }
        var path = NavigationPath(); path.append(acct)
        self.path = path
        transactionFilter = nil
        assistantFeedback("Opened \(acct.nickname)")
    }

    func filterTransactions(_ p: FilterTransactions) {
        // Progressive, per the contract: "an amount alone filters by amount; a later turn can add
        // the date". Only an empty call clears.
        if p.isEmpty {
            transactionFilter = nil
            assistantFeedback("Showing all transactions")
        } else {
            transactionFilter = TransactionFilter(
                amount: p.amount ?? transactionFilter?.amount,
                date: p.date ?? transactionFilter?.date,
                merchant: p.merchant ?? transactionFilter?.merchant)
            assistantFeedback("Filtered transactions")
        }
    }

    func selectTransaction(_ p: SelectTransaction) {
        guard let acct = visibleAccount ?? account(ofKind: "credit_card") else { return }
        let tx = p.transactionId.flatMap { id in acct.transactions.first { $0.id == id } }
            ?? (transactionFilter.map { f in f.apply(to: acct.transactions) } ?? []).first
        guard let tx else { return }
        var path = NavigationPath(); path.append(acct); path.append(tx)
        self.path = path
        assistantFeedback("Selected \(tx.merchant)")
    }

    func startDispute(_ p: StartDispute) {
        disputeOpen = true
        assistantFeedback("Opened the dispute form")
    }

    func setDisputeDetails(_ p: SetDisputeDetails) {
        var changed: [String] = []
        if let r = p.reason { disputeReason = r; changed.append("reason") }
        if let c = p.cardPossession { disputeCardPossession = c; changed.append("card") }
        if let a = p.authorized { disputeAuthorized = a; changed.append("authorisation") }
        if let d = p.additionalDetails { disputeDetails = d; changed.append("details") }
        guard !changed.isEmpty else { return }
        assistantFeedback("Filled in \(changed.joined(separator: ", "))")
    }

    /// `-uiTesting`: offline mode, no animations, deterministic data. Set by the UI test's launch.
    let isUITesting = ProcessInfo.processInfo.arguments.contains("-uiTesting")

    /// The notification authorization status at launch, exposed only to the prompt's UI test
    /// (`-uiTesting -promptNotifications`), which can then tell "already answered on this
    /// simulator" (skip) from "the prompt never came" (fail). Nil in every other run.
    var notificationStatusProbe: String?

    func signIn() { isSignedIn = true }
    func signOut() { isSignedIn = false; supportExpanded = false }
}

@main
struct AcmeBankApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var support = SupportCoordinator()
    @State private var liveSync = LiveSyncCoordinator()
    @State private var voice = VoiceCoordinator()

    init() {
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            UIView.setAnimationsEnabled(false)
        }
    }

    /// `-appearance light|dark`, honoured only under `-uiTesting`. The test runner's cloned
    /// simulators do not inherit the appearance set on the original, so a design capture that must
    /// match the light mockups asks for it explicitly. `nil` leaves the system in charge.
    private var forcedScheme: ColorScheme? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-uiTesting"), let i = args.firstIndex(of: "-appearance"), i + 1 < args.endIndex else { return nil }
        switch args[i + 1] { case "light": return .light; case "dark": return .dark; default: return nil }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(support)
                .environment(liveSync)
                .environment(voice)
                .tint(Palette.brand)
                .onAppear {
                    appDelegate.support = support
                    appDelegate.model = model
                    support.liveSync = liveSync
                    support.voice = voice
                    liveSync.app = model
                    // The app knows whether its chat is showing; the SDK does not.
                    support.isConversationOnScreen = { [weak model] in model?.conversationOnScreen ?? false }
                    // A notification tap lands in the conversation; the dock should be open to show it.
                    support.onOpenConversation = { [weak model] in model?.supportExpanded = true }
                }
                // The session exists from launch so a cold-launch tap resumes immediately. The Live
                // Sync keys saved from the sign-in screen load first: the session's contact flow
                // depends on them.
                .task {
                    #if DEBUG
                    await liveSync.loadSavedKeys()
                    #endif
                    await support.prepare()
                }
                .task {
                    let args = ProcessInfo.processInfo.arguments
                    guard args.contains("-uiTesting"), args.contains("-promptNotifications") else { return }
                    let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    model.notificationStatusProbe = status == .notDetermined ? "notDetermined" : "decided"
                }
                .overlay(alignment: .topLeading) {
                    if let probe = model.notificationStatusProbe {
                        Text(probe).font(.system(size: 1)).accessibilityIdentifier("debug.notificationStatus")
                    }
                }
                // A deep link during a live call binds Live Sync to that call.
                .onOpenURL { url in liveSync.bind(url: url) }
                .preferredColorScheme(forcedScheme)
        }
    }
}

/// Notification wiring: the delegate shows the app's own "support replied" banner in the
/// foreground unless the conversation is on screen, and routes a tap back into the conversation.
/// The SDK posts no notifications — `SupportCoordinator` posts them from
/// `TouchpointSession.onIncomingMessages`; this is only glue.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Set from the scene's `onAppear`, which can come after a cold-launch tap has already been
    /// delivered — so a tap that arrives first is held and forwarded here.
    weak var support: SupportCoordinator? { didSet { forwardPendingTap() } }
    weak var model: AppModel?
    private var pendingTapContactID: String?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Before launch finishes, so a tap that launched the app is delivered here. The permission
        // prompt waits for the first chat (SupportCoordinator.openChat), where it has context.
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    private func forwardPendingTap() {
        guard let contactID = pendingTapContactID, let support else { return }
        pendingTapContactID = nil
        Task { await support.openFromNotification(contactID: contactID) }
    }

    // The delegate is main-actor-isolated by UIKit inference, but the notification centre calls
    // these from its own queue, so they are `nonisolated` and hop. (The async main-actor variants do
    // not compile under Swift 6: UNNotification and its response are not Sendable.) Only the contact
    // id string crosses.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let contactID = response.notification.request.content.userInfo[SupportCoordinator.contactIDKey] as? String
        Task { @MainActor in
            guard let contactID else { return }   // not one of ours
            // Without the demo's real sign-in, a tap lands in the app signed in. With it, only a
            // signed-in user goes straight through; otherwise the tap waits behind the sign-in screen
            // (resume needs only the stored participant token, but anything new needs the user).
            #if DEBUG
            if let support, support.requiresSignIn {
                if support.hasSignedInUser { model?.isSignedIn = true }
            } else {
                model?.isSignedIn = true
            }
            #else
            model?.isSignedIn = true
            #endif
            pendingTapContactID = contactID
            forwardPendingTap()
        }
        // Routing is fire-and-forget; the system only needs to know the response was received.
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let ours = notification.request.content.userInfo[SupportCoordinator.contactIDKey] is String
        nonisolated(unsafe) let complete = completionHandler
        Task { @MainActor in
            // The chat may have come on screen between posting and presenting: check again.
            let onScreen = model?.conversationOnScreen ?? false
            complete(ours && onScreen ? [] : [.banner, .list])
        }
    }
}

/// Accessibility announcement plus a light haptic, for assistant-driven screen changes.
enum AssistantFeedback {
    @MainActor static func announce(_ text: String) {
        UIAccessibility.post(notification: .announcement, argument: "Assistant: \(text)")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}
