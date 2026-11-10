import SwiftUI
import TouchpointCore

/// Touchpoint web's customization options (`TouchpointConfiguration`, `interface.ts`) in iOS terms,
/// with **web's defaults** — a host that sets nothing gets exactly today's rendering, and a host
/// that sets the same options as the web or Android SDK gets the same chat.
///
/// What is here is the *content* styling web groups under `TouchpointConfiguration`: message
/// bubbles, participant info, the brand icon and the welcome screen. What is **not** here, because
/// the host owns it on iOS: the window and its placement (`windowSize`, `containerStyle`), the
/// launcher (`launchIcon`), colours and radii (``TouchpointTheme``), the font face
/// (``TouchpointTheme/fontFamily`` — OP-6, a theme token as on web and Android), and the words
/// (``TouchpointStrings`` / the String Catalog — a separate host-override gap, OP-7).
///
/// Threaded through the SwiftUI environment like the theme (`.touchpointChatOptions(_:)`), and also
/// as an `options:` parameter on the public entry points. Not `Sendable`: it may carry SwiftUI
/// `Image`s, and it is only ever read on the main actor.
///
/// - `userMessageBubble` the customer's messages in a bubble (web: on — today's rendering).
/// - `agentMessageBubble` the assistant's and agents' messages in a bubble (web: off — today's
///   rendering draws them as plain text). When on, the bubble fills `secondary` at tier 40, as
///   Android's does.
/// - `userMessageBubbleStyle` / `agentMessageBubbleStyle` per-side overrides, applied only where
///   that side's bubble is on (web's `userMessageBubbleStyle` / `agentMessageBubbleStyle`).
/// - `showParticipantInfo` each run of messages under its sender's avatar and name, every message
///   aligned to the leading edge (web: off — today's rendering keeps the customer's words trailing
///   and draws no name/avatar).
/// - `assistantName` the assistant's name in participant info; `nil` is web's "AI".
/// - `assistantIcon` the assistant's avatar image in participant info; `nil` is the SDK's glyph.
/// - `avatarShape` round, or square, as web's `avatarShape`.
/// - `brandIcon` the brand mark in the header (OP-4), and above the welcome greeting with
///   `welcomeScreenLogo`. Fitted into a 40pt square in the full and half windows, as web's docked
///   and full panels draw it; 40pt tall at its own width in the mini window (web's floating panel,
///   `isBrandIconSquare={!isFloating}`), so a wide logo shows whole there. With a brand, the
///   header's restart moves to the trailing group (web).
/// - `welcomeScreen` web's immersive welcome: the opening turn centred until the customer sends
///   (web: on — today's rendering). Off renders a top-anchored transcript from the first message.
///   Never drawn in `touchpointChatWindow`'s phone bottom-half dock, which has no room to centre
///   a group in (web has no half-height panel on a phone). A host showing the chat in its own
///   half-height container (a `.medium` sheet, say) should turn it off there.
/// - `welcomeScreenLogo` the brand icon above the welcome greeting (web: on; no effect with no
///   `brandIcon` or the welcome screen off).
/// - `userMessageTimestamp` / `agentMessageTimestamp` the time under each message of that side
///   (web, both off): the hour and minute for today, else the date too, in the device locale.
///   The customer's sits beside the delivery state; the assistant's and agents' on its own line,
///   omitted when the next message of the same run shows the same time.
/// - `headerStyle` the header bar's fill, title ink and colour scheme (web's `headerStyle`).
/// - `hiddenElements` built-in parts to leave out (web's `hiddenElements`): the header's restart or
///   settings button, or the welcome screen's logo. Hiding the header's restart keeps it in the
///   settings panel and on an ended chat's "Start new conversation", as web does.
/// - `addedElements` optional parts to add (web's `addedElements`): a close button after the
///   header's minimise. It asks to end a live conversation first, then ends it and collapses.
/// - `copy` the host's own words for some of the SDK's (web's `copy`, ported for the end
///   confirmation only); `nil` parts keep the SDK's localised text.
public struct TouchpointChatOptions: Equatable, Sendable {
    public var userMessageBubble: Bool
    public var agentMessageBubble: Bool
    public var userMessageBubbleStyle: TouchpointBubbleStyle?
    public var agentMessageBubbleStyle: TouchpointBubbleStyle?
    public var showParticipantInfo: Bool
    public var assistantName: String?
    public var assistantIcon: Image?
    public var avatarShape: TouchpointAvatarShape
    public var brandIcon: Image?
    public var welcomeScreen: Bool
    public var welcomeScreenLogo: Bool
    public var userMessageTimestamp: Bool
    public var agentMessageTimestamp: Bool
    public var headerStyle: TouchpointHeaderStyle?
    public var hiddenElements: Set<TouchpointHiddenElement>
    public var addedElements: Set<TouchpointAddedElement>
    public var copy: TouchpointChatCopy

