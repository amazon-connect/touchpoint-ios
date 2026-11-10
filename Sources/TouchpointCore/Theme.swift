import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Theme tokens, shaped like the web SDK's so a brand configured once reads the same
/// on both: two inks (`primary` and its inverse `secondary`) expressed at **alpha tiers**, an
/// understated `accent`, a translucent `background`, semantic colours, and two radii.
///
/// Propagated **solely through SwiftUI environment values** — never `UIAppearance`, which is
/// process-global and would restyle the host app.
///
/// Every colour token is a `Color`, not a hex string, and that is deliberate: a hex string cannot
/// carry a light and dark pair, so any integrator-set colour would lose Dark Mode.
///
/// A host **may** override the font family (web's theme `fontFamily`, `Theme.tsx`; Android's
/// `TouchpointTheme.fontFamily`). It was excluded to protect Dynamic Type; that call is
/// reversed here to close the Android/web parity gap (OP-6), because the override is applied in a
/// way that keeps Dynamic Type scaling — see ``TranscriptMetrics/fontFamily`` and the `textFont`
/// helper. Text sizes are still exposed only through `TranscriptMetrics`; `fontFamily` chooses the
/// face, not the size.
public struct TouchpointTheme: Sendable, Equatable {
    /// The ink. Body text at tier 90 (web `text-primary`), quiet text at 60, fills at 10, wells
    /// at 5. Hierarchy comes from alpha, not hue — see `ThemeTier`. Assigning it, even its current
    /// value, swaps web's tuned default ladder for the plain one derived from the colour (see
    /// `primary(_:)`).
    public var primary: Color {
        get { primaryOverride ?? Defaults.primary }
        set { primaryOverride = newValue }
    }
    /// The ink's inverse: text on an ink-filled control, the surface behind a translucent fill.
    /// Assigning it behaves as `primary` does.
    public var secondary: Color {
        get { secondaryOverride ?? Defaults.secondary }
        set { secondaryOverride = newValue }
    }
    private var primaryOverride: Color?
    private var secondaryOverride: Color?
    /// Brand colour. **Defaults to the ink's default** (black on light, white on dark — fixed, like
    /// the web's) so it stays understated out of the box and a host-set accent is clearly visible:
    /// caret, loader, selection, the voice ripple. Assigning it, even its current value, records
    /// brand intent; see `accentIsBrand`.
    public var accent: Color {
        get { accentOverride ?? Defaults.accent }
        set { accentOverride = newValue }
    }
    /// Surface fill. Under `.glass` (the web default) it is translucent — the surface sits over a
    /// blurred backdrop; under `.flat` it is a solid card colour. Assigning it records brand intent;
    /// see `backgroundIsBrand`.
    public var background: Color {
        get { backgroundOverride ?? (surface == .flat ? Defaults.flatBackground : Defaults.background) }
        set { backgroundOverride = newValue }
    }
    private var accentOverride: Color?
    private var backgroundOverride: Color?
    /// Focus ring, and the ripple's fallback when no brand accent is set.
    public var focus: Color
    public var error: Color
    public var errorSecondary: Color
    public var warning: Color
    public var warningSecondary: Color
    public var success: Color
    public var successSecondary: Color
    /// Bubbles, pills, cards, error chips. Scaled with text by `TranscriptMetrics`.
    public var innerCornerRadius: CGFloat
    /// Containers that hold buttons: composer, button groups, the launch button, the voice rail.
    public var outerCornerRadius: CGFloat
    /// How the panel is drawn. See ``SurfaceStyle``.
    public var surface: SurfaceStyle
    /// Whether the panel carries its decorative depth layers — the diagonal sheen, the bottom shade
    /// and the film of grain (web: `backgroundDepthLayer`, `interface.ts:426`, gating
    /// `BackgroundDecoration.tsx:41`). Defaults to `true`, as web's does (`App.tsx:139`).
    ///
    /// Turning it off leaves the fill, the backdrop blur and the tinted wash — the flatter, cleaner
    /// look web describes — and is what a host wrapping the SDK view in a surface of its own should
    /// set on **its** copy, so the depth layers are painted once rather than stacked.
    public var backgroundDepthLayer: Bool
    /// The font family applied to the SDK's **text** (web's theme `fontFamily`, `Theme.tsx:598`;
    /// Android's `TouchpointTheme.fontFamily`). A family or PostScript name as `Font.custom` takes
    /// it; `nil` is the platform's own face, which is web's default (its stack resolves to the
    /// system font). It sets the face only — sizes stay with `TranscriptMetrics`, and Dynamic Type
    /// is preserved (see `TranscriptMetrics.textFont`). Glyphs (SF Symbols) are never refaced.
    public var fontFamily: String?

