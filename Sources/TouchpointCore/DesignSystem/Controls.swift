import SwiftUI

/// Reads the theme and Dynamic Type scale into one `TranscriptMetrics`, so every control derives
/// its geometry the same way.
package struct MetricsReader<Content: View>: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    private let content: (TouchpointTheme, TranscriptMetrics) -> Content

    package init(@ViewBuilder content: @escaping (TouchpointTheme, TranscriptMetrics) -> Content) {
        self.content = content
    }

    package var body: some View {
        content(theme, TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme))
    }
}

/// A circular icon button (web: `IconButton.tsx`, `MessageButton.tsx`): a 40pt circle at the
/// default text size holding a 16pt glyph (compact: 32pt and 12pt), inside a 44pt hit area.
/// Variants are fills; pressed state is a tint overlay; disabled drops the glyph to tier 20.
///
/// Keyboard and Switch Control focus is drawn by the system's own focus ring, which the SDK does
/// not replace. Icon-only controls get the Large Content Viewer, because control geometry stops
/// growing at the first accessibility size (`TranscriptMetrics.controlScale`).
package struct TouchpointIconButtonStyle: ButtonStyle {
    package enum Variant: Sendable {
        /// No fill; the glyph alone at tier 60. Header controls, rail controls, message actions.
        case ghost
        /// No fill; glyph at tier 90. A message action the user has chosen (thumbs up, say).
        case selected
        /// No fill; glyph at tier 60 — the same as `ghost`. The sibling of a chosen action: the
        /// chosen one's tier-90 ink carries the state (web's icon set has no filled variant), so
        /// this stays at the AA floor rather than dropping to tier 40, which lands near 2.5:1 on
        /// the light surface (WCAG 1.4.11).
        case unselected
        /// Quiet fill (tier 10) with strong glyph (tier 80). The send button.
        case subtle
        /// Ink fill with inverse glyph. The attach button, the rail's sharing state.
        case main
        /// Web IconButton `main` (`IconButton.tsx:50-51`): accent fill, the accent's readable ink.
        /// Disabled is an accent-20 fill with a `secondary40` glyph. Send and the date submit.
        /// **Deviation:** web's glyph is a fixed `text-secondary`; here it is whichever of black or
        /// white reads on the host's accent (`inkOnAccent`), because a brand accent need not follow
        /// the colour scheme. On a light brand accent the disabled glyph is faint; it is inactive.
        case accent
        /// Semantic red fill with inverse glyph. End call, close in voice mode.
        case error
    }

    package enum Size: Sendable {
        /// 40pt, 16pt glyph.
        case regular
        /// 32pt, 12pt glyph — the actions under a message.
        case compact
    }

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.self) private var environment
    private let variant: Variant
    private let size: Size

    package init(_ variant: Variant, size: Size = .regular) {
        self.variant = variant
        self.size = size
    }

    package func makeBody(configuration: Configuration) -> some View {
        MetricsReader { theme, metrics in
            let diameter = size == .regular ? metrics.iconButtonDiameter : metrics.compactIconButtonDiameter
            configuration.label
                .environment(\.touchpointIconSize, size == .regular ? metrics.iconGlyphSize : metrics.compactIconGlyphSize)
                .foregroundStyle(glyph(theme))
                .frame(width: diameter, height: diameter)
                .background(fill(theme), in: Circle())
                .overlay {
                    if configuration.isPressed {
                        Circle().fill(pressOverlay(theme))
                    }
                }
                .animation(.easeInOut(duration: Motion.colorDuration), value: configuration.isPressed)
                // Web's control is a 40pt disc with 8pt gaps, and that is what is drawn. The iOS
                // 44pt tap floor is met by growing the *hit area* outwards instead of the frame: a
                // `minHeight` here made the header 60 tall and pushed the gaps to 12, so the layout
                // no longer matched web. The outset is half the shortfall on each edge.
                .contentShape(.rect.inset(by: -(metrics.minimumTapTarget - metrics.iconButtonDiameter) / 2))
                .accessibilityShowsLargeContentViewer()
        }
    }

    private func glyph(_ theme: TouchpointTheme) -> Color {
        guard isEnabled else {
            return switch variant {
            case .ghost, .subtle, .error: theme.primary(.t20)
            case .selected: theme.primary(.t40)
            case .unselected: theme.primary(.t10)
            case .main, .accent: theme.secondary(.t40)
            }
        }
        return switch variant {
        case .ghost, .unselected: theme.primary(.t60)
        case .selected: theme.primary(.t90)
        case .subtle: theme.primary(.t80)
        case .main, .error: theme.secondary(.t90)
        case .accent: theme.inkOnAccent(in: environment)
        }
    }

    private func fill(_ theme: TouchpointTheme) -> Color {
        guard isEnabled else {
            return switch variant {
            case .ghost, .selected, .unselected: .clear
            case .subtle: theme.primary(.t5)
            case .main: theme.primary(.t10)
            case .accent: theme.accent(.t20)
            case .error: theme.secondary(.t20)
            }
        }
        return switch variant {
        case .ghost, .selected, .unselected: .clear
        case .subtle: theme.primary(.t10)
        case .main: theme.primary(.t90)
        case .accent: theme.accent
        case .error: theme.error
        }
    }

    private func pressOverlay(_ theme: TouchpointTheme) -> Color {
        switch variant {
        case .ghost, .main, .accent, .selected, .unselected: theme.secondary(.t10)
        case .subtle: theme.primary(.t10)
        case .error: theme.primary(.t5)
        }
    }
}

