import SwiftUI
import TouchpointCore

/// Touchpoint web's full-screen voice (web `input: "voice"`, `FullscreenVoice.tsx`), for a call on
/// a ``TouchpointVoiceCall``. Shown, it starts the call — as web's does on opening — asking for the
/// microphone through the call's own permission policy; then web's call: the orb, rippling while
/// the other side speaks, the microphone rippling while the customer does, a Speakers toggle,
/// Minimise when the host offers one, and a red close in the header, and the connecting, ended and
/// failed screens, the last with Retry.
///
/// The view drives the existing facade, so the host-owned flow (the floating
/// ``TouchpointVoiceMiniRail`` + CallKit) is unchanged. Two ways to use it:
///
/// - **View-owned (web's model).** Hand it a call the host has configured with a microphone
///   permission policy and has *not* started; the view starts, restarts, ends and hangs up on
///   dismissal itself — unless the customer minimises, which hands the call to the host.
/// - **Host-owned.** Show it for a call the host already started (the same call the rail controls);
///   it reflects that call and leaves its lifecycle to the host, except the red close, which ends
///   it. Minimise and dismissal leave it running.
///
/// **Deviation from web:** web's error screen appears only for a failed *connect*; a no-microphone
/// outcome is the same generic failure here, because the facade surfaces a microphone denial as a
/// start failure rather than a distinct screen (web has no on-device permission model).
///
/// **iOS addition:** a Minimise control (`onMinimise`) that dismisses the view and keeps the call.
/// Web's full-screen voice and its voice mini widget are separate modes an integrator picks, so
/// it never needs one; here the full screen opens from the rail mid-call, and the only way back
/// was to hang up.
@MainActor
public struct TouchpointVoiceView: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var model: TouchpointVoiceModel

    private let brandMark: AnyView?
    private let onClose: (@MainActor () -> Void)?
    private let onMinimise: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - call: the call to show and (in the view-owned flow) drive.
    ///   - brandMark: the host's logo for the orb, as web's `brandIcon` fills its VoiceIcon. Omit it
    ///     and the Touchpoint mark is shown on a neutral disc.
    ///   - onEnded: called once when a connected call shown here has ended — not on Restart, and not
    ///     once Minimise was tapped.
    ///   - onClose: the header's red close. It hangs up first, as web's collapse does. `nil` hides
    ///     the control (a host dismissing the view another way still gets the hang-up on dismissal).
    ///   - onMinimise: dismisses the view and keeps the call (**iOS addition** — web's full-screen
    ///     voice has only the red close). Given, the header draws a Minimise control while the call
    ///     is connecting or live; it hands the call to the host (``TouchpointVoiceModel/minimise()``)
    ///     and then calls this, which should dismiss the view. Pass it only where the call stays
    ///     reachable once the view is gone — a ``TouchpointVoiceMiniRail``, or at least the system
    ///     call UI — and follow the call's `state` from then on. A quick double tap may call it
    ///     twice; dismissing twice should be harmless.
    public init(call: TouchpointVoiceCall,
                brandMark: AnyView? = nil,
                onEnded: (@MainActor (EndReason) -> Void)? = nil,
                onClose: (@MainActor () -> Void)? = nil,
                onMinimise: (@MainActor () -> Void)? = nil) {
        let model = TouchpointVoiceModel(call: call)
        model.onEnded = onEnded
        _model = State(initialValue: model)
        self.brandMark = brandMark
        self.onClose = onClose
        self.onMinimise = onMinimise
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme) }

    public var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(TouchpointSurface(in: Rectangle()))
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onChange(of: model.call.state, initial: true) { _, state in model.callStateChanged(state) }
    }

    // MARK: Header — Speakers, Minimise, red close (VO-1)

    // Deviation: web's header also carries Restart and Settings; here it is the Speakers toggle,
    // Minimise when the host offers one (an iOS addition), and the red close, as the voice
    // design specifies. Restart is reached from the failed screen's Retry, and a host wanting an in-call
    // restart affordance can call `model.restart()`.
    enum HeaderControl: Equatable, Sendable { case speakers, minimise, close }

    /// The header's controls, in order: the destructive close last, as web's. Minimise only while
    /// there is a call to keep — connecting or live; an ended or failed call has nothing to hand on.
    nonisolated static func headerControls(screen: VoiceScreen, hasMinimise: Bool, hasClose: Bool) -> [HeaderControl] {
        var controls: [HeaderControl] = [.speakers]
        if hasMinimise, screen == .connecting || screen == .live { controls.append(.minimise) }
        if hasClose { controls.append(.close) }
        return controls
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: metrics.controlPadding) {
            Spacer(minLength: 0)
            ForEach(Self.headerControls(screen: model.screen, hasMinimise: onMinimise != nil, hasClose: onClose != nil),
                    id: \.self, content: headerControl)
        }
        .padding(metrics.controlPadding)
    }

    @ViewBuilder
    private func headerControl(_ control: HeaderControl) -> some View {
        switch control {
        case .speakers:
            Button { model.toggleSpeakers() } label: {
                TouchpointIconView(model.speakersOn ? .volume : .volumeOff)
            }
            .buttonStyle(TouchpointIconButtonStyle(.ghost))
            .accessibilityLabel(TouchpointStrings.speakersLabel)
            .accessibilityValue(model.speakersOn ? TouchpointStrings.speakersOnValue : TouchpointStrings.speakersOffValue)
        case .minimise:
            // The chat header's own minimise: same glyph, style and label.
            Button {
                model.minimise()
                onMinimise?()
            } label: {
                TouchpointIconView(.minimize)
            }
            .buttonStyle(TouchpointIconButtonStyle(.ghost))
            .accessibilityLabel(TouchpointStrings.minimiseButtonLabel)
            .accessibilityHint(TouchpointStrings.minimiseCallHint)
        case .close:
            Button {
                model.end()
                onClose?()
            } label: {
                TouchpointIconView(.close)
            }
            .buttonStyle(TouchpointIconButtonStyle(.error))
            .accessibilityLabel(TouchpointStrings.endCallLabel)
        }
    }

    // MARK: Content by screen (VO-1, VO-2)

    @ViewBuilder
    private var content: some View {
        switch model.screen {
        case .connecting:
            // Web's full-screen voice shows its `Loader` (`FullscreenVoice.tsx:225`).
            TouchpointLoader(size: metrics.loaderSize, label: TouchpointStrings.callConnecting)
        case .live:
            liveCall
        case .ended:
            VoiceStateScreen(metrics: metrics,
                             title: TouchpointStrings.callEndedTitle,
                             lines: [TouchpointStrings.callEndedBody])
        case .failed:
            VStack(spacing: 0) {
                VoiceStateScreen(metrics: metrics,
                                 title: TouchpointStrings.callErrorTitle,
                                 lines: [TouchpointStrings.callErrorBody, TouchpointStrings.callErrorHint])
                    .frame(maxHeight: .infinity)
                retryBar
            }
        }
    }

    /// Web's live call: the orb centred and rippling while the other side speaks, the microphone
    /// below it rippling while the customer does.
    @ViewBuilder
    private var liveCall: some View {
        VStack(spacing: 0) {
            ZStack {
                // Deviation: web animates the ripple unconditionally; `RippleView` draws only the
                // static ring under Reduce Motion (its own documented behaviour), because a
                // continuously scaling animation is exactly what that setting exists to stop.
                if model.call.isRemoteSpeaking {
                    RippleView(diameter: metrics.voiceOrbSize, metrics: metrics)
                }
                VoiceOrb(metrics: metrics, brandMark: brandMark)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ZStack {
                if model.call.isLocalSpeaking {
                    RippleView(diameter: metrics.iconButtonDiameter, metrics: metrics)
                }
                Button { Task { try? await model.call.setMuted(!model.call.isMuted) } } label: {
                    TouchpointIconView(model.call.isMuted ? .micOff : .mic)
                }
                // Web: subtle while the microphone is on, ghost when it is off — the fill carries the state.
                .buttonStyle(TouchpointIconButtonStyle(model.call.isMuted ? .ghost : .subtle))
                .accessibilityLabel(model.call.isMuted ? TouchpointStrings.unmuteLabel : TouchpointStrings.muteLabel)
            }
            .padding(.vertical, metrics.voiceBarPadding)
        }
    }

    /// Web's Retry bar under the error screen.
    @ViewBuilder
    private var retryBar: some View {
        Button { model.restart() } label: {
            Label {
                Text(TouchpointStrings.callRetryLabel)
            } icon: {
                TouchpointIconView(.restart, size: metrics.iconGlyphSize)
            }
            .font(metrics.bodyFont)
            .frame(maxWidth: .infinity)
            .frame(minHeight: metrics.minimumTapTarget)
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.primary(.t60))
        .frame(maxWidth: metrics.settingsMaxWidth)
        .frame(height: metrics.voiceRetryBarHeight)
        .padding(.horizontal, metrics.transcriptPadding)
    }
}

