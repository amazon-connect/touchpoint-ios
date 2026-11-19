import OSLog
import SwiftUI
import TouchpointChat
import TouchpointCore
import TouchpointVoice

/// The support launcher docked at the bottom of every signed-in screen, and the chat it opens.
///
/// Open, the chat covers the screen. That is web's default on a phone: `windowSize: "half"` is a
/// fixed overlay across the whole viewport whose page-side column only appears from 768px up
/// (`App.tsx:1008-1019`, `Layout.tsx:23`), so below that the chat spans it all — no rounded top, no
/// border, no grabber, and the same translucent surface over the page. An earlier fixed-height dock
/// following the bank mockups (design-05…12) clipped long replies and starved the transcript once
/// choices joined the composer; web wins where the two disagree.
///
/// Everything visual comes from the SDK: `TouchpointLaunchButton` is the collapsed state,
/// `TouchpointChatView` the panel — including the replies a message offers, which it draws itself —
/// and `TouchpointVoiceMiniRail` the in-call rail. The demo contributes its brand accent and the
/// words — which is the whole point of the design system.
struct SupportDock: View {
    @Environment(SupportCoordinator.self) private var support
    @Environment(VoiceCoordinator.self) private var voice
    @Environment(AppModel.self) private var model
    @Environment(LiveSyncCoordinator.self) private var liveSync
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        panel
            .touchpointTheme(model.chatTheme)
            // The partner configuration's `colorMode: "light"`: the chat stays light whatever the
            // system's appearance, as web's widget does; the bank screens around it still follow it.
            .environment(\.colorScheme, model.partnerLook ? .light : systemScheme)
    }

    // MARK: Collapsed

    /// The SDK's launcher, brand-filled as the bank screens show it (design-05…12): a translucent
    /// disc would borrow whatever list row happens to sit behind it, and the accessibility audit
    /// caught exactly that as a contrast failure over the Accounts screen.
    struct Launcher: View {
        @Environment(SupportCoordinator.self) private var support
        @Environment(VoiceCoordinator.self) private var voice
        @Environment(AppModel.self) private var model
        @Binding var isExpanded: Bool

        var body: some View {
            HStack(spacing: 12) {
                // In a call the rail *is* the launcher — its leading control opens the chat (owner's
                // ask) — and it floats over the screen as a draggable `CallRail`, so the pill steps
                // aside rather than sitting under it.
                if !(voice.call != nil && voice.isInCall) {
                    TouchpointLaunchButton(label: "Support", style: .prominent) { open() }
                        .accessibilityIdentifier("support.open")
                        .accessibilityHint("Opens a chat with \(PartnerBrand.bankName) support")
                }
                Spacer()
            }
            .padding(.horizontal)
            // On the safe area's bottom edge, as web's launcher sits on the viewport's.
            .touchpointTheme(model.chatTheme)
            // A refused microphone or a failed start is explained in the panel's footer. Keyed on
            // the message, so a second, different failure opens it again; not while in a call,
            // where the footer shows the rail instead.
            .onChange(of: voice.permissionDenial != nil) { _, denied in
                if denied { isExpanded = true }
            }
            .onChange(of: voice.lastError) { _, error in
                if error != nil, !voice.isInCall { isExpanded = true }
            }
        }

        private func open() {
            isExpanded = true
            Task { await support.openChat() }
        }
    }

    /// The in-call rail while the chat is collapsed: web's draggable voice mini widget. It floats
    /// over the whole screen — a layer of its own, not the bottom inset the Support pill uses — so
    /// the customer can drag it out of the way of whatever they are looking at; the layer takes no
    /// touches except on the rail. Vertical on a phone and horizontal on a tablet, as web's is below
    /// and above its `md` breakpoint. It starts bottom-leading, where the Support pill was (web
    /// starts bottom-trailing; the demo keeps the call where the customer started it).
    struct CallRail: View {
        @Environment(SupportCoordinator.self) private var support
        @Environment(VoiceCoordinator.self) private var voice
        @Environment(AppModel.self) private var model
        @Environment(\.horizontalSizeClass) private var sizeClass
        @Binding var isExpanded: Bool

        var body: some View {
            if let call = voice.call, voice.isInCall {
                // No menu here (D12, c71): the floating rail is web's VoiceMini, which has none; the
                // full-screen call opens from the in-chat rail.
                TouchpointVoiceMiniRail(call: call, axis: sizeClass == .compact ? .vertical : .horizontal,
                                        onOpenChat: {
                                            isExpanded = true
                                            Task { await support.openChat() }
                                        })
                    // No `voice.rail` identifier: it could only go on the full-screen layer
                    // `touchpointDraggable` returns, and from there it would land on every
                    // control. The in-chat rail keeps it.
                    .touchpointDraggable(anchor: .bottomLeading)
                    .touchpointTheme(model.chatTheme)
            }
        }
    }

    // MARK: Expanded

    private var panel: some View {
        VStack(spacing: 0) {
            if let session = support.session, !support.startFailed {
                TouchpointChatView(session: session,
                                   theme: model.chatTheme,
                                   // Web's header carries no title, only icon buttons; "Logo + name"
                                   // in Settings adds one beside the mark. The demo keeps the
                                   // minimise wording, since the chat goes back to the launcher
                                   // rather than being dismissed — the one deviation here.
                                   header: model.chatHeader,
                                   actions: chatActions,
                                   onClose: { isExpanded = false },
                                   options: model.chatOptions,
                                   // Connect Views open from the guide card, rendered by the
                                   // instance's own script; nil (no instance URL) keeps the card closed.
                                   views: support.viewRendering,
                                   composerAccessory: Optional<EmptyView>.none,
                                   // No welcome logo: web shows one only for a host
                                   // `brandIcon`, and the demo's monogram read as a stray avatar.
                                   // The call controls sit in the chat's own tray, below the
                                   // composer, rather than on a second surface under it.
                                   footer: footer)
                    // The showcase flow's custom modality: the SDK hands over its JSON, the app
                    // draws it — web's `modalityComponents`.
                    .touchpointModality("AcmeDisputeSummary") { context in
                        DisputeSummaryCard(json: context.modality.json)
                    }
                    // A new session object can reuse a freed one's address, and the SDK view keys
                    // its subscription on object identity; an explicit per-session id makes SwiftUI
                    // build a fresh view instead of keeping one bound to a dead session.
                    .id(support.sessionGeneration)
            } else if let error = support.lastError {
                // A failed start is a product state, not an endless spinner: say why, and offer to
                // try again, which re-runs the chat start.
                VStack(spacing: 12) {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try again") { Task { await support.openChat() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Palette.brand)
                        .accessibilityIdentifier("support.retry")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
            } else {
                VStack(spacing: 12) {
                    ProgressView().tint(Palette.brand)
                    Text("Connecting you to support…")
                        .font(.footnote)
                        .foregroundStyle(Palette.muted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            }
            // With a chat on screen the footer is inside it (above); otherwise it goes here.
            if support.session == nil { footer }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The SDK's own surface behind the parts outside the SDK view — the connecting state and
        // the voice footer — so the whole screen is one material. The **depth** layers are off
        // here: `TouchpointChatView` paints its own surface inside this one, and web paints the
        // sheen, shade and grain once (`Layout.tsx:28`), not once per nested surface.
        .background {
            TouchpointSurface()
                .touchpointTheme(model.dockChromeTheme)
                .ignoresSafeArea()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("support.panel")
    }

    /// The host hooks the SDK draws controls for. Restart is web's: its header always carries one
    /// on the leading edge (`Header.tsx:58-69`), and the same reset backs the "Start new
    /// conversation" button an ended chat shows. The composer has no microphone, as web's has none:
    /// a call starts from Settings → "Call us" (D3).
    private var chatActions: TouchpointChatActions {
        var actions = TouchpointChatActions(
            onRestart: { [support] in await support.restartChat() },
            // Thumbs under the assistant's answers (D11). The SDK keeps the choice on the message,
            // so the chosen thumb stays selected; the demo has no feedback backend, so it logs it.
            // Not in the partner look: the partner's web chat has no feedback row.
            onFeedback: model.partnerLook ? nil : Self.logFeedback,
            // The SDK's settings panel: restart, transcript, end, and the window size.
            onEndConversation: { [support] in await support.endChat() },
            windowMode: model.chatWindowMode(liveSyncActive: liveSync.isActive),
            onWindowModeChange: { [model] in model.chatWindowPick = $0 })
        // "Call us" lives in Settings, out of the footer (D3, c12, c13): while no call is live.
        if voice.isAvailable, !voice.isInCall, voice.phoneCallStatus == nil {
            actions.settingsRows = [TouchpointSettingsRow(label: "Call us", isProminent: true) { [voice] in
                Task { await voice.startCall() }
            }]
        }
        return actions
    }

    private static let feedbackLog = Logger(subsystem: "com.acmebank.demo", category: "feedback")

    private static let logFeedback: @MainActor (Message, MessageFeedback) -> Void = { message, feedback in
        feedbackLog.info("feedback \(String(describing: feedback), privacy: .public) on \(message.serverMessageID.map { "\($0)" } ?? "?", privacy: .public)")
    }

    /// A live call uses the SDK's rail. Offline mode has no instance to call, and a denied
    /// microphone is a product state with a Settings link rather than a dead button.
    @ViewBuilder
    private var footer: some View {
        if let denial = voice.permissionDenial {
            // The panel is already open, so "continue with chat" means putting the denial away.
            PermissionDenialView(denial: denial, onContinueWithChat: { voice.dismissDenial() })
                .accessibilityIdentifier("voice.permissionDenied")
        } else if let call = voice.call, voice.isInCall {
            VStack(spacing: 4) {
                TouchpointVoiceMiniRail(call: call, axis: .horizontal, onMenu: { model.voiceFullScreen = true })
                    .accessibilityIdentifier("voice.rail")
                // Only what the rail can't show (D12, c70): "On a call" said nothing the rail
                // didn't.
                if let caption = Self.callStateText(voice.state) {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(model.chatTheme.primary(.t60))
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        } else if let status = voice.phoneCallStatus {
            // Ring-my-phone: Connect is calling the customer's phone; the call lives there.
            Text(status)
                .font(.caption)
                .foregroundStyle(model.chatTheme.primary(.t60))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("voice.phoneStatus")
        } else if let error = voice.lastError {
            // A failed start is a product state, not a silent button; Settings → "Call us" tries
            // again.
            Text(error)
                .font(.caption2)
                .foregroundStyle(Palette.negative)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .accessibilityIdentifier("voice.error")
        }
        // Nothing otherwise: the bank design has no standing footer under the chat.
    }

    /// The caption under the in-chat rail, or `nil` while the call is simply connected.
    static func callStateText(_ s: VoiceCallState) -> String? {
        switch s {
        case .idle: nil
        case .requesting, .connecting: "Calling…"
        case .connected: nil
        case .reconnecting: "Reconnecting…"
        case .interrupted: "On hold for another call"
        case .ended: "Call ended"
        }
    }
}

/// `AcmeDisputeSummary`, the showcase flow's own modality: the dispute about to be raised.
private struct DisputeSummaryCard: View {
    struct Summary: Decodable { let merchant: String?; let amount: String?; let status: String? }
    let json: Data

    var body: some View {
        let s = try? JSONDecoder().decode(Summary.self, from: json)
        VStack(alignment: .leading, spacing: 6) {
            Label("Dispute summary", systemImage: "doc.text.magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Palette.brand)
            if let merchant = s?.merchant { LabeledContent("Merchant", value: merchant) }
            if let amount = s?.amount { LabeledContent("Amount", value: amount) }
            if let status = s?.status { LabeledContent("Status", value: status) }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
        .background(Palette.brand.opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }
}