    public init(
        userMessageBubble: Bool = true,
        agentMessageBubble: Bool = false,
        userMessageBubbleStyle: TouchpointBubbleStyle? = nil,
        agentMessageBubbleStyle: TouchpointBubbleStyle? = nil,
        showParticipantInfo: Bool = false,
        assistantName: String? = nil,
        assistantIcon: Image? = nil,
        avatarShape: TouchpointAvatarShape = .round,
        brandIcon: Image? = nil,
        welcomeScreen: Bool = true,
        welcomeScreenLogo: Bool = true,
        userMessageTimestamp: Bool = false,
        agentMessageTimestamp: Bool = false,
        headerStyle: TouchpointHeaderStyle? = nil,
        hiddenElements: Set<TouchpointHiddenElement> = [],
        addedElements: Set<TouchpointAddedElement> = [],
        copy: TouchpointChatCopy = TouchpointChatCopy()
    ) {
        self.hiddenElements = hiddenElements
        self.addedElements = addedElements
        self.copy = copy
        self.userMessageBubble = userMessageBubble
        self.agentMessageBubble = agentMessageBubble
        self.userMessageBubbleStyle = userMessageBubbleStyle
        self.agentMessageBubbleStyle = agentMessageBubbleStyle
        self.showParticipantInfo = showParticipantInfo
        self.assistantName = assistantName
        self.assistantIcon = assistantIcon
        self.avatarShape = avatarShape
        self.brandIcon = brandIcon
        self.welcomeScreen = welcomeScreen
        self.welcomeScreenLogo = welcomeScreenLogo
        self.userMessageTimestamp = userMessageTimestamp
        self.agentMessageTimestamp = agentMessageTimestamp
        self.headerStyle = headerStyle
    }

    /// Web's defaults — today's rendering.
    public static let `default` = TouchpointChatOptions()

    /// The style to apply to a bubble on `outbound`'s side, if that side is bubbled; `nil` when the
    /// side draws no bubble, so a style set for a side that is off has no effect (web gates the
    /// style on the bubble, `interface.ts:442,461`).
    func bubbleStyle(outbound: Bool) -> TouchpointBubbleStyle? {
        guard ChatOptions.isBubbled(outbound: outbound, options: self) else { return nil }
        return outbound ? userMessageBubbleStyle : agentMessageBubbleStyle
    }
}

/// A built-in part a host can leave out (web's `HiddenElement`, `interface.ts`).
public enum TouchpointHiddenElement: String, Sendable, Hashable, CaseIterable {
    /// The header's restart button. Restart stays in the settings panel.
    case headerRestart = "header.restart"
    /// The header's settings button, and with it the built-in settings panel.
    case headerSettings = "header.settings"
    /// The brand logo above the welcome greeting (the same as `welcomeScreenLogo: false`).
    case welcomeScreenLogo = "welcomescreen.logo"
}

