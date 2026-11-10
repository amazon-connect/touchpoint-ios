import Foundation
import SwiftUI
import TouchpointCore

/// The host's entry point to chat UI.
///
/// ```swift
/// ContentView()
///     .touchpointChat(session: session, isPresented: $showChat, presentation: .sheet(detents: [.large]))
/// ```
///
/// Only the two presentation cases the SDK builds exist; see `TouchpointPresentation`.
@MainActor
public extension View {
    func touchpointChat(
        session: TouchpointSession,
        isPresented: Binding<Bool>,
        presentation: TouchpointPresentation = .sheet(detents: [.large]),
        theme: TouchpointTheme = .default,
        header: ChatHeader? = nil,
        actions: TouchpointChatActions = TouchpointChatActions(),
        options: TouchpointChatOptions = .default,
        views: ConnectViewRendering? = nil
    ) -> some View {
        modifier(TouchpointChatModifier(session: session, isPresented: isPresented, presentation: presentation,
                                        theme: theme, header: header, actions: actions, options: options, views: views))
    }
}

/// The chat surface on its own, for `.embedded`: the host places it in whatever container it likes.
@MainActor
public struct TouchpointChatView: View {
    private let session: TouchpointSession
    private let theme: TouchpointTheme
    private let options: TouchpointChatOptions
    @State private var model = ChatTranscriptModel()
    /// Which session the model currently holds, so re-appearing does not discard loaded pages while
    /// a genuine session swap still clears them.
    @State private var boundSession: ObjectIdentifier?

    private let header: ChatHeader?
    private let actions: TouchpointChatActions
    private let onClose: (() -> Void)?
    private let composerAccessory: AnyView?
    private let welcomeLogo: AnyView?
    private let footer: AnyView?
    /// The host's Connect View / guide renderer configuration. `nil`: guide cards do not open.
    private let views: ConnectViewRendering?
    @State private var endReporter = ContactEndReporter(endedAtSubscribe: nil)

    /// - Parameters:
    ///   - header: Title bar drawn by the SDK. `nil` draws a bar only if there is a control to put in
    ///     it (close, restart, settings); the template has no title.
    ///   - actions: Host hooks; each adds exactly one control (see `TouchpointChatActions`).
    ///   - onClose: Called by the header's close control. The host decides what closing means —
    ///     collapsing a dock, dismissing a sheet — because only it owns the container.
    ///   - composerAccessory: Host content drawn with the composer, after any choices the
    ///     conversation itself offers — those the SDK draws on its own, from the messages. The host
    ///     owns the content; the SDK owns the place it goes, including its inset: the accessory is
    ///     laid on the composer's edges, so pass it unpadded.
    public init(session: TouchpointSession, theme: TouchpointTheme = .default,
                header: ChatHeader? = nil, actions: TouchpointChatActions = TouchpointChatActions(),
                onClose: (() -> Void)? = nil, options: TouchpointChatOptions = .default,
                views: ConnectViewRendering? = nil) {
        self.init(session: session, theme: theme, header: header, actions: actions, onClose: onClose,
                  options: options, views: views, composerAccessory: Optional<EmptyView>.none, welcomeLogo: Optional<EmptyView>.none)
    }

    ///   - welcomeLogo: The host's brand mark, drawn above the greeting on the welcome screen —
    ///     web's `brandIcon` with `welcomeScreenLogo` on. Omit it and the greeting stands alone.
    ///   - options: Customization options (``TouchpointChatOptions``) — bubbles, participant info,
    ///     the brand icon, the welcome screen. Defaults to web's defaults (today's rendering).
    ///   - footer: Host content below the composer, on the chat's own surface — call controls
    ///     during a voice call, say. **iOS addition:** web has no such slot (chat and voice never
    ///     share one web instance). Drawn on the SDK surface so it is part of the same tray rather
    ///     than a second surface with a seam under the composer.
    public init<Accessory: View, Logo: View, Footer: View>(session: TouchpointSession, theme: TouchpointTheme = .default,
                                             header: ChatHeader? = nil, actions: TouchpointChatActions = TouchpointChatActions(),
                                             onClose: (() -> Void)? = nil,
                                             options: TouchpointChatOptions = .default,
                                             views: ConnectViewRendering? = nil,
                                             composerAccessory: Accessory?,
                                             welcomeLogo: Logo? = Optional<EmptyView>.none,
                                             footer: Footer? = Optional<EmptyView>.none) {
        self.session = session
        self.theme = theme
        self.options = options
        self.header = header
        self.actions = actions
        self.onClose = onClose
        self.views = views
        self.composerAccessory = composerAccessory.map { AnyView($0) }
        self.welcomeLogo = welcomeLogo.map { AnyView($0) }
        self.footer = footer.map { AnyView($0) }
    }

