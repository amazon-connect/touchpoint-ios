import SwiftUI
import TouchpointCore
#if canImport(AVKit)
import AVKit
#endif

/// The floating voice rail (design-01…03): a translucent, hairlined capsule holding the call's
/// controls — an optional host menu, the speaker, the microphone, screen sharing while the agent
/// has asked for it, and a red close. Expanding rings
/// surround whichever side is currently audible, which is what makes a voice call legible without
/// any text.
///
/// The host places it; the SDK owns its look and its wiring to the call. Vertical by default, as in
/// the template.
@MainActor
public struct TouchpointVoiceMiniRail: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    /// Set by ``TouchpointVoiceMiniRail/touchpointDraggable(anchor:)``: the rail then draws web's drag handle.
    @Environment(\.touchpointDrag) private var drag
    /// True while the handle is being dragged. A `GestureState` resets when the gesture is
    /// cancelled as well as when it ends (a system swipe, an alert, the app backgrounding) — which
    /// `onEnded` alone misses, leaving the next drag to start from the cancelled one's origin.
    @GestureState private var dragging = false

    private let call: TouchpointVoiceCall
    private let axis: Axis
    private let onMenu: (@MainActor () -> Void)?
    private let onOpenChat: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - call: The call the rail controls and reflects.
    ///   - axis: `.vertical` matches the mobile template; `.horizontal` suits a wide layout.
    ///   - onMenu: The host's menu. Omit it and no menu control is drawn.
    ///   - onOpenChat: Opens the host's chat. Drawn first, so during a call the rail can stand in
    ///     for the host's own "Support" launcher — one pill rather than two side by side.
    ///     **iOS addition:** web's chat and voice never share an instance, so its rail has no such
    ///     control. Omit it and none is drawn.
    public init(call: TouchpointVoiceCall, axis: Axis = .vertical, onMenu: (@MainActor () -> Void)? = nil,
                onOpenChat: (@MainActor () -> Void)? = nil) {
        self.call = call
        self.axis = axis
        self.onMenu = onMenu
        self.onOpenChat = onOpenChat
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme) }

    public var body: some View {
        let phase = VoiceMiniRail.phase(for: call.state)
        Group {
            if phase == .hidden {
                EmptyView()
            } else {
                // One shell for both phases, with the controls always laid out: the rail keeps its
                // footprint while connecting instead of jumping into place when the call lands.
                // The loader sits over controls that are present but invisible and unreachable,
                // which is how the web reserves the size.
                shell {
                    controlStack
                        .opacity(phase == .connecting ? 0 : 1)
                        .accessibilityHidden(phase == .connecting)
                        .overlay {
                            if phase == .connecting {
                                // Web's VoiceMini shows its `LoaderAnimation` at 24 (c67).
                                TouchpointLoader(size: metrics.compactLoaderSize, label: TouchpointStrings.callConnecting)
                            }
                        }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TouchpointStrings.voiceRailLabel)
    }

    @ViewBuilder
    private var controlStack: some View {
        let controls = VoiceMiniRail.controls(hasMenu: onMenu != nil, screenShare: call.screenShare, hasChat: onOpenChat != nil,
                                              draggable: drag != nil)
        if axis == .vertical {
            VStack(spacing: metrics.controlPadding) {
                ForEach(controls, id: \.self, content: control)
            }
        } else {
            HStack(spacing: metrics.controlPadding) {
                ForEach(controls, id: \.self, content: control)
            }
        }
    }

    /// The translucent capsule: the SDK's surface, clipped and hairlined, as the web's rail is.
    /// The inset compensates for each control's 44pt hit frame around its 40pt circle, so the
    /// visible gap to the edge is the web's 8pt rather than 12.
    @ViewBuilder
    private func shell<Content: View>(@ViewBuilder _ content: @escaping () -> Content) -> some View {
        content()
            .padding(metrics.composerShellPadding)
            .background(TouchpointSurface(in: TouchpointShape.rounded(metrics.outerRadius), bordered: true))
    }

    @ViewBuilder
    private func control(_ control: VoiceMiniRail.Control) -> some View {
        switch control {
        case .chat:
            Button { onOpenChat?() } label: { TouchpointIconView(.smallTalk) }
                .buttonStyle(TouchpointIconButtonStyle(VoiceMiniRail.variant(for: .chat)))
                .accessibilityLabel(TouchpointStrings.openChatLabel)
        case .menu:
            Button { onMenu?() } label: { TouchpointIconView(.fullScreen) }
                .buttonStyle(TouchpointIconButtonStyle(VoiceMiniRail.variant(for: .menu)))
                .accessibilityLabel(TouchpointStrings.voiceMenuLabel)
        case .dragHandle:
            dragHandle
        case .speakers:
            // Web's Speakers toggle (`VoiceMini.tsx`): mutes what the customer hears, not the
            // microphone — the same control as the full-screen view's header.
            rippling(.speakers) {
                Button { Task { await call.setSpeakersOn(!call.speakersOn) } } label: {
                    TouchpointIconView(call.speakersOn ? .volume : .volumeOff)
                }
                .buttonStyle(TouchpointIconButtonStyle(VoiceMiniRail.variant(for: .speakers)))
                .accessibilityLabel(TouchpointStrings.speakersLabel)
                .accessibilityValue(call.speakersOn ? TouchpointStrings.speakersOnValue : TouchpointStrings.speakersOffValue)
            }
        case .audioRoute:
            audioRouteControl
        case .microphone:
            rippling(.microphone) {
                Button { Task { try? await call.setMuted(!call.isMuted) } } label: {
                    TouchpointIconView(call.isMuted ? .micOff : .mic)
                }
                .buttonStyle(TouchpointIconButtonStyle(VoiceMiniRail.variant(for: .microphone)))
                .accessibilityLabel(call.isMuted ? TouchpointStrings.unmuteLabel : TouchpointStrings.muteLabel)
            }
        case .screenShare:
            // The rail is the sharing indicator (plan rev 2): filled while the agent can see the
            // screen, alongside iOS's own status-bar indicator. Another tap stops it.
            let sharing = VoiceMiniRail.isSharing(call.screenShare)
            Button {
                Task {
                    if sharing { await call.stopScreenShare() } else { try? await call.startScreenShare() }
                }
            } label: {
                TouchpointIconView(.screenShare)
            }
            .buttonStyle(TouchpointIconButtonStyle(sharing ? .main : VoiceMiniRail.variant(for: .screenShare)))
            .accessibilityLabel(sharing ? TouchpointStrings.stopScreenShareLabel : TouchpointStrings.screenShareLabel)
            .accessibilityAddTraits(sharing ? .isSelected : [])
        case .close:
            Button { Task { try? await call.end() } } label: { TouchpointIconView(.close) }
                .buttonStyle(TouchpointIconButtonStyle(VoiceMiniRail.variant(for: .close)))
                .accessibilityLabel(TouchpointStrings.endCallLabel)
        }
    }

    /// Web's handle (`Layout.tsx`, the `Reorder` icon): the only place a drag starts, so the rail's
    /// buttons — and the UIKit route picker, which swallows touches — keep their taps. Hidden from
    /// VoiceOver, which cannot drag; every control stays reachable wherever the rail sits.
    @ViewBuilder
    private var dragHandle: some View {
        TouchpointIconView(.reorder, size: metrics.iconGlyphSize)
            .foregroundStyle(theme.primary(.t60))
            .frame(width: metrics.minimumTapTarget, height: metrics.minimumTapTarget)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .updating($dragging) { _, active, _ in active = true }
                    .onChanged { drag?.changed($0.translation) }
            )
            .onChange(of: dragging) { _, active in if !active { drag?.ended() } }
            .accessibilityHidden(true)
    }

    /// Output routing belongs to iOS: the system route picker is the control, and `audioOutput` is
    /// reflected rather than overridden (the audio-route rule). **iOS addition** — web has no
    /// route control; the speakers toggle beside it is web's.
    @ViewBuilder
    private var audioRouteControl: some View {
        Group {
            #if canImport(AVKit) && !os(macOS)
            // Sized at the tap floor, not at 40pt inside it: the UIKit view *is* the control, and
            // an outer SwiftUI frame would add dead margin that forwards nothing.
            RoutePickerButton(tint: theme.primary(.t60), label: TouchpointStrings.audioRouteLabel)
                .frame(width: metrics.minimumTapTarget, height: metrics.minimumTapTarget)
                .accessibilityValue(call.audioOutput ?? "")
            #else
            TouchpointIconView(.volume, size: metrics.iconGlyphSize)
                .foregroundStyle(theme.primary(.t60))
                .frame(width: metrics.minimumTapTarget, height: metrics.minimumTapTarget)
                .accessibilityLabel(TouchpointStrings.audioRouteLabel)
            #endif
        }
    }

    /// Wraps a control in the ripple, behind it, when that side is audible.
    @ViewBuilder
    private func rippling<Content: View>(_ control: VoiceMiniRail.Control, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        content().background {
            if VoiceMiniRail.ripples(control, localSpeaking: call.isLocalSpeaking, remoteSpeaking: call.isRemoteSpeaking) {
                RippleView(diameter: metrics.iconButtonDiameter, metrics: metrics)
            }
        }
    }
}