/// An optional part a host can add (web's `AddedElement`, `interface.ts`).
public enum TouchpointAddedElement: String, Sendable, Hashable, CaseIterable {
    /// A close button after the header's minimise. With a live conversation and an
    /// `onEndConversation` hook it asks first, then ends the conversation and collapses the chat;
    /// otherwise it only collapses (web `Header.tsx`). Needs the view's `onClose`.
    case headerClose = "header.close"
}

/// The host's words for some of the SDK's (web's `copy`, a `Partial<Copy>`). Only the end
/// confirmation is overridable so far; a `nil` part keeps the SDK's localised text. The host owns
/// the translation of what it sets.
public struct TouchpointChatCopy: Sendable, Equatable {
    /// Web's `copy.endConversationConfirm`.
    public struct EndConversationConfirm: Sendable, Equatable {
        public var title: String?
        public var body: String?
        public var confirm: String?
        public var cancel: String?

        public init(title: String? = nil, body: String? = nil, confirm: String? = nil, cancel: String? = nil) {
            self.title = title
            self.body = body
            self.confirm = confirm
            self.cancel = cancel
        }
    }

    public var endConversationConfirm: EndConversationConfirm

    public init(endConversationConfirm: EndConversationConfirm = EndConversationConfirm()) {
        self.endConversationConfirm = endConversationConfirm
    }
}

/// Participant info's avatar shape (web's `avatarShape`): fully round, or a lightly-rounded square.
public enum TouchpointAvatarShape: Sendable, Equatable {
    case round
    case square
}

/// A border on a message bubble (web's `CustomStyle.border`), as a colour and a width.
public struct TouchpointBubbleBorder: Sendable, Equatable {
    public var color: Color
    public var width: CGFloat

    public init(color: Color, width: CGFloat = 1) {
        self.color = color
        self.width = width
    }
}

/// Web's bubble style (`CustomStyle` on a message bubble), typed to what a bubble can carry. A `nil`
/// part keeps the SDK's default for that part — fill, text colour, corner radius, the two paddings
/// and the border are each overridable on their own (web's `userMessageBubbleStyle` /
/// `agentMessageBubbleStyle`). Dimensions are **unscaled** point values the host states once; the
/// SDK multiplies them by the current Dynamic Type scale, as it does its own, so an overridden
/// bubble grows with text like the rest of the transcript.
public struct TouchpointBubbleStyle: Sendable, Equatable {
    public var fill: Color?
    public var textColor: Color?
    public var cornerRadius: CGFloat?
    public var horizontalPadding: CGFloat?
    public var verticalPadding: CGFloat?
    public var border: TouchpointBubbleBorder?

    public init(
        fill: Color? = nil,
        textColor: Color? = nil,
        cornerRadius: CGFloat? = nil,
        horizontalPadding: CGFloat? = nil,
        verticalPadding: CGFloat? = nil,
        border: TouchpointBubbleBorder? = nil
    ) {
        self.fill = fill
        self.textColor = textColor
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.border = border
    }
}

/// Web's `headerStyle` (a `CustomStyle` on the header container, `Layout.tsx:35-46`), typed to
/// what a header bar can carry:
/// - `background` fills the bar (web `backgroundColor`).
/// - `foreground` is the title's ink (web `color`, which only reaches text that inherits it; web's
///   icon buttons carry their own ink classes, so here too the controls keep the theme's inks).
/// - `colorScheme` resolves the bar's theme colours as light or dark (web `colorScheme`, which
///   flips the `light-dark()` theme values inside the header). This is how a dark brand bar gets
///   white controls over a light panel.
///
/// **Deviation (web wins on behaviour):** web's docs say "only available in floating mode", but
/// `App.tsx:1056` applies it in every window size, and so does this.
public struct TouchpointHeaderStyle: Sendable, Equatable {
    public var background: Color?
    public var foreground: Color?
    public var colorScheme: ColorScheme?