    /// The host's actions with restart wrapped, so the end a restart causes is not reported as the
    /// contact ending (CV-2).
    private var wrappedActions: TouchpointChatActions {
        var wrapped = actions
        if let restart = actions.onRestart {
            wrapped.onRestart = {
                endReporter.restarting = true
                await restart()
                endReporter.restarting = false
            }
        }
        return wrapped
    }

    public var body: some View {
        ChatTranscriptView(
            model: model,
            header: header,
            actions: wrappedActions,
            onSend: { body in (try? await session.send(body)) != nil },
            onChoose: { choice in (try? await session.sendChoice(choice)) != nil },
            onSlot: { id, value in (try? await session.sendSlot(id: id, value: value)) != nil },
            onTyping: { await session.sendTyping() },
            onRetry: { message in (try? await session.resend(message)) != nil },
            onLoadEarlier: { await loadEarlier() },
            onClose: onClose,
            // Web offers attachments whenever an agent is in the chat (`App.tsx:830, 917`); so does
            // the SDK. The instance needs attachment storage enabled, or the upload fails visibly.
            onAttach: { try await session.sendAttachment(fileURL: $0) },
            onOpenAttachment: { try await session.attachmentURL(id: $0.id) },
            onServerTranscript: { try? await session.serverTranscript() },
            authenticationActions: AuthenticationActions(
                begin: { try await session.beginAuthentication() },
                complete: { try await session.completeAuthentication(callbackURL: $0) },
                cancel: { await session.cancelAuthentication() }),
            onDescribeView: { try? await session.describeView(viewToken: $0) },
            onSubmitView: { viewName, action, data in
                (try? await session.sendViewResponse(viewName: viewName, action: action, data: data)) != nil
            },
            views: views,
            onReportSecurityRejection: { session.reportSecurityRejection($0) },
            composerAccessory: composerAccessory,
            welcomeLogo: welcomeLogo,
            footer: footer
        )
        .touchpointTheme(theme)
        .touchpointChatOptions(options)
        // Structured: the subscription lives exactly as long as the view is on screen, and the
        // session fans events out per subscriber, so going away does not silence anyone else.
        // Keyed on the session: SwiftUI would otherwise keep both the `@State` model and the
        // running subscription when a host swaps in a different session at the same position,
        // showing one contact's transcript under another.
        .task(id: ObjectIdentifier(session)) {
            if boundSession != ObjectIdentifier(session) {
                model.reset()
                boundSession = ObjectIdentifier(session)
            }
            // Subscribe *before* loading the page: the stream registers on creation and buffers, so
            // nothing emitted during the load is lost between the two. A contact already over when
            // the view appears comes back in the replay; that end is not news.
            endReporter = ContactEndReporter(endedAtSubscribe: session.isActive ? nil : session.contactID)
            let events = session.events
            await loadFirstPage()
            for await event in events {
                // The view can be on screen before the session has a contact — a host resuming a
                // stored conversation after a relaunch does so into a session the dock already
                // shows. The first page
                // it loaded was then empty and belonged to no contact; load it again for the one
                // the session just adopted, so stored history appears before the network answers.
                // Any live state, not only `.connecting`: with a fast transport the replay this
                // subscriber receives may already say `.connected`.
                if case .stateChanged = event, session.isActive, loadedContactID != session.contactID {
                    await loadFirstPage(force: true)
                }
                model.ingest(event)
                if case .contactEnded(let reason) = event, endReporter.shouldReport(contactID: session.contactID) {
                    actions.onContactEnded?(reason)
                }
            }
        }
    }

    /// Which contact the first page was loaded for, so adopting a different one reloads it.
    @State private var loadedContactID: String?

    private func loadFirstPage(force: Bool = false) async {
        guard force || !model.initialLoaded else { return }   // re-appearing must not discard loaded pages
        // The session can be swapped while this fetch is in flight; `.task(id:)` cancels the task
        // but `earlierTranscript` is not cancellation-aware, so the result is checked against the
        // session it was asked for. Otherwise one contact's page lands in another's transcript.
        let asked = ObjectIdentifier(session)
        let contact = session.contactID
        do {
            let page = try await session.earlierTranscript(before: nil)
            guard asked == ObjectIdentifier(session), asked == boundSession else { return }
            loadedContactID = contact
            model.setInitial(page.messages, hasMore: page.hasMore)
        } catch {
            guard asked == ObjectIdentifier(session), asked == boundSession else { return }
            // A blank transcript and a failed read look identical to the user otherwise.
            model.initialLoadFailed()
        }
    }