/// The rail's pure rules, so "what is drawn, when" is testable without a running call. Internal:
/// hosts place the rail, they do not reimplement it, and every public symbol becomes immutable at
/// publication.
enum VoiceMiniRail {
    enum Control: Equatable, Hashable, Sendable { case dragHandle, chat, menu, speakers, audioRoute, microphone, screenShare, close }

    /// What the rail is showing.
    enum Phase: Equatable, Sendable {
        /// No call worth a rail: before one starts, and after it ends.
        case hidden
        /// Connecting — the footprint with a loader in it.
        case connecting
        /// The controls.
        case live
    }

    /// The controls, in order. Web's VoiceMini is speakers, microphone, close (`VoiceMini.tsx`),
    /// led by its drag handle when draggable. iOS additions around them: the open-chat control and
    /// the host menu first, the system output-route picker after the speakers, and screen sharing
    /// (only once the agent opens a session) just before close.
    static func controls(hasMenu: Bool, screenShare: ScreenShareState = .unavailable, hasChat: Bool = false,
                         draggable: Bool = false) -> [Control] {
        var controls: [Control] = draggable ? [.dragHandle] : []
        if hasChat { controls.append(.chat) }
        if hasMenu { controls.append(.menu) }
        // The route picker follows the microphone (D8, c75), so the order reads as web's speakers,
        // microphone, then the iOS addition.
        controls += [.speakers, .microphone, .audioRoute]
        if screenShare != .unavailable { controls.append(.screenShare) }
        controls.append(.close)
        return controls
    }