    public init(background: Color? = nil, foreground: Color? = nil, colorScheme: ColorScheme? = nil) {
        self.background = background
        self.foreground = foreground
        self.colorScheme = colorScheme
    }
}

// MARK: - Pure decisions (OP-1…OP-5)

/// View-free decisions for the customization options, so each is testable without rendering. The
/// SwiftUI layer applies colours and images; everything a unit test can pin lives here.
enum ChatOptions {
    /// Whose avatar a message carries under participant info. Web's `you` / `agent` / `bot`: the
    /// customer's own, any human party (agent or supervisor — `isHuman`), else the bot.
    enum AvatarRole: Equatable { case you, agent, bot }

    static func role(for message: Message) -> AvatarRole {
        if message.direction == .outbound { return .you }
        return message.participantRole.isHuman ? .agent : .bot
    }

    /// The sender's display name under participant info. Labels are injected, so the choice is
    /// testable without the string catalog: web uses "You", the assistant's name (or "AI"), and the
    /// agent's own name where the participant set carries one (else "Agent").
    static func displayName(role: AvatarRole, assistantName: String?, agentName: String?,
                            youLabel: String, defaultAssistantLabel: String, defaultAgentLabel: String) -> String {
        switch role {
        case .you: youLabel
        case .agent: agentName ?? defaultAgentLabel
        case .bot: (assistantName?.isEmpty == false ? assistantName : nil) ?? defaultAssistantLabel
        }
    }

    /// Whether a message's bubble is drawn, per side (OP-1). The customer's side is
    /// `userMessageBubble`; every inbound message (assistant or human agent) is `agentMessageBubble`.
    static func isBubbled(outbound: Bool, options: TouchpointChatOptions) -> Bool {
        outbound ? options.userMessageBubble : options.agentMessageBubble
    }

    /// Web's `formatTimestamp` (`utils/formatTimestamp.ts`): the hour and minute for a message from
    /// today, otherwise the abbreviated month and day too, plus the year when it is not this year,
    /// as "<date>, <time>". The device locale, as web uses the browser's.
    static func timestamp(_ date: Date, now: Date = Date(), calendar: Calendar = .current,
                          locale: Locale = .current) -> String {
        let time = date.formatted(Date.FormatStyle(locale: locale, calendar: calendar).hour().minute())
        if calendar.isDate(date, inSameDayAs: now) { return time }
        var day = Date.FormatStyle(locale: locale, calendar: calendar).month(.abbreviated).day()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { day = day.year() }
        return "\(date.formatted(day)), \(time)"
    }

    /// Whether a message shows its time (web `Messages.tsx:638,664,719-728`). The customer's: every
    /// message, when `userMessageTimestamp` is on. The other side's, when `agentMessageTimestamp`
    /// is on, except where the next message is from the same sender and shows the same text — web
    /// keeps only the last of a run's identical stamps.
    ///
    /// `next` is the next **drawn message**. Web's next response can also be a notice, which
    /// breaks the run; the SDK's notices are not messages, so a notice between two same-minute
    /// replies does not keep the first one's stamp. A named simplification.
    static func showsTimestamp(_ message: Message, next: Message?, options: TouchpointChatOptions,
                               format: (Date) -> String = { timestamp($0) }) -> Bool {
        if message.direction == .outbound { return options.userMessageTimestamp }
        guard options.agentMessageTimestamp else { return false }
        guard let next, next.direction == .inbound, role(for: next) == role(for: message) else { return true }
        return format(next.createdAt) != format(message.createdAt)
    }

    /// The drawn messages that show their time, by client id — each judged against the next drawn
    /// message, as web judges each response against the next.
    static func timestamped(_ messages: [Message], options: TouchpointChatOptions,
                            format: (Date) -> String = { timestamp($0) }) -> Set<UUID> {
        guard options.userMessageTimestamp || options.agentMessageTimestamp else { return [] }
        var shown = Set<UUID>()
        for i in messages.indices {
            let next = i + 1 < messages.count ? messages[i + 1] : nil
            if showsTimestamp(messages[i], next: next, options: options, format: format) {
                shown.insert(messages[i].clientMessageID)
            }
        }
        return shown
    }