    private func loadEarlier() async {
        // Retrying after a failed *initial* load means loading the first page again. Keyed on
        // whether a page ever landed, not on emptiness — an empty conversation is legitimately empty.
        guard model.initialLoaded else { return await loadFirstPage(force: true) }
        await model.loadEarlier {
            let page = try await session.earlierTranscript(before: model.messages.first)
            return (page.messages, page.hasMore)
        }
    }
}

/// Decides whether a `.contactEnded` the view sees is a contact ending now (CV-2). The session
/// replays an earlier end to a new subscriber, and a restart ends a contact on the way to the next;
/// neither is what a host's `onContactEnded` means.
struct ContactEndReporter: Equatable {
    /// The contact that was already over when the view subscribed.
    private let endedAtSubscribe: String?
    private var reported: Set<String> = []
    var restarting = false

    init(endedAtSubscribe: String?) { self.endedAtSubscribe = endedAtSubscribe }

    mutating func shouldReport(contactID: String?) -> Bool {
        guard let contactID, contactID != endedAtSubscribe, !reported.contains(contactID) else { return false }
        reported.insert(contactID)   // a restart's end too, so it is not reported once the restart is over
        return !restarting
    }
}

/// Sheet presentation. `.embedded` is the identity case — the host already placed
/// `TouchpointChatView` itself — so the modifier only has work to do for `.sheet`.
@MainActor
struct TouchpointChatModifier: ViewModifier {
    let session: TouchpointSession
    @Binding var isPresented: Bool
    let presentation: TouchpointPresentation
    let theme: TouchpointTheme
    let header: ChatHeader?
    let actions: TouchpointChatActions
    var options: TouchpointChatOptions = .default
    let views: ConnectViewRendering?

    /// A nested surface — the sheet's presentation background, sitting behind the chat view's own —
    /// keeps the fill and the backdrop blur but drops the decorative depth. Web gates those layers
    /// per surface (`BackgroundDecoration.tsx:41`) and paints them once.
    private static func chromeTheme(_ theme: TouchpointTheme) -> TouchpointTheme {
        var chrome = theme
        chrome.backgroundDepthLayer = false
        return chrome
    }

    func body(content: Content) -> some View {
        switch presentation {
        case .embedded:
            // Deliberately a no-op: `.embedded` means the host owns the container, so wrapping its
            // content in a stack of our choosing would change its layout behind its back. Place
            // `TouchpointChatView` wherever you want it instead.
            content
        case .sheet(let detents):
            content.sheet(isPresented: $isPresented) {
                // No default title: the template's sheet is controls only. The close control alone
                // makes the bar appear.
                TouchpointChatView(session: session, theme: theme, header: header, actions: actions,
                                   onClose: { isPresented = false }, options: options, views: views)
                    .presentationDetents(detents)
                    // The SDK's own surface is the sheet's background, so the panel's fill and
                    // material reach every edge instead of sitting on a system-grey sheet. The
                    // depth layers are off here because `TouchpointChatView` already paints them,
                    // and web paints them once per surface (`Layout.tsx:28`) — stacked, the wash
                    // and the bottom shade double and two grain films sit at different phases.
                    .presentationBackground {
                        TouchpointSurface().touchpointTheme(Self.chromeTheme(theme))
                    }
            }
        }
    }
}

private struct TouchpointChatIsPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// Whether the chat is on screen. A host that keeps `TouchpointChatView` mounted while hiding
    /// it — so a half-typed message survives — sets this to `false`: the composer gives up the
    /// keyboard and arrivals are not announced over the screen the customer is looking at.
    var touchpointChatIsPresented: Bool {
        get { self[TouchpointChatIsPresentedKey.self] }
        set { self[TouchpointChatIsPresentedKey.self] = newValue }
    }
}

/// The window mode `touchpointChatWindow` presents the panel in, for what web derives from it (the
/// brand icon's shape in the floating window). Internal: a host states the mode once, on the window.
private struct TouchpointChatWindowModeKey: EnvironmentKey {
    static let defaultValue: TouchpointChatWindowMode? = nil
}

extension EnvironmentValues {
    var touchpointChatWindowMode: TouchpointChatWindowMode? {
        get { self[TouchpointChatWindowModeKey.self] }
        set { self[TouchpointChatWindowModeKey.self] = newValue }
    }

    /// Whether the panel is the phone's bottom-half dock — `.half` below the tablet breakpoint. The
    /// panel cannot tell this from its own width (a tablet's right-half panel is narrower than the
    /// breakpoint too), so the window that knows the window's width states it.
    @Entry var touchpointChatIsBottomDock = false
}
