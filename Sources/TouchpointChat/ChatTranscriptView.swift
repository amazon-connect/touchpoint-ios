import QuickLook
import SwiftUI
import TouchpointCore
#if canImport(UIKit)
import UIKit
#endif

/// Header for the chat surface. The template (design-01…03) draws controls only — restart on the
/// leading edge, settings and close on the trailing one — and the bank dock adds a title. The bar
/// belongs to the SDK so the controls' labels and 44pt targets are localised and accessible without
/// each host rebuilding them.
public struct ChatHeader: Sendable, Equatable {
    /// `nil` draws no heading, as the template does.
    public var title: String?
    /// What the close control means. Web draws one glyph (`Close`); a host docking the panel may
    /// prefer "minimise", which is the same action with an honest name and a dash. A deviation, and
    /// opt-in: the default matches web.
    public var closeStyle: CloseStyle
    /// A line under the bar, centred over a divider, for words the customer should see before
    /// anything else ("This chat is recorded."). `nil` draws none. **iOS addition:** web has no
    /// such slot.
    public var notice: String?

    public enum CloseStyle: Sendable, Equatable { case minimise, close }

    public init(title: String? = nil, closeStyle: CloseStyle = .close, notice: String? = nil) {
        self.title = title
        self.closeStyle = closeStyle
        self.notice = notice
    }
}

/// Host hooks the chat surface offers controls for. **A control appears only when its hook is set**:
/// a button that does nothing is worse than no button. All run on the main actor.
/// A host row in the built-in settings panel, drawn after the SDK's own: a text button with the
/// label and no icon, prominent (ink-filled) or quiet. A tap closes the panel, then runs `action`.
/// **iOS addition:** web's settings panel takes no host rows.
public struct TouchpointSettingsRow: Sendable {
    public var label: String
    public var isProminent: Bool
    public var action: @MainActor () -> Void

    public init(label: String, isProminent: Bool = false, action: @escaping @MainActor () -> Void) {
        self.label = label
        self.isProminent = isProminent
        self.action = action
    }
}

public struct TouchpointChatActions: Sendable {
    /// Header: start a new conversation. The host owns what that means (end + start a session).
    public var onRestart: (@MainActor () async -> Void)?
    /// Header: open the host's own settings. Leave it `nil` to get the SDK's built-in panel (web's
    /// `Settings.tsx`), which the header offers whenever there is something to put in it.
    public var onSettings: (@MainActor () -> Void)?
    /// Built-in settings: end the conversation, after a confirmation (web's "End conversation").
    public var onEndConversation: (@MainActor () async -> Void)?
    /// Built-in settings: the window mode on show, and what the customer picks. Set both to offer
    /// the switch — a user-facing control web keeps in host configuration, so a named addition.
    public var windowMode: TouchpointChatWindowMode?
    public var onWindowModeChange: (@MainActor (TouchpointChatWindowMode) -> Void)?
    /// Composer: the microphone slot — enter voice mode. Shown in place of send while the draft is
    /// empty (design-01).
    public var onMicrophone: (@MainActor () -> Void)?
    /// Under an assistant response: thumbs up / down (design-01). The host records it.
    public var onFeedback: (@MainActor (Message, MessageFeedback) -> Void)?
    /// The contact ended (web's `onContactEnded`): once per end, never for the end of a contact
    /// that had already ended when the view appeared, and not for the end a restart causes.
    public var onContactEnded: (@MainActor (EndReason) -> Void)?
    /// Built-in settings: the host's own rows, after the SDK's (a call, a help page).
    public var settingsRows: [TouchpointSettingsRow] = []

    public init(onRestart: (@MainActor () async -> Void)? = nil,
                onSettings: (@MainActor () -> Void)? = nil,
                onMicrophone: (@MainActor () -> Void)? = nil,
                onFeedback: (@MainActor (Message, MessageFeedback) -> Void)? = nil,
                onEndConversation: (@MainActor () async -> Void)? = nil,
                windowMode: TouchpointChatWindowMode? = nil,
                onWindowModeChange: (@MainActor (TouchpointChatWindowMode) -> Void)? = nil) {
        self.onRestart = onRestart
        self.onSettings = onSettings
        self.onMicrophone = onMicrophone
        self.onFeedback = onFeedback
        self.onEndConversation = onEndConversation
        self.windowMode = windowMode
        self.onWindowModeChange = onWindowModeChange
    }

    /// Whether the SDK's own settings panel has anything to offer. Restart and transcript download
    /// are there too, but the header already carries restart, so neither earns a settings button
    /// alone — a host that wired only restart before the panel existed sees no new control.
    var hasBuiltInSettings: Bool { hasBuiltInSettings(headerRestartHidden: false) }

    /// As above, but with the header's restart hidden (web's `HiddenElement.HeaderRestart`) restart
    /// alone earns the panel: it is the only place left to restart from.
    func hasBuiltInSettings(headerRestartHidden: Bool) -> Bool {
        onSettings == nil && (onEndConversation != nil || (windowMode != nil && onWindowModeChange != nil)
                              || !settingsRows.isEmpty || (headerRestartHidden && onRestart != nil))
    }
}

/// The reader's verdict on an assistant response.
public enum MessageFeedback: Sendable, Equatable {
    case positive
    case negative
}