/// A suggested-reply chip (design-05…12): a pill with the quiet tier-10 fill and tier-90 label,
/// never shorter than the tap floor. Pressed tints.
///
/// Disabled drops to tier 40 — an inactive control, which WCAG 1.4.11 exempts. The one a reader
/// actually chose is `isChosen`: that text is *content*, so it stays at the tier-60 AA floor on the
/// quiet fill, and reads as selected.
package struct TouchpointChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    private let isChosen: Bool

    package init(isChosen: Bool = false) { self.isChosen = isChosen }

    package func makeBody(configuration: Configuration) -> some View {
        MetricsReader { theme, metrics in
            // design-05…12: small, light pills under the agent's message — a quiet shortcut row, not
            // a set of buttons. Tier-5 on the flat card; tier-10 on glass, where tier-5 vanishes.
            let fill = theme.surface == .flat ? ThemeTier.t5 : ThemeTier.t10
            configuration.label
                .font(.footnote)
                .foregroundStyle(ink(theme))
                .padding(.horizontal, metrics.chipHorizontalPadding)
                .padding(.vertical, metrics.chipVerticalPadding)
                .background(isEnabled || isChosen ? theme.primary(fill) : theme.primary(.t5), in: Capsule())
                .overlay {
                    if configuration.isPressed { Capsule().fill(theme.secondary(.t10)) }
                }
                // The pill is drawn at its natural height; the tap target is still the full 44pt.
                .frame(minHeight: metrics.minimumTapTarget)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: Motion.colorDuration), value: configuration.isPressed)
        }
    }

    private func ink(_ theme: TouchpointTheme) -> Color {
        if isEnabled { return theme.primary(.t90) }
        // The chosen reply is still the reader's own words on screen: the AA floor, not the tier an
        // inactive control may use.
        return isChosen ? theme.primary(.t60) : theme.primary(.t40)
    }
}

/// Durations shared by every control, so the SDK's motion is one voice (web: Tailwind's 150ms
/// colour transitions).
package enum Motion {
    package static let colorDuration: TimeInterval = 0.15
}

/// A horizontal light band sweeping through text (web `.shimmer`): the typing and connection
/// indicator. The text is drawn at tier 60 — the AA floor — and a copy at tier 90 shows through a
/// band that crosses every 1.5s. Under Reduce Motion there is no band; the text reads at tier 60.
///
/// The modifier owns the foreground style: a `.foregroundStyle` set inside `content` would win over
/// both layers and hide the sweep.
package struct Shimmer: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package static let period: TimeInterval = 1.5

    /// 0…1 position of the band, wrapping every `period`.
    package static func phase(at time: TimeInterval) -> Double {
        time.truncatingRemainder(dividingBy: period) / period
    }

    package init() {}

    package func body(content: Content) -> some View {
        if reduceMotion {
            ShimmerFrame(phase: nil) { content }
        } else {
            TimelineView(.animation) { context in
                ShimmerFrame(phase: Self.phase(at: context.date.timeIntervalSinceReferenceDate)) { content }
            }
        }
    }
}