    /// Starting counts as sharing for the control: the customer asked, so another tap must stop it.
    static func isSharing(_ state: ScreenShareState) -> Bool { state == .starting || state == .sharing }

    static func phase(for state: VoiceCallState) -> Phase {
        switch state {
        case .idle, .ended: .hidden
        case .requesting, .connecting: .connecting
        // A Chime-internal reconnect or a system interruption keeps the controls: the call is still
        // the user's to mute or end, and taking the controls away mid-call is the worse failure.
        case .connected, .reconnecting, .interrupted: .live
        }
    }

    /// Only ending a call is destructive, and it is the one control the design fills in red.
    static func variant(for control: Control) -> TouchpointIconButtonStyle.Variant {
        control == .close ? .error : .ghost
    }

    /// The speakers toggle ripples while the other side talks, as web's does; the microphone while
    /// this side does.
    static func ripples(_ control: Control, localSpeaking: Bool, remoteSpeaking: Bool) -> Bool {
        switch control {
        case .speakers: remoteSpeaking
        case .microphone: localSpeaking
        case .dragHandle, .chat, .menu, .audioRoute, .screenShare, .close: false
        }
    }
}

#if canImport(AVKit) && !os(macOS)
/// `AVRoutePickerView` wrapped for SwiftUI: the system's own output picker, so AirPlay, Bluetooth
/// and the receiver all appear without the SDK second-guessing the route.
private struct RoutePickerButton: UIViewRepresentable {
    let tint: Color
    let label: String

    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.prioritizesVideoDevices = false
        // The label goes on the UIKit view: AVRoutePickerView hosts its own button, whose system
        // label would otherwise win over a SwiftUI `.accessibilityLabel`.
        view.accessibilityLabel = label
        apply(tint, to: view, in: context.environment)
        return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
        view.accessibilityLabel = label
        apply(tint, to: view, in: context.environment)
    }

    /// Resolved against the current environment, so the tint follows a colour-scheme change rather
    /// than freezing at whatever was current when the view was made.
    private func apply(_ color: Color, to view: AVRoutePickerView, in environment: EnvironmentValues) {
        let c = color.resolve(in: environment)
        let resolved = UIColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.opacity))
        view.activeTintColor = resolved
        view.tintColor = resolved
    }
}
#endif