/// The transcript (design-01…03). Every dimension comes from `TranscriptMetrics`,
/// which scales with the user's text size; every colour comes from the theme environment. No
/// `UIAppearance`, no literal font sizes, no fixed heights — a fixed-height transcript is the defect
/// scaled metrics exist to prevent, and it only shows up at accessibility text sizes.
///
/// Shape, after the mobile template: the assistant speaks in plain text, full width; the customer's
/// words sit in a quiet bubble on the trailing side with a gutter; responses are separated by a
/// generous gap, messages within one by a small one; copy and feedback hang under an assistant
/// response; the composer is one pill. The whole thing sits on `TouchpointSurface`.
///
/// Conformance target is Section 508 / WCAG 2.1 AA: 44pt targets, a label on every control,
/// delivery state readable rather than purely visual, and an announcement live region that is
/// **never recreated** so VoiceOver does not lose focus when a message arrives.
@MainActor
struct ChatTranscriptView: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.touchpointChatOptions) private var options

    @Bindable private var model: ChatTranscriptModel
    private let header: ChatHeader?
    /// Host content between the transcript and the composer (suggested replies).
    private let composerAccessory: AnyView?
    /// The host's brand mark, shown above the greeting on the welcome screen (web's `brandIcon`).
    private let welcomeLogo: AnyView?
    /// Host content below the composer, on the panel's surface (an iOS addition; see
    /// `TouchpointChatView.init`'s `footer`).
    private let footer: AnyView?
    private let actions: TouchpointChatActions
    private let onSend: (String) async -> Bool
    /// Answers a choice the conversation offered. Returns whether it was queued.
    private let onChoose: (InteractiveChoice) async -> Bool
    /// Fills a slot from a modality (a carousel card, a date). Returns whether it was queued.
    private let onSlot: (String, String) async -> Bool
    /// The draft changed. Web's input calls `sendTyping` on every change (`Input.tsx:322-327`);
    /// the session throttles.
    private let onTyping: () async -> Void
    private let onRetry: (Message) async -> Bool
    private let onLoadEarlier: () async -> Void
    private let onClose: (() -> Void)?
    /// Uploads a prepared file (a copy this app owns). `nil`: the composer offers no paperclip.
    private let onAttach: ((URL) async throws -> Void)?
    /// A fresh signed link for an attachment the agent sent. `nil`: attachment pills do not open.
    private let onOpenAttachment: ((MessageAttachment) async throws -> URL)?
    /// The server's transcript for Download. `nil`: the local copy is shared.
    private let onServerTranscript: (() async -> [TranscriptEntry]?)?
    /// Sign-in (Connect's "Authenticate Customer"): the card's three actions.
    private let authenticationActions: AuthenticationActions
    /// Resolve a Connect View reference for a guide card (A7). `nil`: guide cards do not open.
    private let onDescribeView: (@MainActor (String) async -> ConnectViewDefinition?)?
    /// Submit a Connect View action back to the flow. `nil`: guide cards do not open.
    private let onSubmitView: (@MainActor (String?, String, Data) async -> Bool)?
    /// The host's instance-URL configuration for the guide renderer. `nil`: guide cards do not open.
    private let views: ConnectViewRendering?
    /// Report a renderer security rejection (a refused foreign-origin navigation) to the host (I6).
    private let onReportSecurityRejection: (@MainActor (TouchpointError) -> Void)?
    @State private var attachmentUpload: AttachmentUpload = .idle
    /// Bumped when a contact ends, so an upload still in flight then — a restart mid-upload, the
    /// same session going on to a new contact — leaves no chip or announcement on the next one.
    @State private var uploadEpoch = 0
    /// The downloaded file QuickLook is showing.
    @State private var previewURL: URL?
    @State private var draft = ""
    /// One drain task at a time, so a burst does not start several overlapping loops.
    @State private var draining = false
    /// True while the newest row is on screen. Starts true: a fresh transcript opens at the end.
    @State private var atBottom = true
    @State private var showingSettings = false
    /// One restart at a time across the header and the settings panel, which each guard only their
    /// own taps — and the panel's guard resets whenever it is reopened.
    @State private var restartInFlight = false
    @State private var endInFlight = false
    /// The end confirmation on show, and where it was asked from; `nil` when none is.
    @State private var endConfirmation: EndConfirmationSource?
    @Environment(\.touchpointChatIsPresented) private var isPresented
    @Environment(\.touchpointChatWindowMode) private var windowMode
    @Environment(\.touchpointChatIsBottomDock) private var isBottomDock
    /// Set when the keyboard is about to rise with the reader at the end; the next shrink of the
    /// transcript scrolls the newest row back into view and clears it.
    @State private var followKeyboard = false
    @State private var transcriptHeight: CGFloat = 0
    /// The panel's height, which caps the choices at web's `max-h-[40vh]`. Zero until measured.
    @State private var panelHeight: CGFloat = 0
    /// The surface's available width, which drives the tablet thresholds (TB-1/TB-2). Zero until
    /// measured — below the breakpoint, so a phone's first frame is the phone layout.
    @State private var panelWidth: CGFloat = 0

    init(model: ChatTranscriptModel,
         header: ChatHeader? = nil,
         actions: TouchpointChatActions = TouchpointChatActions(),
         onSend: @escaping (String) async -> Bool,
         onChoose: @escaping (InteractiveChoice) async -> Bool = { _ in true },
         onSlot: @escaping (String, String) async -> Bool = { _, _ in true },
         onTyping: @escaping () async -> Void = {},
         onRetry: @escaping (Message) async -> Bool = { _ in true },
         onLoadEarlier: @escaping () async -> Void = {},
         onClose: (() -> Void)? = nil,
         onAttach: ((URL) async throws -> Void)? = nil,
         onOpenAttachment: ((MessageAttachment) async throws -> URL)? = nil,
         onServerTranscript: (() async -> [TranscriptEntry]?)? = nil,
         authenticationActions: AuthenticationActions = AuthenticationActions(),
         onDescribeView: (@MainActor (String) async -> ConnectViewDefinition?)? = nil,
         onSubmitView: (@MainActor (String?, String, Data) async -> Bool)? = nil,
         views: ConnectViewRendering? = nil,
         onReportSecurityRejection: (@MainActor (TouchpointError) -> Void)? = nil,
         composerAccessory: AnyView? = nil,
         welcomeLogo: AnyView? = nil,
         footer: AnyView? = nil) {
        self.onServerTranscript = onServerTranscript
        self.authenticationActions = authenticationActions
        self.onDescribeView = onDescribeView
        self.onSubmitView = onSubmitView
        self.views = views
        self.onReportSecurityRejection = onReportSecurityRejection
        self.onAttach = onAttach
        self.onOpenAttachment = onOpenAttachment
        self.model = model
        self.header = header
        self.actions = actions
        self.onSend = onSend
        self.onChoose = onChoose
        self.onSlot = onSlot
        self.onTyping = onTyping
        self.onRetry = onRetry
        self.onLoadEarlier = onLoadEarlier
        self.onClose = onClose
        self.composerAccessory = composerAccessory
        self.welcomeLogo = welcomeLogo
        self.footer = footer
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme) }

    /// Which message rows begin a sender run — only consulted under participant info (OP-3).
    private var runStarts: Set<UUID> {
        options.showParticipantInfo ? TranscriptLayout.runStarts(in: model.items) : []
    }

    /// Which drawn messages show their time (web's `userMessageTimestamp` / `agentMessageTimestamp`).
    private var timestamped: Set<UUID> {
        ChatOptions.timestamped(model.rows.map(\.message), options: options)
    }

    /// The sender name drawn above a run under participant info: "You", the assistant's name (or
    /// "AI"), or the agent's own name from the participant set (else "Support").
    private func participantName(for message: Message) -> String {
        ChatOptions.displayName(
            role: ChatOptions.role(for: message),
            assistantName: options.assistantName,
            agentName: model.participantName(message.participantID),
            youLabel: TouchpointStrings.youSenderLabel,
            defaultAssistantLabel: TouchpointStrings.assistantSenderLabel,
            defaultAgentLabel: ChatTranscriptModel.senderName(message))
    }

    /// Host accessory content on the composer's own inset, so the two share a leading and trailing
    /// edge. The SDK owns where the accessory goes; a host that also inset it drew its choices
    /// narrower than the field below them, which read as misaligned on device.
    private func placed(_ accessory: some View) -> some View {
        accessory.padding(.horizontal, metrics.controlPadding)
    }

    /// Whether anything sits with the composer: the conversation's choices, or host content.
    private var hasAccessory: Bool { !model.choices.isEmpty || composerAccessory != nil }

    /// The choices the conversation offers, then the host's own accessory. Web draws the choices
    /// above the field (`App.tsx:941-943`) and inline under it on the welcome screen.
    @ViewBuilder
    private var accessory: some View {
        VStack(spacing: metrics.composerSpacing) {
            if !model.choices.isEmpty { choicesView(model.choices) }
            if let composerAccessory { composerAccessory }
        }
    }

    /// Web's `MessageChoices`: the group is capped at 40% of the viewport and scrolls past that
    /// (`Messages.tsx:104`, `max-h-[40vh] overflow-auto`). The cap is what lets a long set of
    /// choices — or a short set at the largest text sizes — coexist with the transcript instead of
    /// pushing it off screen. It scrolls only when it has to, so a set that fits does not bounce.
    private func choicesView(_ choices: [InteractiveChoice]) -> some View {
        let replies = TouchpointSuggestedReplies(choices.map(\.text)) { text in
            guard let choice = choices.first(where: { $0.text == text }) else { return }
            Task {
                if await onChoose(choice) == false {
                    Announcer.announce(TouchpointStrings.sendFailedAnnouncement)
                }
            }
        }
        return HeightCap(cap: panelHeight > 0 ? panelHeight * Self.choicesHeightFraction : .infinity) {
            ViewThatFits(in: .vertical) {
                replies
                ScrollView { replies }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    /// Web's `40vh`.
    static let choicesHeightFraction: CGFloat = 0.4

    /// Its content's own height, up to `cap` — CSS `max-height`. A `.frame(maxHeight:)` is not
    /// that: a flexible frame takes the whole cap whenever it is offered more, and centred a short
    /// set of choices in a band of empty space under the field.
    struct HeightCap: Layout {
        var cap: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let content = subviews.first else { return .zero }
            let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
            // Also no taller than it is offered: a short panel or a grown composer can leave the
            // choices less than the cap, and they scroll in what is left rather than drawing over
            // the composer (c53).
            return CGSize(width: proposal.width ?? natural.width,
                          height: min(natural.height, cap, proposal.height ?? .infinity))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            // Offered exactly the capped height: content that fits takes it; content that does not
            // is the `ViewThatFits` falling back to its scroll view, which fills it.
            subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                                  proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
        }
    }

    private var composer: some View {
        MessageComposer(draft: $draft, metrics: metrics, isEnabled: model.canSend && !model.composerLocked,
                        onMicrophone: actions.onMicrophone, onSend: { body in await onSend(body) },
                        lockedHint: model.composerLocked ? TouchpointStrings.authenticationLockedHint : nil,
                        offersAttachment: MessageComposer.offersAttachment(isEnabled: model.canSend, agentPresent: model.escalated,
                                                                            canAttach: onAttach != nil),
                        upload: attachmentUpload,
                        onPickAttachment: attach,
                        onDeleteAttachment: { attachmentUpload = .idle },
                        isCovered: endConfirmation != nil)
        // Only a draft that grew is typing; clearing the field after a send is not.
        .onChange(of: draft) { old, new in
            guard new.count > old.count else { return }
            Task { await onTyping() }
        }
    }

    /// The welcome screen's brand mark: the host's explicit `welcomeLogo` if given (the pre-options
    /// API), else `options.brandIcon` when `welcomeScreenLogo` is on (OP-5/web's `welcomeScreenLogo`).
    /// Both are decorative — web marks the logo `role="presentation"`.
    @ViewBuilder
    private var welcomeLogoView: some View {
        if let logo = welcomeLogo {
            logo
                .frame(width: metrics.welcomeLogoSize, height: metrics.welcomeLogoSize)
                .accessibilityHidden(true)
        } else if let brand = options.brandIcon,
                  ChatOptions.showsWelcomeLogo(hasBrandIcon: true, options: options) {
            brand
                .resizable()
                .scaledToFit()
                .frame(width: metrics.welcomeLogoSize, height: metrics.welcomeLogoSize)
                .accessibilityHidden(true)
        }
    }

    /// Web's welcome screen (`App.tsx:852-900`): the opening assistant turn centred in the panel
    /// rather than top-anchored, with 24pt between its parts, an optional 48pt host logo above it,
    /// and the greeting at `text-lg` (18pt) primary80, centred, 16pt between messages.
    ///
    /// Web hides the composer until the first assistant message arrives, and when the turn carries
    /// choices it moves the composer *up* into the centred group above them. Both are reproduced,
    /// by ``ConversationLayout`` rather than here: a panel that opens with a lone field and no
    /// greeting is the thing this screen exists to avoid. This is only the logo and the greeting.
    ///
    /// While connecting, web's animated `Loader` with the interim message as its label (c52).
    @ViewBuilder
    private func welcomeContent(_ messages: [Message]) -> some View {
        let hasGreeting = !messages.isEmpty
        // A bare scroll view, not one in a GeometryReader: ``ConversationLayout`` reads its
        // natural height to decide between inline and pinned, and centres it. It scrolls only when
        // the panel is too short for it. **Deviation:** web's `justify-center` inside an
        // overflowing flex box puts the top out of reach; here an overflowing group starts at its
        // top and scrolls.
        ScrollView {
            VStack(spacing: metrics.welcomeSpacing) {
                welcomeLogoView
                if hasGreeting {
                    VStack(spacing: metrics.welcomeMessageSpacing) {
                        ForEach(messages, id: \.clientMessageID) { message in
                            // Web runs the greeting through `SafeMarkdown` as well (`App.tsx`,
                            // welcome branch), so markdown in the opening message renders here too.
                            // Centred, which is the welcome screen's own rule, not markdown's.
                            ChatMarkdownText(message.body, metrics: metrics, tier: .t90,
                                             alignment: .center, font: metrics.greetingFont)
                                // The greeting keeps its full height rather than being compressed
                                // to one truncated line; the accessibility audit's text-clipped
                                // check caught that once.
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                } else if let interim = model.interim ?? model.statusLine {
                    // Web's welcome screen shows its `Loader` with the interim message as the
                    // label (`App.tsx:924-926`), which before the greeting arrives is
                    // "Connecting…": the 32pt loader, the label 12pt below in tier 60.
                    VStack(spacing: metrics.loaderLabelGap) {
                        TouchpointLoader(size: metrics.loaderSize, label: interim)
                        Text(interim)
                            .font(metrics.bodyFont)
                            .foregroundStyle(theme.primary(.t60))
                            .multilineTextAlignment(.center)
                            .accessibilityHidden(true)
                    }
                    .padding(metrics.composerSpacing)
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, metrics.transcriptPadding)
            .padding(.horizontal, metrics.transcriptHorizontalPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    /// Web's interim message, rendered as the transcript's last child: leading-aligned, sized to its
    /// content, shimmering (`Messages.tsx:826-830` — `text-primary-40 text-base shimmer w-fit`).
    ///
    /// Two named deviations. The ink is tier 60 rather than web's 40, which lands near 2.9:1 on its
    /// own surface — the SDK's floor is WCAG AA, and `Shimmer` owns the tiers. And the shimmer is
    /// dropped under Reduce Motion, where the text simply reads at tier 60; web animates regardless.
    ///
    /// It takes the same gap a message row would, from the one shared spacing rule, so the
    /// indicator cannot drift from the transcript it sits in.
    @ViewBuilder
    private func interimRow(_ interim: String) -> some View {
        Text(interim)
            .font(metrics.bodyFont)
            .lineSpacing(metrics.bodyLineSpacing)
            .shimmer()
            .padding(.top, TranscriptLayout.topSpacing(index: model.items.count, metrics: metrics))
            .frame(maxWidth: .infinity, alignment: .leading)
            // Deliberately one plain `Text` and no `accessibilityElement(children:)`: a single text
            // is already one element with a label, and combining it would wrap it in a container
            // that `staticTexts` queries no longer match — the trap this repo has hit before with
            // message rows. VoiceOver hears arrivals through the announcer above, not from here.
            .accessibilityIdentifier(Self.interimRowID)
            .id(Self.interimRowID)
    }

    @ViewBuilder
    private func itemView(_ item: TranscriptLayout.Item, timestamped: Set<UUID> = []) -> some View {
        switch item {
        case .message(let row):
            MessageRow(row: row, metrics: metrics, canRetry: model.canSend,
                       feedbackGiven: model.feedback[row.id],
                       onRetry: onRetry,
                       onFeedback: feedbackHandler,
                       modalitiesEnabled: model.answerableMessageID == row.message.id,
                       options: options,
                       startsRun: !options.showParticipantInfo || runStarts.contains(row.message.clientMessageID),
                       participantName: options.showParticipantInfo ? participantName(for: row.message) : "",
                       timestamp: timestamped.contains(row.message.clientMessageID)
                           ? ChatOptions.timestamp(row.message.createdAt) : nil)
        case .notice(_, let text):
            // Web: `<p className="text-center text-primary-60 text-base">` (`Messages.tsx:676-683`).
            Text(text)
                .font(metrics.bodyFont)
                .lineSpacing(metrics.bodyLineSpacing)
                .foregroundStyle(theme.primary(.t60))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)   // no vertical clip at large text sizes
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(Self.noticeRowID)
        case .error(let id, let text):
            // The connection problem is the only error row; tapping it away is Android's dismiss.
            TranscriptErrorRow(text: text, metrics: metrics,
                               onDismiss: id == TranscriptLayout.connectionProblemID ? { model.dismissConnectionProblem() } : nil)
        case .authentication(let card):
            AuthenticationCardView(card: card, metrics: metrics)
        }
    }

    static let noticeRowID = "touchpoint.transcript.notice"

    #if canImport(UIKit)
    static let keyboardWillShow = UIResponder.keyboardWillShowNotification
    static let keyboardDidShow = UIResponder.keyboardDidShowNotification
    static let keyboardWillHide = UIResponder.keyboardWillHideNotification
    #else
    // No software keyboard here.
    static let keyboardWillShow = Notification.Name("TouchpointNoKeyboard.willShow")
    static let keyboardDidShow = Notification.Name("TouchpointNoKeyboard.didShow")
    static let keyboardWillHide = Notification.Name("TouchpointNoKeyboard.willHide")
    #endif

    /// Stable id so the scroll-to-bottom effect can bring the indicator into view, as web does by
    /// including `interimMessage` in its scroll effect's dependencies (`Messages.tsx:452`).
    static let interimRowID = "touchpoint.transcript.interim"


    private var feedbackHandler: (@MainActor (Message, MessageFeedback) -> Void)? {
        guard let handler = actions.onFeedback else { return nil }
        return { [model] message, verdict in
            guard model.recordFeedback(message, verdict) else { return }
            handler(message, verdict)
        }
    }

    /// The header's settings hook: the host's, or the toggle for the built-in panel. None when the
    /// host hid the header's settings button (web's `HiddenElement.HeaderSettings`).
    private var settingsHook: (@MainActor () -> Void)? {
        guard !options.hiddenElements.contains(.headerSettings) else { return nil }
        if let host = actions.onSettings { return host }
        guard actions.hasBuiltInSettings(headerRestartHidden: options.hiddenElements.contains(.headerRestart)) else { return nil }
        return { showingSettings.toggle() }
    }

    /// The header's restart: the guarded hook, unless the host hid the header's button. The panel
    /// and "Start new conversation" keep `restartHook`.
    private var headerRestartHook: (@MainActor () async -> Void)? {
        options.hiddenElements.contains(.headerRestart) ? nil : restartHook
    }

    /// Web's added header close: with a live conversation and an end hook, ask first; otherwise
    /// just collapse. `nil` unless the host added it and gave the view an `onClose`.
    private var closeConversationHook: (() -> Void)? {
        guard options.addedElements.contains(.headerClose), let onClose else { return nil }
        return {
            if actions.onEndConversation != nil, !model.isEnded {
                endConfirmation = .header
            } else {
                onClose()
            }
        }
    }

    /// Where the end confirmation was asked from, which decides what follows a confirm: the
    /// settings panel closes (web `Settings.tsx`), the header's close collapses the chat
    /// (`Header.tsx`).
    enum EndConfirmationSource: Equatable { case settings, header }

    /// Ends the conversation after a confirm, once at a time, then leaves at once as web does
    /// (it does not wait for the end to land). Leaving happens even while an earlier end is still
    /// running: only the second end is skipped.
    private func confirmEnd(from source: EndConfirmationSource) {
        endConfirmation = nil
        if let end = actions.onEndConversation, !endInFlight {
            endInFlight = true
            Task {
                await end()
                endInFlight = false
            }
        }
        switch source {
        case .settings: showingSettings = false
        case .header: onClose?()
        }
    }

    /// The host's restart, run at most once at a time whichever control asked for it.
    private var restartHook: (@MainActor () async -> Void)? {
        guard let restart = actions.onRestart else { return nil }
        return {
            guard !restartInFlight else { return }
            restartInFlight = true
            await restart()
            restartInFlight = false
        }
    }

    /// The actions as the settings panel sees them: restart guarded here, since the panel is
    /// rebuilt (and its own guard reset) each time it reopens. The panel only asks to end; the
    /// view runs the end after the confirmation (`confirmEnd`), with its own guard.
    private var panelActions: TouchpointChatActions {
        var a = actions
        a.onRestart = restartHook
        return a
    }

    /// Whether the header bar is drawn at all (OP-4 brand icon counts).
    private var drawsHeaderBar: Bool {
        ChatHeaderBar.drawsBar(hasTitle: header?.title != nil, hasRestart: headerRestartHook != nil,
                               hasSettings: settingsHook != nil, hasClose: onClose != nil,
                               hasBrandIcon: options.brandIcon != nil)
    }

    private var headerBar: some View {
        ChatHeaderBar(header: header, metrics: metrics, onRestart: headerRestartHook,
                      onSettings: settingsHook, onClose: onClose, onCloseConversation: closeConversationHook,
                      settingsOpen: showingSettings,
                      brandIcon: options.brandIcon, windowMode: windowMode ?? actions.windowMode,
                      style: options.headerStyle)
            // Under the end confirmation the header looks as it did (it stays unveiled) but takes no
            // touch, as web's veil covers it: a tap there could close the settings the question came
            // from, or start a restart under it.
            .allowsHitTesting(endConfirmation == nil)
    }

    /// The host's notice under the header (``ChatHeader/notice``): centred, over a hairline, on
    /// the panel's own surface rather than the header's fill.
    private var hasHeaderNotice: Bool { !(header?.notice ?? "").isEmpty }

    @ViewBuilder
    private var headerNotice: some View {
        if let notice = header?.notice, !notice.isEmpty {
            VStack(spacing: 0) {
                Text(notice)
                    .font(metrics.bodyFont)
                    .foregroundStyle(theme.primary(.t90))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, metrics.transcriptHorizontalPadding)
                    .padding(.vertical, metrics.controlPaddingWide)
                Rectangle()
                    .fill(theme.primary(.t20))
                    .frame(height: metrics.hairline)
                    .accessibilityHidden(true)
            }
            .accessibilityIdentifier(Self.headerNoticeID)
        }
    }

    static let headerNoticeID = "touchpoint.header.notice"

    /// Height the content keeps clear of a floating header: the bar's button plus its own vertical
    /// padding. An approximation of the bar's measured height — the bar wraps rather than clips at
    /// large text, so the integrator confirms clearance on device.
    private var floatingHeaderInset: CGFloat { metrics.iconButtonDiameter + metrics.controlPadding * 2 }

    /// The settings panel, welcome screen, or transcript-and-composer — each capped to web's 640
    /// and centred on a wide surface (TB-1), a no-op on a phone.
    @ViewBuilder
    private var contentBody: some View {
        if showingSettings {
            // Web swaps the conversation for the panel (`App.tsx`, `isSettingsOpen`), and the
            // header's settings button takes it away again.
            ChatSettingsPanel(model: model, metrics: metrics, actions: panelActions,
                              onDone: { showingSettings = false }, serverTranscript: onServerTranscript,
                              onRequestEnd: { endConfirmation = .settings })
                .tabletContentFrame(width: panelWidth, scale: metrics.scale)
        } else {
            conversation
                // The transcript and its composer share one 640 column on a tablet (web holds each
                // to `md:max-w-content md:mx-auto`); a phone fills the surface as before.
                .tabletContentFrame(width: panelWidth, scale: metrics.scale)
        }
    }

    /// The welcome screen or the transcript, with the choices and the composer, in one
    /// ``ConversationLayout`` so the composer is the same view in both: sending the first message
    /// keeps its focus and the keyboard (c53).
    @ViewBuilder
    private var conversation: some View {
        let welcome = TranscriptLayout.showsWelcomeScreen(enabled: options.welcomeScreen, isBottomDock: isBottomDock)
            ? model.welcome : nil
        // Web hides the composer on the welcome screen until the greeting arrives.
        let showsComposer = welcome.map { !$0.isEmpty } ?? (model.foot == .composer)
        ConversationLayout(isWelcome: welcome != nil, accessorySpacing: metrics.composerSpacing,
                           welcomeGap: welcomeComposerGap) {
            Group {
                if let welcome {
                    welcomeContent(welcome)
                } else {
                    VStack(spacing: 0) {
                        transcript
                        if let status = model.statusLine {
                            statusView(status)
                        }
                    }
                }
            }
            .layoutValue(key: ConversationLayout.RoleKey.self, value: .content)
            .accessibilitySortPriority(2)
            if showsComposer, hasAccessory {
                // The transcript's bottom padding is no gap above this: following the
                // conversation scrolls the newest row's *bottom* to the viewport edge, which parks
                // that padding out of sight and left "Thinking…" touching the accessory on device.
                // The layout puts `accessorySpacing` above it instead.
                placed(accessory)
                    .layoutValue(key: ConversationLayout.RoleKey.self, value: .accessory)
            }
            if showsComposer {
                composer
                    .layoutValue(key: ConversationLayout.RoleKey.self, value: .composer)
                    // VoiceOver reads a custom layout's children in declaration order. On the
                    // welcome screen the field sits above the choices, so it is read before them;
                    // in the transcript the choices sit above it and keep the default order.
                    .accessibilitySortPriority(welcome != nil ? 1 : 0)
            } else if welcome == nil, model.foot == .startNew, let onRestart = restartHook {
                // Web's `StartNewConversationButton`, which runs the same reset as the header's
                // restart (`App.tsx:688`). Drawn only when the host wired that hook: a button
                // that cannot start anything is worse than none.
                StartNewConversationButton(metrics: metrics, onStart: onRestart)
                    .padding(metrics.controlPadding)
                    .layoutValue(key: ConversationLayout.RoleKey.self, value: .composer)
            }
        }
        // Scopes the sort priorities above to the conversation, so the header stays first.
        .accessibilityElement(children: .contain)
    }

    /// Web's greeting → input block `gap-6` (24, `App.tsx:910`), less what already sits there: the
    /// welcome group's bottom padding and the composer's own outer padding.
    private var welcomeComposerGap: CGFloat {
        max(0, metrics.welcomeSpacing - metrics.transcriptPadding - metrics.controlPadding)
    }

    var body: some View {
        // TB-2: from a wide surface the header floats over the content (web `@3xl/main:absolute`);
        // below the breakpoint it stacks above it as before. Phones take the second path untouched.
        let floats = WideLayout.headerFloats(panelWidth)
        VStack(spacing: 0) {
            if drawsHeaderBar, !floats { headerBar }
            if hasHeaderNotice {
                headerNotice
                    // Capped and centred with the content and the floating bar on a wide surface.
                    .tabletContentFrame(width: panelWidth, scale: metrics.scale)
                    .padding(.top, floats && drawsHeaderBar ? floatingHeaderInset : 0)
            }
            contentBody
                // Under a floating header the content keeps clear of the bar so the first row is
                // never hidden behind the translucent strip. **Deviation:** web lets the content
                // scroll fully under its absolute header; the SDK insets by the bar's height, which
                // the on-device audit prefers (no text hidden behind chrome).
                .padding(.top, floats && !hasHeaderNotice ? floatingHeaderInset : 0)
                // No conditional `accessibilityHidden` here: `false` on a container un-hides the
                // decorative images inside it. The card's `.isModal` keeps VoiceOver on the card.
                // Web's `EndConversationConfirm`: over the conversation or the settings panel, under
                // the header, which stays clear of the veil (it takes no touch meanwhile; see
                // `headerBar`).
                .overlay {
                    if let source = endConfirmation {
                        EndConversationConfirm(metrics: metrics, copy: ChatOptions.endConfirmCopy(options.copy),
                                               onCancel: { endConfirmation = nil },
                                               onConfirm: { confirmEnd(from: source) })
                    }
                }
            // Below everything the conversation owns, settings and welcome screen included: the
            // host's footer is about the contact (a call), not one of the panel's views.
            if let footer {
                footer.tabletContentFrame(width: panelWidth, scale: metrics.scale)
                    // Takes no touch under the end confirmation, as the header does not: web's veil
                    // covers the whole panel. (No conditional `accessibilityHidden`, which would
                    // un-hide what the host hid inside it; the card's `.isModal` holds VoiceOver.)
                    .allowsHitTesting(endConfirmation == nil)
            }
        }
        .overlay(alignment: .top) {
            if drawsHeaderBar, floats {
                headerBar
                    // The floating bar caps and centres with the content, so it sits over the 640
                    // column rather than spanning a very wide surface edge to edge.
                    .tabletContentFrame(width: panelWidth, scale: metrics.scale)
            }
        }
        // `ignoresSafeArea` so the panel reaches the home indicator: a sheet with a clear
        // presentation background would otherwise show the host through that strip.
        .background { TouchpointSurface().ignoresSafeArea() }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { panelHeight = proxy.size.height; panelWidth = proxy.size.width }
                    .onChange(of: proxy.size.height) { _, height in panelHeight = height }
                    .onChange(of: proxy.size.width) { _, width in panelWidth = width }
            }
        }
        // One live region for the whole transcript, created once: announcements update its value
        // rather than inserting a new element, so VoiceOver focus survives an inbound message.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TouchpointStrings.transcriptLabel)
        // No `accessibilityValue` for the announcement: it is posted through `UIAccessibility`,
        // which is what iOS actually speaks, and a value cleared in the same update would be a
        // container label that never says anything.
        // Drains the queue one at a time, paced so VoiceOver speaks each in turn rather than
        // dropping all but the last. Driven off the **count**, because two agent messages produce
        // the same announcement text and an unchanged value would not re-trigger the handler —
        // which would wedge the queue on its head.
        .onChange(of: model.pendingAnnouncements.count) { _, _ in
            guard !draining else { return }
            draining = true
            Task { @MainActor in
                while let announcement = model.pendingAnnouncement {
                    // A chat the host has hidden does not speak over the screen the customer is on.
                    if isPresented { Announcer.announce(announcement) }
                    try? await Task.sleep(for: .milliseconds(600))
                    model.clearAnnouncement()
                }
                draining = false
            }
        }
        // WCAG 4.1.3: a connection change is a status message, so it is announced rather than left
        // for a sighted user to notice.
        .onChange(of: model.statusLine) { _, status in
            guard let status else { return }
            Announcer.announce(status)
        }
        // An upload is the contact's: once it ends, its chip goes and a late result is dropped.
        .onChange(of: model.isEnded) { _, ended in
            guard ended else { return }
            uploadEpoch &+= 1
            attachmentUpload = .idle
            // Nothing is left to end (the agent ended it meanwhile): the question goes too.
            endConfirmation = nil
        }
        // A chat the host collapsed (the assistant acting, say) does not come back still asking.
        .onChange(of: isPresented) { _, shown in
            if !shown { endConfirmation = nil }
        }
    }

    /// Connecting and reconnecting shimmer — something is in flight. Ended is plain: nothing is.
    static func statusShimmers(_ state: ContactState) -> Bool {
        switch state {
        case .connecting, .reconnecting: true
        case .idle, .connected, .suspended, .ended: false
        }
    }

    @ViewBuilder
    private func statusView(_ status: String) -> some View {
        let text = Text(status).font(metrics.bodyFont)
        Group {
            if Self.statusShimmers(model.state) {
                text.shimmer()
            } else {
                text.foregroundStyle(theme.primary(.t60))
            }
        }
        .padding(metrics.composerSpacing)
        .frame(maxWidth: .infinity)
    }

    /// Web's `uploadFile` (`Input.tsx:166-218`): validate, upload at once, clear on success, keep
    /// the chip with the error on failure.
    private func attach(_ picked: URL) {
        guard let onAttach else { return }
        let name = picked.lastPathComponent
        let prepared: URL
        do {
            prepared = try AttachmentFiles.prepare(picked)
        } catch AttachmentFiles.PrepareError.tooBig {
            fail(name, TouchpointStrings.attachmentTooBig(megabytes: AttachmentPolicy.maxMegabytes))
            return
        } catch {
            fail(name, TouchpointStrings.attachmentGenericError)
            return
        }
        attachmentUpload = .uploading(name: name)
        let epoch = uploadEpoch
        Task {
            defer { AttachmentFiles.discard(prepared) }
            do {
                try await onAttach(prepared)
                // The contact ended meanwhile (a restart): the chip and the news belong to it.
                guard epoch == uploadEpoch else { return }
                // Delete during the upload already cleared the chip; a later pick owns it now.
                if attachmentUpload == .uploading(name: name) { attachmentUpload = .idle }
                Announcer.announce(TouchpointStrings.attachmentUploaded)
            } catch {
                guard epoch == uploadEpoch else { return }
                if attachmentUpload == .uploading(name: name) { fail(name, TouchpointStrings.attachmentUploadFailed) }
            }
        }
    }

    private func fail(_ name: String, _ message: String) {
        attachmentUpload = .failed(name: name, message: message)
        Announcer.announce(message)   // web's `role="alert"`
    }

    /// The agent's file: a fresh link, downloaded, then QuickLook — iOS's own viewer, with Save to
    /// Files and Share. **Deviation:** web hands the blob to the browser's download; iOS has no
    /// equivalent, and QuickLook is how the system opens a file it was given.
    private func openAttachment(_ attachment: MessageAttachment) {
        guard let onOpenAttachment else { return }
        Task {
            do {
                let remote = try await onOpenAttachment(attachment)
                previewURL = try await AttachmentFiles.download(remote, name: attachment.name)
            } catch {
                Announcer.announce(TouchpointStrings.attachmentOpenFailed)
            }
        }
    }

    private var attachmentActions: AttachmentActions {
        guard onOpenAttachment != nil else { return AttachmentActions() }
        return AttachmentActions(open: { attachment in openAttachment(attachment) })
    }

    private var transcript: some View {
        previewing(transcriptScroll)
            .environment(\.touchpointAttachmentActions, attachmentActions)
            .environment(\.touchpointAuthenticationActions, authenticationActions)
            .environment(\.touchpointModalityActions, ModalityActions(
                sendSlot: { id, value in
                    Task { if await onSlot(id, value) == false { Announcer.announce(TouchpointStrings.sendFailedAnnouncement) } }
                },
                sendChoice: { id in
                    Task { if await onChoose(InteractiveChoice(id: id, text: id)) == false { Announcer.announce(TouchpointStrings.sendFailedAnnouncement) } }
                }))
            .environment(\.touchpointGuideActions, GuideActions(
                describeView: onDescribeView,
                submitView: onSubmitView,
                rendering: views,
                onSecurityRejection: onReportSecurityRejection))
    }

    /// QuickLook over the transcript, and the downloaded file removed once it closes.
    private func previewing<Content: View>(_ content: Content) -> some View {
        content
            .quickLookPreview($previewURL)
            .onChange(of: previewURL) { old, _ in
                if let old { AttachmentFiles.discard(old) }
            }
    }

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if model.pagingFailed {
                        // The model's failure flag has to be visible, or a blank transcript and a
                        // failed read look identical to the reader.
                        VStack(spacing: metrics.composerSpacing) {
                            Text(TouchpointStrings.loadFailedMessage)
                                .font(metrics.bodyFont)
                                .foregroundStyle(theme.error)
                            Button { Task { await onLoadEarlier() } } label: {
                                Text(TouchpointStrings.retryButtonLabel)
                                    .font(metrics.bodyFont)
                                    .foregroundStyle(theme.primary(.t90))
                                    .frame(maxWidth: .infinity, minHeight: metrics.minimumTapTarget)
                                    .contentShape(.rect)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    if model.canLoadEarlier, !model.pagingFailed {
                        Button { Task { await onLoadEarlier() } } label: {
                            Text(TouchpointStrings.loadEarlierLabel)
                                .font(metrics.bodyFont)
                                .foregroundStyle(theme.primary(.t60))
                                .frame(maxWidth: .infinity, minHeight: metrics.minimumTapTarget)
                                .contentShape(.rect)
                        }
                    }
                    let items = model.items
                    let lastID = items.last?.id
                    let stamped = timestamped
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        // Hoisted: inlining the call in the modifier defeats the type-checker here.
                        let topGap = TranscriptLayout.topSpacing(index: index, metrics: metrics)
                        itemView(item, timestamped: stamped)
                            // One gap for every entry after the first — web's `space-y-8` spaces a
                            // notice like any response; see `TranscriptLayout.topSpacing`, which the
                            // snapshot harness shares so the two cannot drift.
                            .padding(.top, topGap)
                            .id(item.id)
                            // Whether the newest row is on screen stands in for "the reader is at
                            // the bottom". iOS 17 exposes no scroll position, and this is the
                            // property that matters: do not move someone who has scrolled up.
                            .onAppear { if item.id == lastID { atBottom = true } }
                            .onDisappear { if item.id == lastID { atBottom = false } }
                    }
                    if let interim = model.interim {
                        interimRow(interim)
                    }
                }
                .padding(.vertical, metrics.transcriptPadding)
                .padding(.horizontal, metrics.transcriptHorizontalPadding)
            }
            // Scrolling the transcript puts the keyboard away: a reader who wants to see more of the
            // conversation should not have to find a Done button first.
            .scrollDismissesKeyboard(.immediately)
            // The keyboard shrinks the transcript from below, and nothing else scrolled it: the
            // newest messages slid under the field (seen on device). Decided *before* the resize,
            // because by the time the height changes the last row may already report off screen.
            .onReceive(NotificationCenter.default.publisher(for: Self.keyboardWillShow)) { _ in
                followKeyboard = atBottom
            }
            // Only the resize this keyboard causes: a panel that moves up without shrinking would
            // otherwise leave the latch set, and a later unrelated shrink yank a reader who scrolled up.
            .onReceive(NotificationCenter.default.publisher(for: Self.keyboardDidShow)) { _ in followKeyboard = false }
            .onReceive(NotificationCenter.default.publisher(for: Self.keyboardWillHide)) { _ in followKeyboard = false }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height in
                let shrank = height < transcriptHeight
                transcriptHeight = height
                guard shrank, followKeyboard else { return }
                followKeyboard = false
                guard let last = model.items.last?.id else { return }
                let animation = Self.scrollAnimation(reduceMotion: reduceMotion)
                if model.interim != nil {
                    withAnimation(animation) { proxy.scrollTo(Self.interimRowID, anchor: .bottom) }
                } else {
                    withAnimation(animation) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
            // Anchored at the bottom: a conversation opens at its newest message, and when a row
            // grows or arrives while the reader is at the end, the end stays in view. `scrollTo`
            // below alone was not enough — it fires before a lazy row has its height, so the newest
            // reply landed half under the composer (an app's accessibility audit caught it as
            // unreadable text). On iOS 18 the anchor is scoped to the initial offset and to size
            // changes only; following *new content* stays with the `atBottom` rule below, so a reader
            // who has scrolled up is not moved by an arriving message.
            .modifier(BottomAnchored())
            // Keyed on what arrives at the *end* of the transcript. Tail identity alone would miss
            // a reply inserted before an unacknowledged echo; message count alone would yank the
            // reader back to the bottom every time they paged backwards. `interim` is in the key
            // for the reason web puts `interimMessage` in its own scroll effect's dependencies
            // (`Messages.tsx:452`): the indicator is the new last child, and an indicator nobody
            // can see does not tell anybody anything.
            .onChange(of: ScrollKey(newest: model.messages.compactMap(\.sequence).max(),
                                    pendingEchoes: model.messages.filter { $0.sequence == nil }.count,
                                    interim: model.interim,
                                    notices: model.notices.count + (model.isEnded ? 1 : 0))) { _, _ in
                // Only follow the conversation when the reader is already at the end. Someone
                // reading earlier messages keeps their place; the announcement still tells them a
                // message arrived.
                guard atBottom else { return }
                let animation = Self.scrollAnimation(reduceMotion: reduceMotion)
                // Two ids of different types, so this is a branch rather than a ternary.
                if model.interim != nil {
                    withAnimation(animation) { proxy.scrollTo(Self.interimRowID, anchor: .bottom) }
                } else if let last = model.items.last?.id {
                    withAnimation(animation) { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    /// iOS 18 can say *which* events the default anchor applies to; iOS 17 cannot, and there the
    /// anchor also follows new content — acceptable, and the `atBottom` scroll is a no-op on top.
    private struct BottomAnchored: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 18.0, macOS 15.0, *) {
                content
                    .defaultScrollAnchor(.bottom, for: .initialOffset)
                    .defaultScrollAnchor(.bottom, for: .sizeChanges)
            } else {
                content.defaultScrollAnchor(.bottom)
            }
        }
    }

    /// What a scroll reacts to: a newer server message, or one more of our own unsent messages.
    /// Deliberately *not* total count, which also grows when older pages are prepended.
    private struct ScrollKey: Equatable {
        let newest: Int?
        let pendingEchoes: Int
        let interim: String?
        /// A notice is a new last child too.
        let notices: Int
    }

    /// Reduce Motion: `nil` means jump to the newest message rather than animate to it.
    /// A function so the decision is unit-testable — `accessibilityReduceMotion` is read-only in
    /// `EnvironmentValues`, so it cannot be injected into a snapshot.
    static func scrollAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut
    }

    /// Dynamic Type → metric scale; the table lives in Core so every control shares it.
    static func scale(for size: DynamicTypeSize) -> CGFloat { TranscriptMetrics.scale(for: size) }
}

// MARK: - Header

private extension View {
    /// Web's `headerStyle` on the bar: the colour scheme first, so the controls' theme inks resolve
    /// in it (`light-dark()` inside the header), then the fill. **Deviation:** the fill stops at the
    /// bar rather than running up under the status bar, whose clock the SDK cannot restyle — dark
    /// system text on a dark brand fill would be unreadable. Web has no status bar to consider.
    @ViewBuilder
    func headerStyled(_ style: TouchpointHeaderStyle?) -> some View {
        if let style {
            Group {
                if let scheme = style.colorScheme { self.environment(\.colorScheme, scheme) } else { self }
            }
            // The view form: `.background(_ style:)` would run under the status bar by itself.
            .background { Rectangle().fill(style.background ?? .clear) }
        } else {
            self
        }
    }
}
/// Restart · [title] · spacer · settings · close, as ghost icon buttons (design-01); with a brand
/// icon, brand · [title] · spacer · restart · settings · close (web). A control is
/// drawn only when its handler exists.
@MainActor
struct ChatHeaderBar: View {
    @Environment(\.touchpointTheme) private var theme
    let header: ChatHeader?
    let metrics: TranscriptMetrics
    let onRestart: (@MainActor () async -> Void)?
    let onSettings: (@MainActor () -> Void)?
    let onClose: (() -> Void)?
    /// Web's added header close (`AddedElement.HeaderClose`): drawn after the minimise. The view
    /// owns what it does (confirm and end, or just collapse).
    var onCloseConversation: (() -> Void)?
    /// The built-in settings panel is showing: the settings button becomes "Close settings".
    var settingsOpen = false
    /// The host's brand mark (OP-4, web's header `BrandIcon`): drawn leading, decorative.
    var brandIcon: Image?
    /// The window the panel is presented in, if any: the brand is natural-width in `.mini`.
    var windowMode: TouchpointChatWindowMode?
    /// The host's header fill, title ink and colour scheme (web's `headerStyle`).
    var style: TouchpointHeaderStyle?
    @State private var restarting = false

    /// `close` is the view's `onClose` (web's collapse); `closeConversation` the added close.
    enum Control: Equatable, Hashable { case restart, settings, close, closeConversation }

    /// The controls the bar draws, in order — the body iterates this, so "no dead buttons" is a
    /// property of the view and not just of a helper.
    static func controls(hasRestart: Bool, hasSettings: Bool, hasClose: Bool,
                         hasCloseConversation: Bool = false) -> [Control] {
        var c: [Control] = []
        if hasRestart { c.append(.restart) }
        if hasSettings { c.append(.settings) }
        if hasClose { c.append(.close) }
        // Web: `showClose = addedElements.includes(HeaderClose) && collapse != null`.
        if hasCloseConversation, hasClose { c.append(.closeConversation) }
        return c
    }

    /// Whether there is a bar at all. A title-only `ChatHeader` with no handlers would otherwise
    /// draw a blank strip; a brand icon alone (OP-4) is reason enough to draw the bar, as web's is.
    static func drawsBar(hasTitle: Bool, hasRestart: Bool, hasSettings: Bool, hasClose: Bool,
                         hasBrandIcon: Bool = false) -> Bool {
        hasTitle || hasBrandIcon || !controls(hasRestart: hasRestart, hasSettings: hasSettings, hasClose: hasClose).isEmpty
    }

    private var allControls: [Control] {
        Self.controls(hasRestart: onRestart != nil, hasSettings: onSettings != nil, hasClose: onClose != nil,
                      hasCloseConversation: onCloseConversation != nil)
    }

    /// The glyph and words of the view's own close: a minimise beside the added close, as web's
    /// collapse is a `Minimize` in text mode; otherwise what the host's `closeStyle` asks for.
    static func collapseMinimises(closeStyle: ChatHeader.CloseStyle?, hasCloseConversation: Bool) -> Bool {
        hasCloseConversation || closeStyle == .minimise
    }

    /// Which controls sit before the title and which after the spacer. Web's `Header.tsx`: restart
    /// leads the bar, but with a brand icon it moves to the trailing group (`ml-auto`), so the brand
    /// owns the leading edge.
    static func placement(_ controls: [Control], hasBrand: Bool) -> (leading: [Control], trailing: [Control]) {
        if hasBrand { return ([], controls) }
        return (controls.filter { $0 == .restart }, controls.filter { $0 != .restart })
    }

    /// Web draws the brand square except in its floating window (`isBrandIconSquare={!isFloating}`,
    /// `App.tsx`), whose header has room for a wordmark: 40 tall and its own width there.
    static func brandIsSquare(windowMode: TouchpointChatWindowMode?) -> Bool { windowMode != .mini }

    /// Web 282c032: while the panel is open the settings button turns into a way back — web's `Undo`
    /// glyph, "Close settings" — and stays a ghost button rather than reading selected.
    static func settingsGlyph(open: Bool) -> TouchpointIcon { open ? .undo : .settings }
    static func settingsLabel(open: Bool) -> String {
        open ? TouchpointStrings.closeSettingsButtonLabel : TouchpointStrings.settingsButtonLabel
    }

    var body: some View {
        let placed = Self.placement(allControls, hasBrand: brandIcon != nil)
        HStack(spacing: metrics.controlPadding) {
            if let brandIcon {
                // Web's `BrandIcon` leads the header, decorative: a 40pt square, or 40 tall at its
                // own width in the mini
                // window, web's floating panel.
                if Self.brandIsSquare(windowMode: windowMode) {
                    brandIcon
                        .resizable()
                        .scaledToFit()
                        .frame(width: metrics.iconButtonDiameter, height: metrics.iconButtonDiameter)
                        .accessibilityHidden(true)
                } else {
                    // Web's `h-10 w-auto`: 40 tall at the image's own width, no wider — a square
                    // mark beside the title leaves no gap. A long wordmark yields to the controls,
                    // which keep their size, rather than pushing them off.
                    brandIcon
                        .resizable()
                        .scaledToFit()
                        .frame(height: metrics.iconButtonDiameter)
                        .accessibilityHidden(true)
                }
            }
            ForEach(placed.leading, id: \.self, content: control)
            if let title = header?.title {
                // Web's header carries no name, avatar or brand icon — only icon buttons
                // (`Header.tsx:33-108`). A title is therefore a host opt-in, and when one is given it
                // takes web's body size and weight rather than a heavier platform headline.
                Text(title)
                    .font(metrics.bodyFont)
                    .foregroundStyle(style?.foreground ?? theme.primary(.t90))
                    // A host's fixed-height container may compress this stack; the title must wrap,
                    // never clip (the audit caught a 1pt vertical clip in a host's docked panel).
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, placed.leading.isEmpty && brandIcon == nil ? metrics.controlPadding : 0)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: 0)
            ForEach(placed.trailing, id: \.self, content: control)
        }
        .padding(.horizontal, metrics.controlPadding)
        .padding(.vertical, metrics.controlPadding)
        .headerStyled(style)
    }

    @ViewBuilder
    private func control(_ control: Control) -> some View {
        switch control {
        case .restart:
            // Disabled while a restart is in flight: the hook is async, and a double tap would
            // start two conversations.
            Button {
                guard !restarting else { return }
                restarting = true
                Task {
                    await onRestart?()
                    restarting = false
                }
            } label: { TouchpointIconView(.restart) }
                .buttonStyle(TouchpointIconButtonStyle(.ghost))
                .accessibilityLabel(TouchpointStrings.restartButtonLabel)
                .disabled(restarting)
        case .settings:
            Button { onSettings?() } label: { TouchpointIconView(Self.settingsGlyph(open: settingsOpen)) }
                .buttonStyle(TouchpointIconButtonStyle(.ghost))
                .accessibilityLabel(Self.settingsLabel(open: settingsOpen))
        case .close:
            let minimises = Self.collapseMinimises(closeStyle: header?.closeStyle,
                                                   hasCloseConversation: onCloseConversation != nil)
            Button { onClose?() } label: { TouchpointIconView(minimises ? .minimize : .close) }
                .buttonStyle(TouchpointIconButtonStyle(.ghost))
                .accessibilityLabel(minimises ? TouchpointStrings.minimiseButtonLabel : TouchpointStrings.closeButtonLabel)
        case .closeConversation:
            Button { onCloseConversation?() } label: { TouchpointIconView(.close) }
                .buttonStyle(TouchpointIconButtonStyle(.ghost))
                .accessibilityLabel(TouchpointStrings.closeButtonLabel)
        }
    }
}

// MARK: - Rows

/// One message. The assistant's words are plain, full width (design-01); the customer's sit in a
/// quiet bubble on the trailing side behind a gutter. Delivery state is text for VoiceOver and a
/// glyph for sighted users, never a glyph alone.
@MainActor
struct MessageRow: View {
    @Environment(\.touchpointTheme) private var theme
    let row: TranscriptLayout.Row
    let metrics: TranscriptMetrics
    /// Retry is only offered when the contact can actually accept a message. A failed row means the
    /// previous contact ended, so without a live one the button would be decorative.
    let canRetry: Bool
    /// The verdict already given for this message, if any — owned by the model, not the row.
    let feedbackGiven: MessageFeedback?
    /// Returns whether the retry was accepted, so a failure is announced rather than swallowed.
    let onRetry: (Message) async -> Bool
    let onFeedback: (@MainActor (Message, MessageFeedback) -> Void)?
    /// Whether this message's modalities still take a pick (web's `enabled`).
    var modalitiesEnabled = false
    /// Customization options (OP-1…OP-3). The default value keeps today's rendering exactly.
    var options: TouchpointChatOptions = .default
    /// Whether this row begins its sender's run. Under participant info the avatar and name are
    /// drawn only on a run's first row (web/Android); ignored when participant info is off.
    var startsRun = true
    /// The sender's display name, resolved by the owner that holds the participant set. Only read
    /// under participant info.
    var participantName = ""
    /// The message's time, already formatted, when its side shows timestamps and this row keeps
    /// one (`ChatOptions.timestamped`); `nil` draws none.
    var timestamp: String?

    private var isOutbound: Bool { row.message.direction == .outbound }
    private var participantInfo: Bool { options.showParticipantInfo }
    /// The customer's words sit trailing, with participant info too (web 8cebb4d, `align="right"`);
    /// everyone else's lead.
    private var alignLeading: Bool { !isOutbound }

    @State private var contentHeight: CGFloat = 0
    /// Whether the message carries an accessibility action, which makes it a control.
    private var hasActions: Bool { row.showsActions || (row.isRetryable && canRetry) }
    /// How far the message's accessibility element reaches past it on each side to make 44pt.
    private var hitInset: CGFloat {
        guard hasActions, contentHeight > 0 else { return 0 }
        return max(0, (metrics.minimumTapTarget - contentHeight) / 2)
    }

    private func announceIfRefused(_ accepted: Bool) {
        if !accepted { Announcer.announce(TouchpointStrings.sendFailedAnnouncement) }
    }

    var body: some View {
        if participantInfo, isOutbound {
            userParticipantRow
        } else if participantInfo {
            participantRow
        } else {
            messageUnit
        }
    }

    /// Web 8cebb4d's `wrapUser`: the customer's message stays trailing, and the first of a run gets
    /// a trailing header row, the avatar and "You" 8pt apart, 4pt above the message (`space-y-1`).
    private var userParticipantRow: some View {
        VStack(alignment: .trailing, spacing: metrics.controlGap) {
            if startsRun {
                HStack(spacing: metrics.avatarGap) {
                    ParticipantAvatar(role: .you, metrics: metrics, options: options)
                    Text(participantName)
                        .font(metrics.bodyFont)
                        .foregroundStyle(theme.primary(.t60))
                        .fixedSize(horizontal: false, vertical: true)
                }
                // The name is already in the message's own accessibility label.
                .accessibilityHidden(true)
            }
            messageUnit
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The message without participant info: today's layout, with each side's bubble now gated by
    /// the options (OP-1/OP-2). An attachment is the pill alone — its own accessibility element, so
    /// the agent's stays a button — never combined or bubbled.
    private var messageUnit: some View {
        Group {
            if let attachment = row.message.attachment {
                attachmentRow(attachment)
            } else {
                VStack(alignment: alignLeading ? .leading : .trailing, spacing: metrics.controlGap) {
                    // A cards-only reply has no words to label: an empty element there added a gap
                    // above the card and an empty "Assistant" stop for VoiceOver.
                    if hasLabelledContent { labelledContent }
                    if row.showsActions, row.allowsFeedback, onFeedback != nil {
                        MessageActionsRow(message: row.message, metrics: metrics, allowsFeedback: row.allowsFeedback,
                                          given: feedbackGiven, onFeedback: onFeedback)
                    }
                    // Cards, carousels, date inputs, videos and a View's guide card: siblings of the
                    // combined text element, so each control stays reachable on its own.
                    if !isOutbound, let interactive = row.message.interactive,
                       !interactive.modalities.isEmpty || interactive.viewSummary != nil {
                        TranscriptModalitiesView(message: row.message, metrics: metrics, isEnabled: modalitiesEnabled)
                            // Web's response column is `space-y-2`: 8pt from the words (c30).
                            .padding(.top, hasLabelledContent ? metrics.messageSpacing - metrics.controlGap : 0)
                    }
                    // Web's agent stamp: its own line after the words and modalities, in the
                    // message's `space-y-2` column, leading (`Messages.tsx:824-826`; its docs say
                    // "aligned to the right", its markup does not — the markup wins). Read as part
                    // of the message's value, so hidden here.
                    if !isOutbound, let timestamp {
                        timestampText(timestamp)
                            .padding(.top, metrics.messageSpacing - metrics.controlGap)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: alignLeading ? .leading : .trailing)
    }

    /// Participant info (OP-3) for the assistant and agents: a 24pt avatar column 8pt from the
    /// content (web `flex gap-2`, `w-6`), the sender's name over the first row of a run. The content
    /// is the same `messageUnit`, so bubbles, delivery state, feedback and modalities behave exactly
    /// as they do without participant info.
    ///
    /// **Deviation:** web draws the interim "thinking"/"typing" line beside the answerer's avatar
    /// under participant info; the SDK keeps its single shared interim row (see `interimRow`), which
    /// is leading-aligned and already announced. A per-row avatar on a transient status line is not
    /// worth a second interim path.
    private var participantRow: some View {
        HStack(alignment: .top, spacing: metrics.avatarGap) {
            avatarColumn
            VStack(alignment: .leading, spacing: metrics.controlGap) {
                if startsRun {
                    // Web draws the name over the first message of a run; it is already in the
                    // message's own accessibility label, so it is hidden from VoiceOver here.
                    Text(participantName)
                        .font(metrics.bodyFont)
                        .foregroundStyle(theme.primary(.t60))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityHidden(true)
                }
                messageUnit
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The 24pt column: the avatar at its leading edge on a run's first row, 2pt down so it centres
    /// on the name's first line (web `mt-0.5`); empty on continuation rows, which keeps them aligned.
    private var avatarColumn: some View {
        Group {
            if startsRun {
                ParticipantAvatar(role: ChatOptions.role(for: row.message), metrics: metrics, options: options)
                    .padding(.top, metrics.avatarTopInset)
            } else {
                // Web's empty `w-6` slot has no height of its own.
                Color.clear.frame(height: 0).accessibilityHidden(true)
            }
        }
        .frame(width: metrics.avatarSize, alignment: .topLeading)
    }

    /// Whether there is anything for `labelledContent` to carry: words, or the customer's status row.
    private var hasLabelledContent: Bool {
        !row.message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || row.showsDeliveryState || (isOutbound && timestamp != nil)
    }

    /// The message's text and delivery state as one combined VoiceOver element, with its 44pt hit
    /// region (unchanged from before the options). Attachments do not pass through here.
    private var labelledContent: some View {
        messageContent
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
            // The message carries actions (copy, retry), so it is a control and owes a 44pt hit
            // region; a one-line reply is ~20pt. The element is grown and the growth taken back
            // outside it, so the region meets the minimum and the layout is untouched.
            .padding(.vertical, hitInset)
            .contentShape(.accessibility, .rect)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(TouchpointStrings.bubbleLabel(sender: accessibilitySender, body: row.message.body))
            .accessibilityValue(accessibilityValue)
            .accessibilityActions {
                if row.isRetryable, canRetry {
                    Button(TouchpointStrings.retryButtonLabel) { Task { await announceIfRefused(onRetry(row.message)) } }
                }
                if row.showsActions {
                    Button(TouchpointStrings.copyButtonLabel) { MessageActions.copy(row.message) }
                }
            }
            .padding(.vertical, -hitInset)
    }

    /// VoiceOver names the sender as the screen does: the participant-info name where it is shown,
    /// the role label otherwise (matching Android).
    private var accessibilitySender: String {
        participantInfo && !participantName.isEmpty ? participantName : ChatTranscriptModel.senderName(row.message)
    }

    /// The delivery state and the time, in the order the screen shows them.
    private var accessibilityValue: String {
        [row.showsDeliveryState ? row.message.deliveryState.accessibilityDescription : nil, timestamp]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// Web's `MessageTimestamp`: `text-xs text-primary-60`.
    private func timestampText(_ text: String) -> some View {
        Text(text)
            .font(metrics.captionFont)
            .foregroundStyle(theme.primary(.t60))
    }

    /// The attachment pill: trailing for the customer and leading for the agent, with participant
    /// info too (web `wrapFirstUser`, `justify-end`). **Deviation from Android**, which aligns every
    /// pill leading under participant info. Its time, when shown, sits under it on the pill's side,
    /// 4pt in from the edge as the text rows' status row is (web stamps an upload like any other).
    private func attachmentRow(_ attachment: MessageAttachment) -> some View {
        VStack(alignment: alignLeading ? .leading : .trailing, spacing: metrics.messageSpacing) {
            HStack(spacing: 0) {
                if isOutbound { Spacer(minLength: metrics.userGutter) }
                AttachmentPill(attachment: attachment, metrics: metrics, opens: !isOutbound)
                if !isOutbound { Spacer(minLength: 0) }
            }
            if let timestamp {
                timestampText(timestamp).padding(alignLeading ? .leading : .trailing, metrics.statusRowInset)
            }
        }
    }

    @ViewBuilder
    private var messageContent: some View {
        VStack(alignment: alignLeading ? .leading : .trailing, spacing: metrics.controlGap) {
            if isOutbound {
                userMessageView
            } else if !row.message.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                agentMessageView
            }
            if row.showsDeliveryState || (isOutbound && timestamp != nil) { deliveryRow }
        }
    }

    /// The customer's words. A bubble (web default) fills `primary10` with `text-primary` ink (web
    /// 8cebb4d, tier 90); without one (OP-1 off) the words are plain. They sit trailing behind the
    /// 48pt gutter, with or without participant info.
    @ViewBuilder
    private var userMessageView: some View {
        let text = Text(row.message.body)
            .font(metrics.bodyFont)
            .lineSpacing(metrics.bodyLineSpacing)
            .foregroundStyle(options.bubbleStyle(outbound: true)?.textColor ?? theme.primary(.t90))
        HStack(spacing: 0) {
            Spacer(minLength: metrics.userGutter)
            bubbled(text, outbound: true)
        }
    }

    /// The assistant's or agent's markdown. Plain by default (web: `agentMessageBubble` off); a
    /// bubble (OP-1 on) fills `secondary40`. Markdown keeps its own ink tiers inside the bubble; a
    /// `textColor` override applies to the plain-text sides, not to rendered markdown.
    @ViewBuilder
    private var agentMessageView: some View {
        if ChatOptions.isBubbled(outbound: false, options: options) {
            // Web's agent bubble keeps 40pt clear on its trailing side (`mr-10`).
            bubbled(ChatMarkdownText(row.message.body, metrics: metrics, tier: .t90), outbound: false)
                .padding(.trailing, metrics.agentBubbleTrailingMargin)
        } else {
            // Unbubbled, the words hug as they do in a bubble, but the row keeps its full width so
            // the message's VoiceOver frame and 44pt region span the row rather than the words.
            ChatMarkdownText(row.message.body, metrics: metrics, tier: .t90)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Wraps `content` in the bubble for its side when that side is bubbled (OP-1), applying the
    /// style overrides where set (OP-2). Overridden dimensions are the host's unscaled points times
    /// the Dynamic Type scale, so a custom bubble grows with text like the SDK's own.
    @ViewBuilder
    private func bubbled<Content: View>(_ content: Content, outbound: Bool) -> some View {
        if ChatOptions.isBubbled(outbound: outbound, options: options) {
            let style = outbound ? options.userMessageBubbleStyle : options.agentMessageBubbleStyle
            let radius = metrics.scaled(style?.cornerRadius, default: metrics.innerRadius)
            content
                .padding(.horizontal, metrics.scaled(style?.horizontalPadding, default: metrics.bubbleHorizontalPadding))
                .padding(.vertical, metrics.scaled(style?.verticalPadding, default: metrics.bubbleVerticalPadding))
                .background(style?.fill ?? defaultBubbleFill(outbound: outbound), in: TouchpointShape.rounded(radius))
                .overlay {
                    if let border = style?.border {
                        TouchpointShape.rounded(radius).strokeBorder(border.color, lineWidth: border.width)
                    }
                }
        } else {
            content
        }
    }

    /// The SDK's default bubble fills: the customer's `primary10` (today's rendering), the agent's
    /// `secondary40` (Android's `agentMessageBubble` fill).
    private func defaultBubbleFill(outbound: Bool) -> Color {
        outbound ? theme.primary(.t10) : theme.secondary(.t40)
    }

    /// Delivery state, retry and — for the customer's messages — the time: web's
    /// `flex items-center gap-3` row, status first (`Messages.tsx:274-285`).
    private var deliveryRow: some View {
        HStack(spacing: metrics.controlGap) {
            if row.showsDeliveryState {
                DeliveryStatusRow(state: row.message.deliveryState, metrics: metrics)
            }
            if row.isRetryable, canRetry {
                Button { Task { await announceIfRefused(onRetry(row.message)) } } label: {
                    Text(TouchpointStrings.retryButtonLabel)
                        .font(metrics.captionFont)
                        .foregroundStyle(theme.primary(.t80))
                        .frame(minHeight: metrics.minimumTapTarget)
                        .contentShape(.rect)
                }
            }
            if isOutbound, let timestamp {
                timestampText(timestamp)
                    .padding(.leading, row.showsDeliveryState ? metrics.controlGap * 2 : 0)   // gap-3 = 12
            }
        }
        // The web puts the status row 8pt below the bubble, not the 4pt used above it, and 4pt in
        // from the message's edge (`pr-1` trailing, `pl-1` leading).
        .padding(.top, metrics.messageSpacing - metrics.controlGap)
        .padding(alignLeading ? .leading : .trailing, metrics.statusRowInset)
    }
}

/// Web's `ParticipantAvatar` (OP-3, `Messages.tsx:160-193`): an icon on a 20pt `primary10` disc in
/// `primary60` ink for every role, or the host's `assistantIcon` at 16pt for the bot. Round or
/// square. Decorative: the sender is in the message's own accessibility label.
@MainActor
struct ParticipantAvatar: View {
    @Environment(\.touchpointTheme) private var theme
    let role: ChatOptions.AvatarRole
    let metrics: TranscriptMetrics
    let options: TouchpointChatOptions

    /// Web's `ParticipantAvatar` icons: `User`, `Escalate` for a human agent, `Bot` (`Messages.tsx`).
    private var glyph: TouchpointIcon {
        switch role {
        case .you: .user
        case .agent: .escalate
        case .bot: .bot
        }
    }

    private var image: Image? { role == .bot ? options.assistantIcon : nil }

    var body: some View {
        let size = image == nil ? metrics.avatarIconSize : metrics.avatarImageSize
        content
            .frame(width: size, height: size)
            .clipShape(shape)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            image.resizable().scaledToFill()
        } else {
            TouchpointIconView(glyph, size: metrics.avatarGlyphSize)
                .foregroundStyle(theme.primary(.t60))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(theme.primary(.t10))
        }
    }

    /// Web's square avatar is `rounded-none` (`Messages.tsx:164`; its prop comment says "inner
    /// radius", its markup does not, and the markup wins).
    private var shape: AnyShape {
        switch options.avatarShape {
        case .round: AnyShape(Circle())
        case .square: AnyShape(Rectangle())
        }
    }
}

/// Glyph plus label (web: `MessageStatusRow.tsx`). Colour says failed or read; the label says
/// everything, for VoiceOver and for anyone who does not read colour.
@MainActor
struct DeliveryStatusRow: View {
    @Environment(\.touchpointTheme) private var theme
    let state: DeliveryState
    let metrics: TranscriptMetrics

    /// Web's `MessageStatusRow`: Time, Check, CheckDouble for delivered and read (read in the
    /// success colour), Error (design QA c26).
    static func glyph(for state: DeliveryState) -> TouchpointIcon {
        switch state {
        case .sending: .time
        case .sent: .check
        case .delivered, .read: .checkDouble
        case .failed: .error
        }
    }

    static func glyphColor(for state: DeliveryState, theme: TouchpointTheme) -> Color {
        switch state {
        case .failed: theme.error
        case .read: theme.success
        case .sending, .sent, .delivered: theme.primary(.t40)
        }
    }

    var body: some View {
        HStack(spacing: metrics.controlGap) {
            TouchpointIconView(Self.glyph(for: state), size: metrics.statusGlyphSize)
                .foregroundStyle(Self.glyphColor(for: state, theme: theme))
            Text(state.accessibilityDescription)
                .font(metrics.captionFont)
                .foregroundStyle(state == .failed ? theme.error : theme.primary(.t60))
        }
    }
}

/// Copy, and thumbs up / down when the host listens and the message is the assistant's
/// (design-01): compact ghost buttons under a response. Feedback is a toggle pair — the chosen one
/// reads selected and filled, its sibling outlined but still at the AA ink floor. The verdict lives
/// in the model, so it survives the row being rebuilt as the run grows.
@MainActor
struct MessageActionsRow: View {
    let message: Message
    let metrics: TranscriptMetrics
    let allowsFeedback: Bool
    let given: MessageFeedback?
    let onFeedback: (@MainActor (Message, MessageFeedback) -> Void)?

    enum Action: Equatable, Hashable { case copy, thumbsUp, thumbsDown }

    /// What the row draws, in order. The body iterates this.
    static func actions(allowsFeedback: Bool, hasHandler: Bool) -> [Action] {
        allowsFeedback && hasHandler ? [.copy, .thumbsUp, .thumbsDown] : [.copy]
    }

    var body: some View {
        HStack(spacing: metrics.controlGap) {
            ForEach(Self.actions(allowsFeedback: allowsFeedback, hasHandler: onFeedback != nil), id: \.self) { action in
                switch action {
                case .copy:
                    Button { MessageActions.copy(message) } label: { TouchpointIconView(.copy) }
                        .buttonStyle(TouchpointIconButtonStyle(.ghost, size: .compact))
                        .accessibilityLabel(TouchpointStrings.copyButtonLabel)
                case .thumbsUp:
                    thumb(.positive, icon: .thumbUp, label: TouchpointStrings.thumbsUpLabel)
                case .thumbsDown:
                    thumb(.negative, icon: .thumbDown, label: TouchpointStrings.thumbsDownLabel)
                }
            }
        }
    }

    /// **Deviation:** web's icon set has no filled thumb, so the chosen one is told apart by the
    /// `selected` ink (tier 90 against its sibling's 60) and the selected trait, not by its shape.
    private func thumb(_ verdict: MessageFeedback, icon: TouchpointIcon, label: String) -> some View {
        Button { onFeedback?(message, verdict) } label: {
            TouchpointIconView(icon)
        }
        .buttonStyle(TouchpointIconButtonStyle(variant(for: verdict), size: .compact))
        .accessibilityLabel(label)
        .accessibilityAddTraits(given == verdict ? .isSelected : [])
    }

    private func variant(for feedback: MessageFeedback) -> TouchpointIconButtonStyle.Variant {
        guard let given else { return .ghost }
        return given == feedback ? .selected : .unselected
    }
}

/// The copy action, factored so the pasteboard and the announcer can be substituted under test.
enum MessageActions {
    static func copy(_ message: Message,
                     announce: (String) -> Void = Announcer.announce,
                     pasteboard: (String) -> Void = MessageActions.writeToPasteboard) {
        pasteboard(message.body)
        announce(TouchpointStrings.copiedAnnouncement)
    }

    static func writeToPasteboard(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

// MARK: - Composer

/// One pill (design-01): the field, and a trailing slot that is the microphone while there is
/// nothing to send and the send button once there is. Disabled when the contact cannot accept
/// messages — composing while *reconnecting* is deliberately allowed, because that is what the
/// outbox is for.
@MainActor
struct MessageComposer: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.self) private var environment
    @Binding var draft: String
    let metrics: TranscriptMetrics
    let isEnabled: Bool
    let onMicrophone: (@MainActor () -> Void)?
    /// Returns whether the message was accepted. On failure the text stays in the box: silently
    /// discarding what someone typed is the worst available outcome.
    let onSend: (String) async -> Bool
    /// Attachments (web `Input.tsx`): whether the paperclip is drawn at all, the upload in the
    /// chip above the field, and what a pick or Delete does.
    /// Shown in place of the placeholder while sign-in holds the composer. **Deviation:** web shows
    /// it over the input on hover (`App.tsx:839-846`); a touch screen has no hover.
    var lockedHint: String? = nil
    var offersAttachment = false
    var upload: AttachmentUpload = .idle
    var onPickAttachment: (URL) -> Void = { _ in }
    var onDeleteAttachment: () -> Void = {}
    /// Something sits over the composer (the end confirmation): it gives up the keyboard, which
    /// would otherwise stay up under the card.
    var isCovered = false

    enum TrailingControl: Equatable { case microphone, send }

    @State private var sending = false
    @State private var importing = false

    /// Web hides the control until a human agent is in the chat, because Amazon Connect refuses an
    /// attachment before that (`Input.tsx:75-79`) — and while the chat cannot send at all.
    nonisolated static func offersAttachment(isEnabled: Bool, agentPresent: Bool, canAttach: Bool) -> Bool {
        isEnabled && agentPresent && canAttach
    }
    @Environment(\.touchpointChatIsPresented) private var isPresented
    @FocusState private var focused: Bool

    /// Which control fills the trailing slot. The send button stays put while a message is in
    /// flight: swapping it for the microphone under the user's finger turns a double tap into
    /// "enter voice mode", and destroys the element VoiceOver is focused on.
    static func trailingControl(draftIsEmpty: Bool, hasMicrophone: Bool, isSending: Bool = false) -> TrailingControl {
        draftIsEmpty && hasMicrophone && !isSending ? .microphone : .send
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: metrics.controlPadding) {
            if upload != .idle {
                ComposerAttachmentStatus(upload: upload, metrics: metrics, onDelete: onDeleteAttachment)
            }
            field
        }
        .padding(metrics.composerShellPadding)
        // Web's shell: `bg-primary-5`, 8px padding, outer radius, 1px primary10 border
        // (`Input.tsx:225-227`). On the flat deviation the well would vanish into an opaque card,
        // so there the card's own colour carries it instead.
        .background(theme.surface == .flat ? theme.background : theme.primary(.t5), in: TouchpointShape.rounded(metrics.outerRadius))
        .overlay {
            TouchpointShape.rounded(metrics.outerRadius)
                .strokeBorder(theme.primary(theme.surface == .flat ? .t20 : .t10), lineWidth: metrics.hairline)
        }
        .padding(metrics.controlPadding)
        .fileImporter(isPresented: $importing, allowedContentTypes: AttachmentPolicy.contentTypes) { result in
            if case .success(let url) = result { onPickAttachment(url) }
        }
    }

    /// Web's paperclip: the ink-filled button while a file can be picked, a quiet disabled one
    /// while a file sits in the chip (`Input.tsx:276-302`).
    @ViewBuilder
    private var attachButton: some View {
        if upload == .idle {
            Button { importing = true } label: { TouchpointIconView(.attachment) }
                .buttonStyle(TouchpointIconButtonStyle(.main))
                .accessibilityLabel(TouchpointStrings.attachmentUploadLabel)
        } else {
            Button {} label: { TouchpointIconView(.attachment) }
                .buttonStyle(TouchpointIconButtonStyle(.ghost))
                .disabled(true)
                .accessibilityLabel(TouchpointStrings.attachmentUploadLabel)
        }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: metrics.controlGap) {
            if offersAttachment { attachButton }
            // A field's prompt never wraps — even on a vertical field, which wraps only what is typed
            // — so the longer locked hint would end "…before c…". It is drawn as wrapping text
            // behind an empty prompt instead: the stack takes the text's height and the field stays
            // in place, labelled with the hint.
            ZStack(alignment: .topLeading) {
                if let lockedHint, draft.isEmpty {
                    Text(lockedHint)
                        .font(metrics.bodyFont)
                        .foregroundStyle(theme.primary(.t60))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                }
                TextField(text: $draft, prompt: Text(lockedHint == nil ? TouchpointStrings.composerPlaceholder : "").foregroundStyle(theme.primary(.t60)), axis: .vertical) {
                    Text(lockedHint ?? TouchpointStrings.composerPlaceholder)
                }
                .textFieldStyle(.plain)
                // The label is what VoiceOver reads; an empty prompt would otherwise leave it blank.
                .accessibilityLabel(lockedHint ?? TouchpointStrings.composerPlaceholder)
                .font(metrics.bodyFont)
                .foregroundStyle(theme.primary(.t90))
                .tint(theme.accent)
                // Web's textarea autosizes to 10 rows (`Input.tsx:304-336`).
                .lineLimit(1...10)
                .focused($focused)
                // A host that hides the chat without removing it takes the keyboard with it — and only
                // the composer's: a field of the host's own keeps its focus.
                .onChange(of: isPresented) { _, presented in if !presented { focused = false } }
                .onChange(of: isCovered) { _, covered in if covered { focused = false } }
            }
            .padding(.horizontal, metrics.controlPadding)
            .padding(.vertical, metrics.controlPadding)
            .frame(minHeight: metrics.iconButtonDiameter)
            .disabled(!isEnabled)

            switch Self.trailingControl(draftIsEmpty: trimmed.isEmpty, hasMicrophone: onMicrophone != nil, isSending: sending) {
            case .microphone:
                // Web's composer has no microphone (`Input.tsx:275-350`); voice is a separate
                // modality the host enters elsewhere. A host that wires `onMicrophone` anyway gets
                // the same ghost icon button web uses for its optional controls, not a branded pill.
                Button { onMicrophone?() } label: { TouchpointIconView(.mic) }
                    .buttonStyle(TouchpointIconButtonStyle(.ghost))
                    .accessibilityLabel(TouchpointStrings.microphoneButtonLabel)
            case .send:
                Button {
                    let body = trimmed
                    draft = ""
                    sending = true
                    Task {
                        if await onSend(body) == false {
                            // Only restore into an empty box: the user may have started the next
                            // message while this one was in flight, and their text wins.
                            if draft.isEmpty { draft = body }
                            Announcer.announce(TouchpointStrings.sendFailedAnnouncement)
                        }
                        sending = false
                    }
                } label: { TouchpointIconView(.send) }
                    // Web's Send is IconButton `main`: the accent (c19, c49).
                    .buttonStyle(TouchpointIconButtonStyle(.accent))
                    .accessibilityLabel(TouchpointStrings.sendButtonLabel)
                    // Web blocks Send while an attachment uploads (`Input.tsx:98-104`).
                    .disabled(!isEnabled || trimmed.isEmpty || upload.isUploading)
            }
        }
    }
}

/// Web's `StartNewConversationButton` (`App.tsx:95-108`): a ghost `TextButton` — full width,
/// `bg-primary-10`, ink at 90, the label leading and the restart glyph trailing
/// (`ui/TextButton.tsx:63-68`). It takes the place of the field once a conversation has ended.
/// Disabled while the hook runs, since starting is async and a second tap would start two.
@MainActor
struct StartNewConversationButton: View {
    @Environment(\.touchpointTheme) private var theme
    let metrics: TranscriptMetrics
    let onStart: @MainActor () async -> Void
    @State private var starting = false

    var body: some View {
        Button {
            guard !starting else { return }
            starting = true
            Task {
                await onStart()
                starting = false
            }
        } label: {
            Text(TouchpointStrings.startNewConversationLabel)
        }
        // Web's `StartNewConversationButton` is a `main` TextButton since 55c55ec, with the Restart
        // icon (`App.tsx:100-111`).
        .buttonStyle(TouchpointTextButtonStyle(.main, icon: .restart))
        .disabled(starting)
        .accessibilityIdentifier(Self.accessibilityID)
    }

    static let accessibilityID = "touchpoint.startNewConversation"
}

/// VoiceOver announcements. UIKit-only, so the view layer stays cross-platform and the unit tier
/// compiles on macOS.
enum Announcer {
    static func announce(_ message: String) {
        #if canImport(UIKit)
        UIAccessibility.post(notification: .announcement, argument: message)
        #endif
    }
}

/// Web's `ErrorMessage` (`ErrorMessage.tsx`): `bg-error-secondary`, `p-3`, `rounded-inner`, the
/// Warning glyph at 16 in `text-error-primary`, 8 between them, and the words at `primary80`.
/// `role="alert"` there; here the model announces it, so it is not read twice. With `onDismiss`,
/// a tap dismisses it, as Android's `ErrorRow` does (web's cannot be dismissed).
@MainActor
struct TranscriptErrorRow: View {
    @Environment(\.touchpointTheme) private var theme
    let text: String
    let metrics: TranscriptMetrics
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        if let onDismiss {
            Button(action: onDismiss) { content }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(text)
                .accessibilityHint(TouchpointStrings.dismissHint)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier(Self.accessibilityID)
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(Self.accessibilityID)
        }
    }

    private var content: some View {
        HStack(spacing: metrics.controlPadding) {
            TouchpointIconView(.warning, size: metrics.iconGlyphSize)
                .foregroundStyle(theme.error)
            Text(text)
                .font(metrics.bodyFont)
                .lineSpacing(metrics.bodyLineSpacing)
                .foregroundStyle(theme.primary(.t80))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(metrics.controlPaddingWide)
        .background(theme.errorSecondary, in: TouchpointShape.rounded(metrics.innerRadius))
        .contentShape(TouchpointShape.rounded(metrics.innerRadius))
    }

    static let accessibilityID = "touchpoint.transcript.error"
}