    /// The two surface treatments the design shows.
    ///
    /// - `glass` is **the web SDK's surface**, and the default: a translucent fill over a blurred
    ///   backdrop with the wash, sheen and grain layers (`Layout.tsx` + `BackgroundDecoration.tsx`).
    ///   Parity with web is the bar, so this is what a host gets by setting nothing.
    /// - `flat` is a deliberate deviation web has no counterpart for: a solid card in `background`
    ///   lifted by a shadow, for a host docking the assistant over an opaque screen of its own where
    ///   a translucent panel has nothing worth seeing through to.
    public enum SurfaceStyle: Sendable, Equatable {
        case flat
        case glass
    }
    /// Whether the host set an accent. Components use this to decide whether the accent carries
    /// brand intent worth showing off, or is just the understated default (web: `useProvidedThemeFields`).
    public var accentIsBrand: Bool { accentOverride != nil }
    /// Whether the host set a background. The surface drops its tinted wash over a host colour,
    /// which would otherwise shift the brand's hue (web: `BackgroundDecoration.tsx`).
    public var backgroundIsBrand: Bool { backgroundOverride != nil }

    public init(
        primary: Color? = nil,
        secondary: Color? = nil,
        accent: Color? = nil,
        background: Color? = nil,
        focus: Color = Defaults.focus,
        error: Color = Defaults.error,
        errorSecondary: Color = Defaults.errorSecondary,
        warning: Color = Defaults.warning,
        warningSecondary: Color = Defaults.warningSecondary,
        success: Color = Defaults.success,
        successSecondary: Color = Defaults.successSecondary,
        innerCornerRadius: CGFloat = Defaults.innerCornerRadius,
        outerCornerRadius: CGFloat = Defaults.outerCornerRadius,
        surface: SurfaceStyle = .glass,
        backgroundDepthLayer: Bool = true,
        fontFamily: String? = nil
    ) {
        self.primaryOverride = primary
        self.secondaryOverride = secondary
        self.accentOverride = accent
        self.backgroundOverride = background
        self.surface = surface
        self.backgroundDepthLayer = backgroundDepthLayer
        self.fontFamily = fontFamily
        self.focus = focus
        self.error = error
        self.errorSecondary = errorSecondary
        self.warning = warning
        self.warningSecondary = warningSecondary
        self.success = success
        self.successSecondary = successSecondary
        self.innerCornerRadius = innerCornerRadius
        self.outerCornerRadius = outerCornerRadius
    }

    /// The tokens a host gets by setting nothing. Each resolves against a light and dark pair, so
    /// Dark Mode works untouched.
    public static let `default` = TouchpointTheme()

    // MARK: Tiers

    /// Tiered ink, by web's two rules (`Theme.tsx:62-90`, `intelligentMerge` `:107-152`):
    ///
    /// - **Default ink** uses web's tuned pairs. The bump follows the *white* ink, not the
    ///   appearance: primary is bumped in dark (where it is white), secondary in light (where it is
    ///   white), because the same alpha of white reads fainter than of black.
    /// - **A host-set ink** gets the plain ladder at every appearance, as web derives
    ///   `rgb(from <colour> r g b / α)` — including 5% for tier 5, where the defaults use 3%.
    ///
    /// The defaults are built once from literal components (`DefaultInk`), never by resolving or
    /// re-wrapping a dynamic `Color`: resolving off the main actor and nesting one dynamic colour
    /// inside another both crashed the test suite.
    public func primary(_ tier: ThemeTier) -> Color {
        primaryOverride.map { $0.opacity(tier.derivedAlpha) } ?? DefaultInk.primary(tier)
    }
    public func secondary(_ tier: ThemeTier) -> Color {
        secondaryOverride.map { $0.opacity(tier.derivedAlpha) } ?? DefaultInk.secondary(tier)
    }
    /// The default accent is the default primary, so it carries the same dark bump (50 → 55,
    /// 20 → 25); a brand accent is mixed at the plain alpha, as web's `color-mix` is.
    public func accent(_ tier: AccentTier) -> Color {
        accentOverride.map { $0.opacity(tier.alpha) } ?? DefaultInk.accent(tier)
    }

