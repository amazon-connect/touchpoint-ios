import SwiftUI
import TouchpointCore

public extension View {
    /// Presents a chat panel over this view in one of the ``TouchpointChatWindowMode``s, the way
    /// web's `windowSize` places its panel (`App.tsx:1000-1012`).
    ///
    /// - `full` covers the view; VoiceOver stays inside the panel.
    /// - `half` docks to the bottom half and insets this view by as much, so its lower content
    ///   scrolls above the panel instead of hiding behind it.
    /// - `mini` floats a rounded panel at the bottom trailing corner; this view stays usable around
    ///   it (web's `floating`: `rounded-outer`, `shadow-2xl`, a primary-10 border, 8pt off the
    ///   edges). From 768pt wide it is web's tall card, 420 wide and nearly full height; on a phone
    ///   it is a compact card (named deviation: web's floating covers a phone's whole screen).
    ///
    /// The panel stays **mounted** while hidden, so a half-typed message survives the chat being
    /// minimised; hidden, it gives up the keyboard and announces nothing
    /// (``SwiftUI/EnvironmentValues/touchpointChatIsPresented``). Put it on the host's root, inside
    /// any safe-area inset the host adds for its own launcher.
    ///
    /// - The mini window's border and corner come from the theme in the environment **here**, so
    ///   apply `.touchpointTheme` above this modifier, not only inside `panel`.
    /// - Pass the same mode to ``TouchpointChatActions/windowMode`` if the customer picks it in the
    ///   built-in settings; the two are not linked. The sheet presentation (`touchpointChat`) has
    ///   no window mode, so offer the switch only with this modifier.
    func touchpointChatWindow<Panel: View>(isPresented: Bool, mode: TouchpointChatWindowMode,
                                           @ViewBuilder panel: () -> Panel) -> some View {
        modifier(ChatWindowModifier(isPresented: isPresented, mode: mode, panel: panel()))
    }
}