/// One frame of the shimmer: pure in `phase`, so the static (`nil`) and moving cases are testable
/// without an environment override.
package struct ShimmerFrame<Content: View>: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    let phase: Double?
    @ViewBuilder let content: () -> Content

    package init(phase: Double?, @ViewBuilder content: @escaping () -> Content) {
        self.phase = phase
        self.content = content
    }

    package var body: some View {
        content()
            .foregroundStyle(theme.primary(.t60))
            .overlay {
                if let phase {
                    content()
                        .foregroundStyle(theme.primary(.t90))
                        .mask {
                            GeometryReader { geo in
                                let band = TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme).shimmerBandWidth
                                // From fully off the leading edge to fully off the trailing one.
                                LinearGradient(colors: [.clear, .black, .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: band)
                                    .offset(x: -band + (geo.size.width + band) * phase)
                            }
                        }
                        // The copy is pixels, not content: VoiceOver reads the text once.
                        .accessibilityHidden(true)
                }
            }
    }
}

package extension View {
    /// Applies the shimmer indicator to text.
    func shimmer() -> some View { modifier(Shimmer()) }
}

/// Expanding rings around a circular control while something is speaking (web: `Ripple.tsx`). A
/// 2pt ring at accent-50 sits just outside the control; four rings at accent-20 scale from the
/// control's footprint to twice it and fade, easing out, by three quarters of each 1.5s cycle,
/// staggered 0.18s. Rings paint **outside** the control only. Under Reduce Motion only the static
/// ring is drawn.
package struct RippleView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    package static let ringCount = 4
    package static let period: TimeInterval = 1.5
    package static let delays: [TimeInterval] = (0..<ringCount).map { Double($0) * 0.18 }

    /// Scale and opacity of one ring at `progress` through its cycle: ease-out (the web's
    /// `cubic-bezier(0,0,.2,1)`, approximated quadratically) over the first three quarters, then rest.
    package static func ring(progress: Double) -> (scale: Double, opacity: Double) {
        let t = min(max(progress, 0), 1)
        let active = 0.75
        guard t < active else { return (2, 0) }
        let linear = t / active
        let k = 1 - (1 - linear) * (1 - linear)
        return (1 + k, 1 - k)
    }

    let diameter: CGFloat
    let metrics: TranscriptMetrics

    package init(diameter: CGFloat, metrics: TranscriptMetrics) {
        self.diameter = diameter
        self.metrics = metrics
    }

    package var body: some View {
        if reduceMotion {
            RippleFrame(diameter: diameter, metrics: metrics, now: nil)
        } else {
            TimelineView(.animation) { context in
                RippleFrame(diameter: diameter, metrics: metrics, now: context.date.timeIntervalSinceReferenceDate)
            }
        }
    }
}