    /// Readable ink for text sitting **on** a filled accent. A host's accent is usually a fixed
    /// brand colour that does not follow the colour scheme, so the ink cannot simply be the scheme's
    /// inverse: near-black on a mid teal in dark mode lands around 3.2:1, and white on a yellow
    /// brand is unreadable. Whichever of black or white contrasts more is chosen, which is the only
    /// answer that holds for an arbitrary accent (decision B: AA beats parity).
    package func inkOnAccent(in environment: EnvironmentValues) -> Color {
        Self.readableInk(on: accent.resolve(in: environment))
    }

    /// Black or white, whichever contrasts more with `fill`. Pure, so the choice is testable.
    package static func readableInk(on fill: Color.Resolved) -> Color {
        func linear(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        let luminance = 0.2126 * linear(Double(fill.red))
            + 0.7152 * linear(Double(fill.green))
            + 0.0722 * linear(Double(fill.blue))
        let againstWhite = 1.05 / (luminance + 0.05)
        let againstBlack = (luminance + 0.05) / 0.05
        return againstWhite >= againstBlack ? .white : .black
    }

    /// The ripple showcases a brand accent; without one it uses the focus blue rather than the ink,
    /// which would read as a shadow (web: `Ripple.tsx`). The fallback is opaque so the tier alpha
    /// is applied once.
    package func rippleColor(_ tier: AccentTier) -> Color {
        (accentIsBrand ? accent : Defaults.rippleFallback).opacity(tier.alpha)
    }

    /// Default values, named so a host can reach one when composing a partial theme. Light and dark
    /// members are the web SDK's `light-dark()` pairs (`Theme.tsx`).
    public enum Defaults {
        public static let primary = Color.dynamic(light: Color(red: 0, green: 2 / 255, blue: 9 / 255), dark: .white)
        public static let secondary = Color.dynamic(light: .white, dark: Color(red: 0, green: 2 / 255, blue: 9 / 255))
        /// Fixed black / white — it does not follow a host's `primary`, matching the web.
        public static let accent = primary
        /// Light #F2F2F2 @ 90%, dark #1B1B21 @ 95% (`Theme.tsx`). The `.glass` fill.
        public static let background = Color.dynamic(
            light: Color(red: 242 / 255, green: 242 / 255, blue: 242 / 255).opacity(0.9),
            dark: Color(red: 27 / 255, green: 27 / 255, blue: 33 / 255).opacity(0.95))
        /// The `.flat` card: solid white in light (design-05…12 draw the panel pure white on the
        /// host screen), and the same #1B1B21 as glass in dark, opaque.
        public static let flatBackground = Color.dynamic(
            light: .white,
            dark: Color(red: 27 / 255, green: 27 / 255, blue: 33 / 255))
        /// Web's voice-orb stand-in when no brand icon is set: #AFAFAF light / #28292F dark, solid
        /// so the ripple behind the orb cannot show through it (`FullscreenVoice.tsx` VoiceIcon,
        /// "imitates primary5 overlayed on the regular background, but it has to be solid"). The
        /// Touchpoint glyph sits on it at tier 40.
        package static let voiceOrbBackground = Color.dynamic(
            light: Color(red: 175 / 255, green: 175 / 255, blue: 175 / 255),
            dark: Color(red: 40 / 255, green: 41 / 255, blue: 47 / 255))
        public static let focus = Color.dynamic(light: Color(red: 0, green: 127 / 255, blue: 217 / 255).opacity(0.9),
                                                dark: Color(red: 0, green: 149 / 255, blue: 1).opacity(0.7))
        public static let error = Color.dynamic(light: Color(red: 157 / 255, green: 3 / 255, blue: 3 / 255),
                                                dark: Color(red: 1, green: 58 / 255, blue: 105 / 255))
        public static let errorSecondary = Color.dynamic(light: Color(red: 1, green: 92 / 255, blue: 137 / 255),
                                                         dark: Color(red: 157 / 255, green: 3 / 255, blue: 3 / 255))
        public static let warning = Color.dynamic(light: Color(red: 220 / 255, green: 159 / 255, blue: 3 / 255),
                                                  dark: Color(red: 1, green: 214 / 255, blue: 108 / 255))
        public static let warningSecondary = Color.dynamic(light: Color(red: 1, green: 217 / 255, blue: 118 / 255),
                                                           dark: Color(red: 131 / 255, green: 94 / 255, blue: 0))
        public static let success = Color.dynamic(light: Color(red: 11 / 255, green: 120 / 255, blue: 70 / 255),
                                                  dark: Color(red: 136 / 255, green: 214 / 255, blue: 79 / 255))
        public static let successSecondary = Color.dynamic(light: Color(red: 157 / 255, green: 215 / 255, blue: 115 / 255),
                                                           dark: Color(red: 11 / 255, green: 120 / 255, blue: 70 / 255))
        /// The focus blue at full alpha; the ripple applies its own tier (`Ripple.tsx:46-67`).
        package static let rippleFallback = Color.dynamic(light: Color(red: 0, green: 127 / 255, blue: 217 / 255),
                                                          dark: Color(red: 0, green: 149 / 255, blue: 1))
        public static let innerCornerRadius: CGFloat = 20
        public static let outerCornerRadius: CGFloat = 28
    }
}

/// The ink's alpha ladder (`Theme.tsx:53-98`). Web carries **two** ladders: the dark defaults use
/// bumped alphas, because the same alpha over a dark surface reads fainter than over a light one.
/// Roles, by convention across the SDK: 90 body text (web `text-primary`), strong ink and ink
/// fills; 80 the error row's words; 60 quiet text; 40 non-text glyphs and placeholders; 20
/// disabled; 10 fills and hairlines; 5 wells; 1 the shimmer's edge.
public enum ThemeTier: CaseIterable, Sendable {
    case t90, t80, t60, t40, t20, t10, t5, t1