struct ChatWindowModifier<Panel: View>: ViewModifier {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPresented: Bool
    let mode: TouchpointChatWindowMode
    let panel: Panel
    /// This view's size with the keyboard ignored, so half height does not halve again when the
    /// keyboard takes its share.
    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Only the phone's bottom-half dock insets the host content below it; the tablet
                // right-half panel (TB-3) overlays the trailing edge and leaves the host as it is.
                if isPresented, mode == .half, tabletHalfWidth == nil {
                    Color.clear.frame(height: Self.halfHeight(size.height))
                }
            }
            .overlay { window }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, s in size = s }
                }
                .ignoresSafeArea(.keyboard)
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: isPresented)
            .animation(reduceMotion ? nil : .spring(duration: 0.35), value: mode)
    }

    static func halfHeight(_ full: CGFloat) -> CGFloat { full * 0.5 }
    /// From web's 768 breakpoint, web's floating card: `md:w-[420px] md:h-[calc(100%-1rem)]
    /// md:max-h-[1080px]` — 420 wide and the window's height less the two 8pt margins, at most 1080.
    /// **Named deviation** below it: web's floating covers the whole screen there (`inset-0`, the
    /// same as full), which would leave mini no different from full on a phone, so iOS keeps a
    /// compact card — the width less 16, at most 420, and 45% of the height — that leaves the app
    /// usable around it.
    static func miniSize(in s: CGSize) -> CGSize {
        let width = max(0, min(420, s.width - 16))
        if s.width >= WideLayout.wideBreakpoint {
            return CGSize(width: width, height: max(0, min(1080, s.height - 16)))
        }
        return CGSize(width: width, height: max(0, min(420, s.height * 0.45)))
    }

    /// TB-3: on a tablet-width window the `.half` panel is the right half (632 from 1280), full
    /// height; `nil` on a phone, where `.half` stays the bottom-half dock. Web's `grid-cols-2` /
    /// `xl:grid-cols-[1fr_632px]` sized from the window.
    private var tabletHalfWidth: CGFloat? {
        mode == .half ? WideLayout.halfPanelWidth(windowWidth: size.width) : nil
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: 1, theme: theme) }

    @ViewBuilder
    private var window: some View {
        // One structural path for every mode: a branch per mode would give the panel a different
        // identity in each, and switching modes would rebuild the chat and lose its draft.
        let mini = mode == .mini
        let miniSize = Self.miniSize(in: size)
        let rightHalf = tabletHalfWidth                      // non-nil → tablet right-half dock
        // Hidden: a bottom or floating panel slides down; a right-half panel slides out to the right.
        let hiddenX = rightHalf.map { isPresented ? 0 : max($0, 1) } ?? 0
        let hiddenY = rightHalf == nil ? (isPresented ? 0 : max(size.height, 1)) : 0
        panel
            .frame(width: mini && size.width > 0 ? miniSize.width : rightHalf,
                   height: mini && size.height > 0 ? miniSize.height : nil)
            // The bottom-half dock caps its height here; full and the tablet right-half fill through
            // the outer frame below. An `.infinity` cap stretched the mini frame, so only half caps.
            .frame(maxHeight: mode == .half && rightHalf == nil && size.height > 0 ? Self.halfHeight(size.height) : nil)
            .clipShape(WindowClip(radius: metrics.outerRadius, isClipping: mini))
            .overlay {
                if mini {
                    TouchpointShape.rounded(metrics.outerRadius)
                        .strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline)
                }
            }
            // The dock's divider: the top edge on a phone's bottom-half, the leading edge on a
            // tablet's right-half, so the hairline always sits between the panel and the host.
            .overlay(alignment: rightHalf == nil ? .top : .leading) {
                if mode == .half {
                    Rectangle().fill(theme.primary(.t10))
                        .frame(width: rightHalf == nil ? nil : metrics.hairline,
                               height: rightHalf == nil ? metrics.hairline : nil)
                }
            }
            .shadow(color: .black.opacity(mode == .full ? 0 : 0.22), radius: mini ? 24 : 12, y: mini ? 8 : -4)
            .padding(mini ? metrics.floatingWindowMargin : 0)
            .accessibilityAddTraits(mode == .full && isPresented ? .isModal : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: Self.windowAlignment(mini: mini, rightHalf: rightHalf != nil))
            .offset(x: hiddenX, y: hiddenY)
            .opacity(isPresented ? 1 : 0)
            .allowsHitTesting(isPresented)
            .accessibilityHidden(!isPresented)
            .environment(\.touchpointChatIsPresented, isPresented)
            .environment(\.touchpointChatWindowMode, mode)
            .environment(\.touchpointChatIsBottomDock, Self.isBottomDock(mode: mode, windowWidth: size.width))
    }

    /// The phone's bottom-half dock: `.half` where the window is too narrow for the tablet's
    /// right-half panel (TB-3).
    static func isBottomDock(mode: TouchpointChatWindowMode, windowWidth: CGFloat) -> Bool {
        mode == .half && WideLayout.halfPanelWidth(windowWidth: windowWidth) == nil
    }

    /// Where the panel sits: mini floats bottom-trailing, a tablet right-half docks trailing full
    /// height, every other dock sits at the bottom.
    static func windowAlignment(mini: Bool, rightHalf: Bool) -> Alignment {
        if mini { return .bottomTrailing }
        if rightHalf { return .trailing }
        return .bottom
    }
}

/// The mini window's rounded clip, and no clip at all otherwise. A radius-0 rect is still a clip:
/// it cut the panel's surface off at the safe area in full and half, leaving the status bar and
/// home indicator bands bare. One shape for every mode keeps the panel's identity across switches.
private struct WindowClip: Shape {
    let radius: CGFloat
    let isClipping: Bool

    func path(in rect: CGRect) -> Path {
        isClipping
            ? Path(roundedRect: rect, cornerRadius: radius, style: .circular)
            // Far enough out to cover any safe-area bleed, finite so the path stays drawable.
            : Path(rect.insetBy(dx: -10_000, dy: -10_000))
    }
}