/// One frame of the ripple: pure in `now`, so the static (`nil`) case is testable.
package struct RippleFrame: View {
    @Environment(\.touchpointTheme) private var theme
    let diameter: CGFloat
    let metrics: TranscriptMetrics
    let now: TimeInterval?

    package init(diameter: CGFloat, metrics: TranscriptMetrics, now: TimeInterval?) {
        self.diameter = diameter
        self.metrics = metrics
        self.now = now
    }

    package var body: some View {
        ZStack {
            Circle()
                .strokeBorder(theme.rippleColor(.t50), lineWidth: metrics.rippleRingWidth)
                .frame(width: diameter + metrics.rippleRingWidth * 2, height: diameter + metrics.rippleRingWidth * 2)
            if let now {
                ZStack {
                    ForEach(0..<RippleView.ringCount, id: \.self) { i in
                        let progress = ((now + RippleView.delays[i]).truncatingRemainder(dividingBy: RippleView.period)) / RippleView.period
                        let ring = RippleView.ring(progress: progress)
                        Circle()
                            .fill(theme.rippleColor(.t20))
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(ring.scale)
                            .opacity(ring.opacity)
                    }
                }
                .mask { RippleHoleMask(diameter: diameter) }
            }
        }
        .frame(width: diameter * 2, height: diameter * 2)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Opaque everywhere except the control's own footprint, so rings paint outside it only. An
/// even-odd fill of a rectangle with a circle cut out — no blend modes, which `ImageRenderer` does
/// not honour reliably.
package struct RippleHoleMask: View {
    let diameter: CGFloat

    package init(diameter: CGFloat) { self.diameter = diameter }

    package var body: some View {
        HoleShape(diameter: diameter)
            .fill(.black, style: FillStyle(eoFill: true))
            .frame(width: diameter * 2, height: diameter * 2)
    }

    private struct HoleShape: Shape {
        let diameter: CGFloat

        func path(in rect: CGRect) -> Path {
            var path = Path(rect)
            path.addEllipse(in: CGRect(x: rect.midX - diameter / 2, y: rect.midY - diameter / 2,
                                       width: diameter, height: diameter))
            return path
        }
    }
}

/// Web's `TextButton` (`ui/TextButton.tsx`): a full-width row with the label leading and a 16pt
/// icon trailing, `px-5 py-4`, outer radius. One style for every text button the SDK draws, so the
/// settings rows, "Start new conversation" and the sign-in button cannot drift apart.
package struct TouchpointTextButtonStyle: ButtonStyle {
    package enum Variant: Sendable {
        /// `bg-primary-10 text-primary`; disabled primary-5 / primary-20.
        case subtle
        /// `bg-primary text-secondary`; disabled primary-5 / secondary-40.
        case main
        /// `bg-error-primary text-secondary`; disabled primary-5 / secondary-40 (web's end confirm).
        case error
    }

    @Environment(\.isEnabled) private var isEnabled
    private let variant: Variant
    private let icon: TouchpointIcon?

    package init(_ variant: Variant, icon: TouchpointIcon?) {
        self.variant = variant
        self.icon = icon
    }

    package func makeBody(configuration: Configuration) -> some View {
        MetricsReader { theme, metrics in
            HStack(spacing: metrics.controlPadding) {
                // Wraps rather than clips in a short panel or at a large text size.
                configuration.label
                    .font(metrics.bodyFont)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let icon {
                    TouchpointIconView(icon, size: metrics.iconGlyphSize)
                }
            }
            .foregroundStyle(ink(theme))
            .padding(.horizontal, metrics.textButtonHorizontalPadding)
            .padding(.vertical, metrics.textButtonVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: max(metrics.minimumTapTarget, metrics.textButtonMinHeight))
            .background(fill(theme), in: TouchpointShape.rounded(metrics.outerRadius))
            .overlay {
                // Web's `active:before:bg-secondary-10`, for both variants.
                if configuration.isPressed {
                    TouchpointShape.rounded(metrics.outerRadius).fill(theme.secondary(.t10)).allowsHitTesting(false)
                }
            }
            .contentShape(TouchpointShape.rounded(metrics.outerRadius))
        }
    }

    private func ink(_ theme: TouchpointTheme) -> Color {
        switch variant {
        case .subtle: theme.primary(isEnabled ? .t90 : .t20)
        // **Deviation:** web's disabled `main` is `text-secondary-40` on `bg-primary-5`, which is
        // near-invisible; web never shows it (its main buttons are never disabled). Here a `main`
        // button is disabled while its action runs (starting a conversation, opening sign-in), so
        // its label keeps the subtle variant's readable disabled ink.
        case .main, .error: isEnabled ? theme.secondary(.t90) : theme.primary(.t20)
        }
    }

    private func fill(_ theme: TouchpointTheme) -> Color {
        guard isEnabled else { return theme.primary(.t5) }
        return switch variant {
        case .subtle: theme.primary(.t10)
        case .main: theme.primary(.t90)
        case .error: theme.error
        }
    }
}