    /// Whether the immersive welcome screen is used (OP-5): the model offered one (opening turn,
    /// still the whole conversation) **and** the host left the switch on. Off → the ordinary
    /// top-anchored transcript, which is exactly what the model's non-welcome branch already draws.
    static func usesWelcome(modelWelcome: [Message]?, enabled: Bool) -> Bool {
        enabled && modelWelcome != nil
    }

    /// Whether the brand mark is drawn above the welcome greeting (web's `welcomeScreenLogo`): a
    /// brand icon is set, the switch is on, and the welcome screen is itself on (web: no effect
    /// otherwise, `interface.ts:494`).
    static func showsWelcomeLogo(hasBrandIcon: Bool, options: TouchpointChatOptions) -> Bool {
        hasBrandIcon && options.welcomeScreenLogo && options.welcomeScreen
            && !options.hiddenElements.contains(.welcomeScreenLogo)
    }

    /// The end confirmation's words: the host's where it set them, else the SDK's localised ones.
    static func endConfirmCopy(_ copy: TouchpointChatCopy) -> (title: String, body: String, confirm: String, cancel: String) {
        let c = copy.endConversationConfirm
        return (c.title ?? TouchpointStrings.settingsEndConfirmTitle,
                c.body ?? TouchpointStrings.settingsEndConfirmBody,
                c.confirm ?? TouchpointStrings.settingsEndLabel,
                c.cancel ?? TouchpointStrings.settingsCancelLabel)
    }
}

extension TranscriptMetrics {
    /// Scale a host-supplied override point value by the Dynamic Type scale, or fall back to the
    /// SDK's already-scaled default (OP-2). Keeps an overridden bubble growing with text.
    func scaled(_ override: CGFloat?, default fallback: CGFloat) -> CGFloat {
        override.map { $0 * scale } ?? fallback
    }
}

extension TranscriptLayout {
    /// Identity of a sender for participant-info runs: same side **and** same role **and** same
    /// participant, so two agents, or an agent and a supervisor, each start their own run.
    struct SenderKey: Equatable {
        let direction: Direction
        let role: ParticipantRole
        let participantID: String?

        init(_ m: Message) {
            direction = m.direction
            role = m.participantRole
            participantID = m.participantID
        }
    }

    /// The message ids that begin a sender run — where participant info draws the avatar and name.
    /// A run breaks on a change of sender and on any non-message item between two messages (a
    /// notice or the sign-in card), as a response breaks it on web and Android: the next sender is
    /// named again even when it is the same party.
    static func runStarts(in items: [Item]) -> Set<UUID> {
        var starts: Set<UUID> = []
        var previous: SenderKey?
        for item in items {
            guard case .message(let row) = item else { previous = nil; continue }
            let key = SenderKey(row.message)
            if previous != key { starts.insert(row.message.clientMessageID) }
            previous = key
        }
        return starts
    }
}

// MARK: - Environment

private struct TouchpointChatOptionsKey: EnvironmentKey {
    static let defaultValue = TouchpointChatOptions.default
}

public extension EnvironmentValues {
    /// The chat customization options in force for this subtree. Defaults to web's defaults, which
    /// are today's rendering.
    var touchpointChatOptions: TouchpointChatOptions {
        get { self[TouchpointChatOptionsKey.self] }
        set { self[TouchpointChatOptionsKey.self] = newValue }
    }
}

public extension View {
    /// Apply Touchpoint chat customization options to this subtree, the way `.touchpointTheme`
    /// applies colours. Scoped to the view hierarchy it is attached to.
    func touchpointChatOptions(_ options: TouchpointChatOptions) -> some View {
        environment(\.touchpointChatOptions, options)
    }
}