/// Web's VoiceIcon: a 128pt disc holding either the host's brand mark or the Touchpoint mark on a
/// solid neutral fill, solid so the orb's ripple cannot show through it. Decorative.
struct VoiceOrb: View {
    @Environment(\.touchpointTheme) private var theme
    let metrics: TranscriptMetrics
    let brandMark: AnyView?

    var body: some View {
        Group {
            if let brandMark {
                brandMark
                    .frame(width: metrics.voiceOrbSize, height: metrics.voiceOrbSize)
                    .clipShape(Circle())
            } else {
                TouchpointGlyph()
                    .fill(theme.primary(.t40))
                    .padding(metrics.voiceOrbPadding)
                    .frame(width: metrics.voiceOrbSize, height: metrics.voiceOrbSize)
                    .background(TouchpointTheme.Defaults.voiceOrbBackground, in: Circle())
            }
        }
        .accessibilityHidden(true)
    }
}

/// Web's state screen (ended / error): the Touchpoint mark in tier 20, a title, and one or two
/// lines under it, centred, as one VoiceOver element.
struct VoiceStateScreen: View {
    @Environment(\.touchpointTheme) private var theme
    let metrics: TranscriptMetrics
    let title: String
    let lines: [String]

    var body: some View {
        VStack(spacing: metrics.voiceScreenSpacing) {
            TouchpointGlyph()
                .fill(theme.primary(.t20))
                .frame(width: metrics.voiceStateGlyphSize, height: metrics.voiceStateGlyphSize)
                .accessibilityHidden(true)
            VStack(spacing: metrics.bubbleSpacing) {
                Text(title).font(metrics.titleFont)
                ForEach(lines, id: \.self) { line in
                    Text(line).font(metrics.bodyFont)
                }
            }
            .multilineTextAlignment(.center)
            .foregroundStyle(theme.primary(.t80))
        }
        .padding(metrics.transcriptPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
