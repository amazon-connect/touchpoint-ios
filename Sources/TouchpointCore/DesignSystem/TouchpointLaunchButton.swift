import SwiftUI

/// The collapsed affordance (design-04): a translucent disc carrying the assistant's mark, floating
/// over the host's screen. 56pt at the default text size, with the SDK's surface behind it so it
/// reads as the same material as the panel it opens.
///
/// A label may ride alongside the glyph, as the bank screens' pill does; without one the button is
/// a circle.
@MainActor
public struct TouchpointLaunchButton: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The whole environment, so the accent can be resolved to pick readable ink over it.
    @Environment(\.self) private var environment

    /// How the launcher is filled.
    public enum Style: Sendable {
        /// The vendor template's translucent disc (design-04): the SDK's own surface, which reads
        /// as the same material as the panel it opens. Suits a host screen whose backdrop the
        /// launcher can safely borrow.
        case surface
        /// A solid brand pill, as the bank screens show the assistant affordance (design-05…12).
        /// Use it over busy or light host content, where a translucent fill cannot guarantee the
        /// label's contrast.
        case prominent
    }

    private let label: String?
    private let style: Style
    /// The host's action. Visible to tests, which cannot tap.
    let action: () -> Void

    /// - Parameters:
    ///   - label: Optional text beside the glyph. `nil` draws the glyph alone.
    ///   - style: `.surface` by default; `.prominent` for a solid brand fill.
    ///   - action: What opening means — the host owns presentation.
    public init(label: String? = nil, style: Style = .surface, action: @escaping () -> Void) {
        self.label = label
        self.style = style
        self.action = action
    }

    private var metrics: TranscriptMetrics { TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme) }

    /// On a brand fill the ink is whichever of black or white reads against *that* accent — a host
    /// brand colour rarely follows the colour scheme, so the scheme's inverse is not a safe choice.
    /// On the translucent surface it is ordinary body ink.
    private var inkColor: Color {
        style == .prominent ? theme.inkOnAccent(in: environment) : theme.primary(.t80)
    }

    /// Web's `rounded-outer`, which follows the host's theme. A capsule would ignore a host-set
    /// radius and would over-round a wrapped label, so the radius is explicit; SwiftUI clamps it to
    /// half the height, which keeps the unlabelled disc circular.
    private var launchShape: RoundedRectangle {
        TouchpointShape.rounded(metrics.outerRadius)
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: metrics.controlPadding) {
                // The Touchpoint mark (`Icons.tsx:610-620`), not a sparkle: web's launch button carries
                // the product's own glyph. Large and alone on the disc; smaller inline beside a label.
                TouchpointGlyph()
                    // Web's glyph is `text-primary-80`, flat — it does not take the accent
                    // (`ui/LaunchButton.tsx:23`). The accent appears only on the `.prominent`
                    // deviation, where it is the fill and the ink must contrast with it.
                    .fill(style == .prominent ? inkColor : theme.primary(.t80))
                    // `w-8 h-8` is unconditional in web: a label does not shrink the mark.
                    .frame(width: metrics.launchGlyphSize, height: metrics.launchGlyphSize)
                if let label {
                    Text(label)
                        .font(metrics.bodyFont)
                        .foregroundStyle(inkColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(metrics.launchPadding)
            .modifier(LaunchFrame(size: metrics.launchButtonSize, isDisc: label == nil))
            .background {
                switch style {
                case .surface:
                    // Web is `bg-background` at the outer radius with **a backdrop blur** — the
                    // default fill is only 0.9/0.95 opaque, and `App.tsx:731` passes
                    // `backdrop-blur-sm`. No hairline and none of the surface's wash/sheen/grain
                    // layers (`ui/LaunchButton.tsx:23`). On the `.flat` deviation the card is
                    // opaque and a blur would do nothing, so that keeps the bordered lift instead.
                    //
                    // The blur shows only while `background` is translucent, and the fill is
                    // applied at the host's own alpha rather than forced down to 0.9. That is web's
                    // behaviour, not a shortcoming of this one: `backdrop-filter` blurs what is
                    // behind the element and the element's `background-color` then paints over it,
                    // so an opaque background hides web's blur too. Clamping the alpha here would
                    // be the divergence, because it would override a host that chose opacity.
                    if theme.surface == .flat {
                        TouchpointSurface(in: launchShape, bordered: true)
                    } else {
                        launchShape.fill(.ultraThinMaterial)
                        launchShape.fill(theme.background)
                    }
                case .prominent:
                    launchShape.fill(theme.accent)
                }
            }
            .contentShape(launchShape)
        }
        .buttonStyle(.plain)
        // A label is visible text; without one the glyph needs a name of its own, and the Large
        // Content Viewer gives it a readable form at accessibility sizes (control geometry caps).
        .accessibilityLabel(label ?? TouchpointStrings.launchButtonLabel)
        .accessibilityShowsLargeContentViewer()
    }
}

/// A disc is exactly 56pt square — an SF Symbol's intrinsic box is taller than its point size, so
/// without a fixed frame the circle drifts a few points larger. A pill with a label takes 56pt as a
/// *floor* instead: the label keeps scaling past the control cap, and a wrapped one must grow the
/// capsule rather than spill out of it.
private struct LaunchFrame: ViewModifier {
    let size: CGFloat
    let isDisc: Bool

    func body(content: Content) -> some View {
        if isDisc {
            content.frame(width: size, height: size)
        } else {
            content.frame(minHeight: size)
        }
    }
}