    /// Light-mode alpha: web's `rgba(0,0,0,α)` ladder.
    public var alpha: Double {
        switch self {
        case .t90: 0.9
        case .t80: 0.8
        case .t60: 0.6
        case .t40: 0.4
        case .t20: 0.2
        case .t10: 0.1
        case .t5: 0.03
        case .t1: 0.01
        }
    }

    /// Dark-mode alpha: web's `rgba(255,255,255,α)` ladder, bumped at every tier above 5. Strictly,
    /// this is the *white ink's* ladder — the default secondary uses it in light mode.
    public var darkAlpha: Double {
        switch self {
        case .t90: 0.95
        case .t80: 0.85
        case .t60: 0.65
        case .t40: 0.45
        case .t20: 0.25
        case .t10: 0.12
        case .t5: 0.03
        case .t1: 0.01
        }
    }

    /// The ladder web derives from a host-set ink (`intelligentMerge`): plain alphas, and 5% at
    /// tier 5 where web's own defaults use 3%.
    public var derivedAlpha: Double {
        self == .t5 ? 0.05 : alpha
    }

    /// The tiers text may use. The web draws placeholders and typing text at 40, which lands near
    /// 2.9:1 on its own light surface; the SDK's floor is WCAG AA, so text stops at 60.
    /// Non-text glyphs and disabled controls are exempt (WCAG 1.4.11, inactive components).
    package static let textTiers: [ThemeTier] = [.t90, .t80, .t60]
}

/// Accent alphas: a ring at 50, a wash at 20.
public enum AccentTier: CaseIterable, Sendable {
    case t50, t20

    public var alpha: Double {
        switch self {
        case .t50: 0.5
        case .t20: 0.2
        }
    }

    /// The default (white) accent in dark mode: `accent50`/`accent20` in `Theme.tsx:84-85`.
    public var darkAlpha: Double {
        switch self {
        case .t50: 0.55
        case .t20: 0.25
        }
    }
}

/// Web's default ink tiers as literal light/dark pairs (`Theme.tsx:62-85`), built **once**.
///
/// Each member is a plain component colour at a fixed alpha, so no dynamic colour is wrapped in
/// another and nothing is resolved — both of those crashed the suite under parallel tests. Built
/// once rather than per call, because a freshly constructed dynamic colour per draw is also what
/// hung resolution in tests. The black is web's: `rgb(0,0,0)` at every tier except 80, which web
/// writes as its ink `rgb(0,2,9)`.
package enum DefaultInk {
    private static func black(_ tier: ThemeTier) -> Color {
        tier == .t80 ? Color(red: 0, green: 2 / 255, blue: 9 / 255) : Color(red: 0, green: 0, blue: 0)
    }
    private static let white = Color(red: 1, green: 1, blue: 1)

    private static let primaryTiers: [ThemeTier: Color] = Dictionary(uniqueKeysWithValues: ThemeTier.allCases.map {
        ($0, Color.dynamic(light: black($0).opacity($0.alpha), dark: white.opacity($0.darkAlpha)))
    })
    private static let secondaryTiers: [ThemeTier: Color] = Dictionary(uniqueKeysWithValues: ThemeTier.allCases.map {
        ($0, Color.dynamic(light: white.opacity($0.darkAlpha), dark: black($0).opacity($0.alpha)))
    })
    private static let accentTiers: [AccentTier: Color] = Dictionary(uniqueKeysWithValues: AccentTier.allCases.map {
        ($0, Color.dynamic(light: Color(red: 0, green: 0, blue: 0).opacity($0.alpha), dark: white.opacity($0.darkAlpha)))
    })

    // Every tier is in each table by construction; the fallbacks only satisfy the type system.
    static func primary(_ tier: ThemeTier) -> Color { primaryTiers[tier] ?? .clear }
    static func secondary(_ tier: ThemeTier) -> Color { secondaryTiers[tier] ?? .clear }
    static func accent(_ tier: AccentTier) -> Color { accentTiers[tier] ?? .clear }
}

package extension Color {
    /// A colour with a light and a dark member, resolved by the trait collection at draw time. The
    /// platform-native way to carry a `light-dark()` pair. `package`: a public `Color.dynamic`
    /// would collide with the many hosts that define one.
    static func dynamic(light: Color, dark: Color) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
        #else
        return light
        #endif
    }
}

private struct TouchpointThemeKey: EnvironmentKey {
    static let defaultValue = TouchpointTheme.default
}

public extension EnvironmentValues {
    var touchpointTheme: TouchpointTheme {
        get { self[TouchpointThemeKey.self] }
        set { self[TouchpointThemeKey.self] = newValue }
    }
}

public extension View {
    /// Apply Touchpoint theme tokens to this subtree. Scoped to the view hierarchy it is attached
    /// to; nothing process-global happens.
    func touchpointTheme(_ theme: TouchpointTheme) -> some View {
        environment(\.touchpointTheme, theme)
    }
}

/// How the host presents Touchpoint UI. **Only the cases the SDK actually builds**:
/// an unexercised public case is an untested permanent commitment, and this enum becomes immutable
/// at publication. Adding `.fullScreen` or `.navigationPush` later is additive and safe.
public enum TouchpointPresentation: Sendable, Equatable {
    /// Fills whatever container the host provides.
    case embedded
    /// A sheet with the given detents.
    case sheet(detents: Set<PresentationDetent>)

    /// The cases built and tested in v1 — what the test suite enumerates so a new case cannot ship
    /// untested. The detents match the launcher's default.
    package static let allCasesBuilt: [TouchpointPresentation] = [.embedded, .sheet(detents: [.large])]
}

/// Geometry derived from the user's text size. **No absolute typographic or spacing values**
/// anywhere in the UI: everything here is a multiple of the current Dynamic Type scale, which
/// is what keeps a transcript usable at accessibility sizes instead of clipping. The base values are
/// the web SDK's pixel values (`web-design-catalogue.md`), so at the default text size the two
/// products share geometry.
package struct TranscriptMetrics: Sendable, Equatable {
    /// `1.0` at the default text size; grows with the user's setting.
    package let scale: CGFloat
    private let innerBase: CGFloat
    private let outerBase: CGFloat
    /// The theme's `fontFamily`, carried so the text accessors can pick the face. `nil` is the
    /// platform face. See ``textFont(_:)``.
    package let fontFamily: String?

    package init(scale: CGFloat, theme: TouchpointTheme = .default) {
        self.scale = max(scale, 0.1)
        innerBase = theme.innerCornerRadius
        outerBase = theme.outerCornerRadius
        fontFamily = theme.fontFamily
    }

    /// Dynamic Type → metric scale. Derived from the category rather than a literal point size, so
    /// the whole layout grows with the user's setting.
    package static func scale(for size: DynamicTypeSize) -> CGFloat {
        switch size {
        case .xSmall: 0.85
        case .small: 0.9
        case .medium: 0.95
        case .large: 1.0
        case .xLarge: 1.1
        case .xxLarge: 1.2
        case .xxxLarge: 1.3
        case .accessibility1: 1.6
        case .accessibility2: 1.9
        case .accessibility3: 2.2
        case .accessibility4: 2.5
        case .accessibility5: 2.8
        @unknown default: 1.0
        }
    }

    /// Control geometry stops growing at 1.6×, where text and the space around text keep scaling
    /// linearly.
    ///
    /// **Settled deviation** (owner's decision). Web has no Dynamic Type at all,
    /// so there is no parity answer to copy and this is an iOS-only choice either way. At the
    /// largest accessibility size the raw factor is 2.5×, which makes a 40pt icon button 100pt and
    /// leaves a four-item voice rail unable to fit a phone's width.
    ///
    /// The alternative considered and rejected was scaling controls linearly and letting them wrap:
    /// it honours the setting literally, but reflows the rail mid-call, wraps the header, and
    /// squeezes a fixed-height docked panel — the failure mode that starved the transcript to zero
    /// height once already.
    ///
    /// What makes the cap acceptable rather than merely convenient: every icon-only control carries
    /// the Large Content Viewer, so a long press shows its label at full size. That is applied by
    /// `TouchpointIconButtonStyle` itself and by the launch button, so no call site can forget it.
    package var controlScale: CGFloat { min(scale, 1.6) }

    // Radii (theme-driven, scaled)
    package var innerRadius: CGFloat { innerBase * scale }
    package var outerRadius: CGFloat { outerBase * scale }

    // Transcript
    package var bubbleHorizontalPadding: CGFloat { 12 * scale }
    package var bubbleVerticalPadding: CGFloat { 8 * scale }
    package var bubbleSpacing: CGFloat { 8 * scale }
    /// Between one response and the next.
    package var responseSpacing: CGFloat { 32 * scale }
    /// Between messages inside one response.
    package var messageSpacing: CGFloat { 8 * scale }
    /// Web is 8px below its 768px breakpoint (`Messages.tsx:522`), and that breakpoint never
    /// applies on an iPhone, so the SDK takes the small-screen value everywhere.
    package var transcriptPadding: CGFloat { 8 * scale }
    /// The transcript's side inset: message text lines up with the header's restart and minimise
    /// glyphs — the bar's inset plus the glyph's inset inside its 40pt button, 8 + 12 = 20 at the
    /// default size. **Deviation from web**, which uses 8px below 768px; product asked for the
    /// alignment, and at 8 the text crowded the panel's edges on a phone.
    package var transcriptHorizontalPadding: CGFloat { controlPadding + (iconButtonDiameter - iconGlyphSize) / 2 }
    /// Web's floating window sits 8px off the viewport edges (`App.tsx`, `m-2`).
    package var floatingWindowMargin: CGFloat { 8 * scale }
    /// Web's settings column caps at `max-w-[420px]` (`Settings.tsx`).
    package var settingsMaxWidth: CGFloat { 420 * scale }
    /// Web's end confirmation card (`EndConversationConfirm.tsx`): `max-w-sm`, `p-4` (also the
    /// veil's inset), `space-y-6` between its parts, `space-y-2` between its buttons, and a
    /// `size-5` warning glyph.
    package var confirmCardMaxWidth: CGFloat { 384 * scale }
    package var confirmCardPadding: CGFloat { 16 * scale }
    package var confirmSectionSpacing: CGFloat { 24 * scale }
    package var confirmWarningSize: CGFloat { 20 * controlScale }
    package var composerSpacing: CGFloat { 8 * scale }
    /// Empty space a user message leaves on its leading side (web 8cebb4d `pl-12`).
    package var userGutter: CGFloat { 48 * scale }
    /// Empty space a bubbled agent message leaves on its trailing side (web `mr-10`).
    package var agentBubbleTrailingMargin: CGFloat { 40 * scale }
    package var statusGlyphSize: CGFloat { 14 * scale }
    /// The avatar column under participant info (web `w-6`). The avatar sits at its leading edge.
    package var avatarSize: CGFloat { 24 * scale }
    /// An icon avatar's disc (web `size-5`) and an image avatar (web `size-4`).
    package var avatarIconSize: CGFloat { 20 * scale }
    package var avatarImageSize: CGFloat { 16 * scale }
    /// The avatar's drop to centre on the name's first line (web `mt-0.5`).
    package var avatarTopInset: CGFloat { 2 * scale }
    /// Avatar column → content, and avatar → "You" (web `gap-2`).
    package var avatarGap: CGFloat { 8 * scale }
    /// The delivery row's inset from the message's edge (web `pr-1` / `pl-1`).
    package var statusRowInset: CGFloat { 4 * scale }
    /// Width of the shimmer's light band (web: 80px).
    package var shimmerBandWidth: CGFloat { 80 * scale }

    // Modalities (web `CustomCard.tsx`, `DefaultVideo.tsx`)
    /// A card is `w-80`; on a phone it is held to the transcript's width.
    package var modalityCardWidth: CGFloat { 320 * scale }
    /// The card's image row is `h-52`.
    package var modalityCardImageHeight: CGFloat { 208 * scale }
    /// Card rows are `px-3 py-4`.
    package var modalityCardRowHorizontalPadding: CGFloat { 12 * scale }
    package var modalityCardRowVerticalPadding: CGFloat { 16 * scale }
    /// The video's play button is `h-14 w-14`.
    package var modalityPlayButtonDiameter: CGFloat { 56 * controlScale }
    /// Web's upload chip: the 16pt status slot (`w-4 h-4`) and its 6pt pulsing dot (`w-1.5 h-1.5`).
    package var attachmentStatusSize: CGFloat { 16 * controlScale }
    package var attachmentPulseDot: CGFloat { 6 * controlScale }
    /// The selected card's border (`border-accent`) is the 1px border at accent colour (c34).
    package var modalitySelectedBorderWidth: CGFloat { hairline }

    // Controls (capped, see `controlScale`)
    package var iconButtonDiameter: CGFloat { 40 * controlScale }
    package var compactIconButtonDiameter: CGFloat { 32 * controlScale }
    /// The glyph is sized by font, the only lever an SF Symbol offers. Weight medium matches the
    /// web icons' 1.5px strokes in a 16px box.
    package var iconFont: Font { .system(size: 16 * controlScale, weight: .medium) }
    package var compactIconFont: Font { .system(size: 12 * controlScale, weight: .medium) }
    /// The icon box in a compact (32pt) icon button.
    package var compactIconGlyphSize: CGFloat { 12 * controlScale }
    /// Web's `Play size={28}` inside the 56pt play disc.
    package var modalityPlayGlyphSize: CGFloat { 28 * controlScale }
    /// The icon in an icon avatar (web `size-3.5`).
    package var avatarGlyphSize: CGFloat { 14 * scale }
    /// Row gap and inset inside a control shell.
    package var controlPadding: CGFloat { 8 * scale }
    package var controlPaddingWide: CGFloat { 12 * scale }
    package var controlGap: CGFloat { 4 * scale }
    /// Inset inside the composer's pill. The trailing control's 44pt hit frame already pads a 40pt
    /// circle by 2, so the shell adds the remainder to land on the web's 8.
    /// Web's composer shell is a plain 8px (`Input.tsx:225`). It needed no compensation once the
    /// 44pt hit area stopped inflating control layout.
    package var composerShellPadding: CGFloat { controlPadding }
    // MARK: Typography (web `Theme.tsx` / `index.css`; the catalogue's typography section)
    //
    // Web is one font stack at a handful of fixed sizes, almost all regular (400). These are those
    // sizes, multiplied by the same Dynamic Type factor as the rest of the grid so the SDK still
    // scales where web cannot.
    //
    // HONEST LIMIT: web pairs each size with a line height (16/24, 14/20, 12/16, 18/28, 20/28).
    // SwiftUI on iOS 17 cannot set line height directly — `lineSpacing` adds *between* lines and
    // nothing above the first — so the size is matched exactly and the leading is approached via
    // `bodyLineSpacing`. Do not assert an exact 24pt line box; it is not reachable.

    /// `text-base` 16/24: message bodies, the composer, notices, errors, participant names.
    package var bodyFont: Font { textFont(16) }
    /// `text-sm` 14/20: secondary text.
    package var smallFont: Font { textFont(14) }
    /// `text-xs` 12/16: status rows, badges, tooltips.
    package var captionFont: Font { textFont(12) }
    /// `text-lg` 18/28: the welcome greeting.
    package var greetingFont: Font { textFont(18) }
    /// `text-xl` 20/28: dialog and ended-conversation titles.
    package var titleFont: Font { textFont(20) }

    /// A **text** font at `base` points times the Dynamic Type `scale`, in the theme's face.
    ///
    /// The face is the theme's `fontFamily` (OP-6), or the platform font when unset. Only text
    /// routes through here; SF Symbol glyphs keep `.system` so a refaced theme does not reface an
    /// icon it has no glyph for.
    ///
    /// **Deviation (OP-6).** The brief suggested `Font.custom(_:size:relativeTo:)`, which scales the
    /// given size a second time by the current Dynamic Type category. This grid already folds
    /// Dynamic Type into `scale` (see `scale(for:)`), and `size` is pre-scaled by it; `relativeTo`
    /// would compound it, and worse, put text on SwiftUI's scaling curve while spacing stays on this
    /// grid's — the two drift apart at accessibility sizes, the misalignment scaled metrics guard against.
    /// `custom(_:fixedSize:)` applies the face at exactly the scaled size, so text and spacing grow
    /// together. Web has no Dynamic Type, so there is no parity answer to copy either way.
    package func textFont(_ base: CGFloat) -> Font {
        let size = base * scale
        guard let fontFamily, !fontFamily.isEmpty else { return .system(size: size) }
        return .custom(fontFamily, fixedSize: size)
    }
    /// The gap that takes a 16pt line towards web's 24pt leading. A 16pt system line box is ~19pt,
    /// so this is the remainder rather than the whole leading.
    package var bodyLineSpacing: CGFloat { 5 * scale }

    // Welcome screen (`App.tsx:852-900`)
    /// `gap-6` between the logo, the greeting and the lifted composer.
    package var welcomeSpacing: CGFloat { 24 * scale }
    /// `space-y-4` between the greeting's own messages.
    package var welcomeMessageSpacing: CGFloat { 16 * scale }
    /// `w-12 h-12` host brand logo.
    package var welcomeLogoSize: CGFloat { 48 * controlScale }
    /// Web's `Loader` is `w-8 h-8` with its label `gap-3` below; the voice rail's is `w-6 h-6`.
    package var loaderSize: CGFloat { 32 * controlScale }
    package var compactLoaderSize: CGFloat { 24 * controlScale }
    package var loaderLabelGap: CGFloat { 12 * scale }

    /// Web's icon glyph is 16px inside a 40px button (`ui/IconButton.tsx`); the launch disc draws
    /// the mark larger.
    package var iconGlyphSize: CGFloat { 16 * controlScale }
    /// Web's launch glyph is 32×32 inside 12px padding (`ui/LaunchButton.tsx:32`), which is what
    /// makes the button 56 tall.
    package var launchGlyphSize: CGFloat { 32 * controlScale }
    /// Web's `TextButton`: 20px horizontal / 16px vertical (`ui/TextButton.tsx`).
    package var textButtonHorizontalPadding: CGFloat { 20 * scale }
    package var textButtonVerticalPadding: CGFloat { 16 * scale }
    /// Web's text button is 56 tall at the default size: `py-4` around a 24px line (design QA c08).
    /// Ours is shorter by the line-height difference, so the floor is stated; padding grows it past
    /// that at larger text sizes.
    package var textButtonMinHeight: CGFloat { 56 * scale }
    package var chipHorizontalPadding: CGFloat { 12 * scale }
    package var chipVerticalPadding: CGFloat { 8 * scale }
    /// Between markdown blocks: web's `space-y-6` on the rendered container (`Messages.tsx:703`).
    package var markdownBlockSpacing: CGFloat { 24 * scale }
    /// Between a list marker and its text, and between table cells vertically. Web gets this from
    /// `list-inside`, where the marker sits in the text flow followed by a space.
    package var markdownMarkerSpacing: CGFloat { 6 * scale }
    package var hairline: CGFloat { 1 }
    package var rippleRingWidth: CGFloat { 2 }
    package var launchButtonSize: CGFloat { 56 * controlScale }
    /// Inset inside the launch button. Capped with the control, so the glyph stays centred in a
    /// 56pt disc instead of the padding outgrowing it.
    package var launchPadding: CGFloat { 12 * controlScale }
    package var launchGlyphFont: Font { .system(size: 32 * controlScale, weight: .regular) }

    // MARK: Voice full screen (web `FullscreenVoice.tsx`, `VoiceModalities.tsx`)
    //
    // Web's voice call is a fixed layout — the orb is `w-[128px] h-[128px] p-4`, its glyph fills the
    // rest; the state screens draw the mark at `w-20 h-20` (80) with `gap-6` (24) stacks; the mic
    // bar is `py-4` (16). The orb and its glyph follow `controlScale` (capped at 1.6×) so a focal
    // 128pt disc does not become a 358pt one at the largest accessibility size; spacing follows the
    // full text scale like the rest of the grid.
    /// Web's VoiceIcon disc: `w-[128px] h-[128px]`.
    package var voiceOrbSize: CGFloat { 128 * controlScale }
    /// `p-4` inside the orb, around its glyph.
    package var voiceOrbPadding: CGFloat { 16 * controlScale }
    /// The state screens' mark (ended / error): web's `w-20 h-20`.
    package var voiceStateGlyphSize: CGFloat { 80 * controlScale }
    /// `py-4` above and below the microphone control.
    package var voiceBarPadding: CGFloat { 16 * scale }
    /// `gap-6` between the parts of a state screen, and around the orb.
    package var voiceScreenSpacing: CGFloat { 24 * scale }
    /// Web's Retry bar is `h-20` (80) with the button capped at `max-w-content`.
    package var voiceRetryBarHeight: CGFloat { 80 * scale }

    /// Apple HIG and WCAG 2.5.5 (AAA) floor — AA's own requirement (2.5.8) is only 24pt, so this
    /// is deliberately stricter. A **floor**: it never drops below 44pt, and never grows with text,
    /// because a tap target does not need to.
    package var minimumTapTarget: CGFloat { 44 }
}
