import SwiftUI
import Testing
@testable import TouchpointCore

@Suite("Theme and presentation")
@MainActor
struct ThemeTests {
    private func resolve(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        return color.resolve(in: env)
    }

    // MARK: Tiers (T1, T2)

    @Test("Both of the web SDK's tier ladders, strictly decreasing — dark is bumped at every tier above 5")
    func tierLadder() {
        // `Theme.tsx:53-98`: the dark defaults are not the light ones, which is why the SDK carries
        // two ladders and resolves them per scheme.
        let light = ThemeTier.allCases.map(\.alpha)
        let dark = ThemeTier.allCases.map(\.darkAlpha)
        #expect(light == [0.9, 0.8, 0.6, 0.4, 0.2, 0.1, 0.03, 0.01])
        #expect(dark == [0.95, 0.85, 0.65, 0.45, 0.25, 0.12, 0.03, 0.01])
        for (a, b) in zip(light, light.dropFirst()) { #expect(b < a) }
        for (a, b) in zip(dark, dark.dropFirst()) { #expect(b < a) }
        for (l, d) in zip(light, dark) { #expect(d >= l) }
        #expect(AccentTier.allCases.map(\.alpha) == [0.5, 0.2])
    }

    @Test("Default ink resolves to web's pairs: the bump follows the white ink — primary in dark, secondary in light")
    func defaultInkLadders() {
        let t = TouchpointTheme.default
        for tier in ThemeTier.allCases {
            let pL = resolve(t.primary(tier), .light), pD = resolve(t.primary(tier), .dark)
            let sL = resolve(t.secondary(tier), .light), sD = resolve(t.secondary(tier), .dark)
            #expect(abs(Double(pL.opacity) - tier.alpha) < 0.005, "primary \(tier) light \(pL.opacity)")
            #expect(abs(Double(pD.opacity) - tier.darkAlpha) < 0.005, "primary \(tier) dark \(pD.opacity)")
            #expect(abs(Double(sL.opacity) - tier.darkAlpha) < 0.005, "secondary \(tier) light \(sL.opacity)")
            #expect(abs(Double(sD.opacity) - tier.alpha) < 0.005, "secondary \(tier) dark \(sD.opacity)")
            // Black where web is black, white where it is white.
            #expect(Double(pL.red) < 0.01 && Double(pD.red) > 0.99)
            #expect(Double(sL.red) > 0.99 && Double(sD.red) < 0.01)
        }
        // Web writes tier 80's black as its ink, rgb(0,2,9).
        #expect(abs(Double(resolve(t.primary(.t80), .light).blue) - 9 / 255) < 0.01)
        for tier in AccentTier.allCases {
            #expect(abs(Double(resolve(t.accent(tier), .light).opacity) - tier.alpha) < 0.005)
            #expect(abs(Double(resolve(t.accent(tier), .dark).opacity) - tier.darkAlpha) < 0.005)
        }
        #expect(AccentTier.allCases.map(\.darkAlpha) == [0.55, 0.25])
    }

    @Test("A tier is the base colour at that alpha — hierarchy comes from alpha, not hue")
    func tierResolvesToBaseAtAlpha() {
        // A host-set ink gets web's derived ladder in every scheme, with no bump.
        var t = TouchpointTheme()
        t.primary = Color(red: 0.2, green: 0.4, blue: 0.6)
        t.secondary = Color(red: 0.7, green: 0.7, blue: 0.7)
        t.accent = Color(red: 0.9, green: 0.1, blue: 0.1)
        for tier in ThemeTier.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let r = resolve(t.primary(tier), scheme)
                #expect(abs(Double(r.red) - 0.2) < 0.01 && abs(Double(r.green) - 0.4) < 0.01 && abs(Double(r.blue) - 0.6) < 0.01)
                #expect(abs(Double(r.opacity) - tier.derivedAlpha) < 0.005, "tier \(tier) alpha \(r.opacity)")
                #expect(abs(Double(resolve(t.secondary(tier), scheme).opacity) - tier.derivedAlpha) < 0.005)
            }
        }
        #expect(ThemeTier.t5.derivedAlpha == 0.05, "web derives 5% at tier 5 from a host colour")
        let a = resolve(t.accent(.t20), .dark)
        #expect(abs(Double(a.red) - 0.9) < 0.01 && abs(Double(a.opacity) - 0.2) < 0.005)
        // Setting the default value explicitly is still a host-set ink, as it is on web.
        var explicit = TouchpointTheme()
        explicit.primary = TouchpointTheme.Defaults.primary
        #expect(abs(Double(resolve(explicit.primary(.t60), .dark).opacity) - 0.6) < 0.005)
        #expect(explicit != TouchpointTheme.default)
    }

    // MARK: Defaults (T3, T5, T7)

    @Test("Defaults are dynamic: ink is near-black in light and near-white in dark, the inverse for secondary")
    func defaultsFollowScheme() {
        let t = TouchpointTheme.default
        let pL = resolve(t.primary, .light), pD = resolve(t.primary, .dark)
        #expect(Double(pL.red) < 0.05 && Double(pL.green) < 0.05 && Double(pL.blue) < 0.08)
        #expect(Double(pD.red) > 0.95 && Double(pD.green) > 0.95 && Double(pD.blue) > 0.95)
        let sL = resolve(t.secondary, .light), sD = resolve(t.secondary, .dark)
        #expect(Double(sL.red) > 0.95)
        #expect(Double(sD.red) < 0.05)
        // Glass is the default, with web's fill: light #F2F2F2 @ 90%, dark #1B1B21 @ 95%.
        let bL = resolve(t.background, .light), bD = resolve(t.background, .dark)
        #expect(abs(Double(bL.red) - 242 / 255) < 0.01 && abs(Double(bL.opacity) - 0.9) < 0.01)
        #expect(abs(Double(bD.red) - 27 / 255) < 0.01 && abs(Double(bD.blue) - 33 / 255) < 0.01 && abs(Double(bD.opacity) - 0.95) < 0.01)
        // The flat deviation is opaque: a card, not a pane.
        let f = TouchpointTheme(surface: .flat)
        let fL = resolve(f.background, .light), fD = resolve(f.background, .dark)
        #expect(Double(fL.red) > 0.99 && Double(fL.green) > 0.99 && Double(fL.blue) > 0.99 && Double(fL.opacity) > 0.99)
        #expect(abs(Double(fD.red) - 27 / 255) < 0.01 && abs(Double(fD.blue) - 33 / 255) < 0.01 && Double(fD.opacity) > 0.99)
    }

    @Test("Accent is understated by default — the default ink, fixed — and only a host-set accent counts as brand intent")
    func accentIsUnderstated() {
        let d = TouchpointTheme.default
        #expect(!d.accentIsBrand && !d.backgroundIsBrand)
        #expect(resolve(d.accent, .light) == resolve(TouchpointTheme.Defaults.primary, .light))
        #expect(resolve(d.accent, .dark) == resolve(TouchpointTheme.Defaults.primary, .dark))
        // Like the web, the default accent does not follow a host's primary: brand colour is opt-in.
        var inked = d
        inked.primary = .blue
        #expect(!inked.accentIsBrand)
        #expect(resolve(inked.accent, .light) == resolve(TouchpointTheme.Defaults.primary, .light))
        #expect(resolve(TouchpointTheme(primary: .blue).accent, .light) == resolve(TouchpointTheme.Defaults.primary, .light))
        // Init and mutation agree.
        var branded = TouchpointTheme()
        branded.accent = .purple
        #expect(branded.accentIsBrand)
        #expect(TouchpointTheme(accent: .orange).accentIsBrand)
        #expect(TouchpointTheme(background: .black).backgroundIsBrand)
        var surfaced = d
        surfaced.background = .black
        #expect(surfaced.backgroundIsBrand)
        // Assigning the current value is still an assignment — the host chose it (documented).
        var same = d
        same.accent = same.accent
        #expect(same.accentIsBrand)
    }

    @Test("Color.dynamic picks the member matching the colour scheme")
    func dynamicColor() {
        let c = Color.dynamic(light: Color(red: 1, green: 0, blue: 0), dark: Color(red: 0, green: 0, blue: 1))
        #expect(Double(resolve(c, .light).red) > 0.95)
        #expect(Double(resolve(c, .dark).blue) > 0.95)
    }

    // MARK: Contrast floor (T4)

    @Test("Tier 60 ink over the default surface clears WCAG AA in both schemes; tier 80 clears AAA")
    func aaFloor() {
        let t = TouchpointTheme.default
        for scheme in [ColorScheme.light, .dark] {
            let page: (r: Double, g: Double, b: Double) = scheme == .light ? (1, 1, 1) : (0, 0, 0)
            let surface = PixelProbe.composite(resolve(t.background, scheme), over: page)
            let ink60 = PixelProbe.composite(resolve(t.primary(.t60), scheme), over: surface)
            let ink80 = PixelProbe.composite(resolve(t.primary(.t80), scheme), over: surface)
            let lSurface = PixelProbe.relativeLuminance(r: surface.r, g: surface.g, b: surface.b)
            let c60 = PixelProbe.contrast(PixelProbe.relativeLuminance(r: ink60.r, g: ink60.g, b: ink60.b), lSurface)
            let c80 = PixelProbe.contrast(PixelProbe.relativeLuminance(r: ink80.r, g: ink80.g, b: ink80.b), lSurface)
            #expect(c60 >= 4.5, "\(scheme) tier60 contrast \(c60)")
            #expect(c80 >= 7, "\(scheme) tier80 contrast \(c80)")
        }
    }

    @Test("Text tiers never drop below 60 — the AA floor is a type-level fact")
    func textTiersFloor() {
        for tier in ThemeTier.textTiers { #expect(tier.alpha >= 0.6, "\(tier) is not text-safe") }
        #expect(ThemeTier.textTiers.contains(.t60))
        #expect(!ThemeTier.textTiers.contains(.t40))
    }

    // MARK: Overrides and environment

    @Test("A host overrides one token without losing the rest")
    func partialOverride() {
        var t = TouchpointTheme.default
        t.accent = .purple
        #expect(t.accent == .purple)
        #expect(t.background == TouchpointTheme.default.background)
        #expect(t.innerCornerRadius == TouchpointTheme.default.innerCornerRadius)
    }

    @Test("The theme travels through the SwiftUI environment, never through UIAppearance")
    func environmentPropagation() {
        #expect(EnvironmentValues().touchpointTheme == TouchpointTheme.default)
        var custom = TouchpointTheme.default
        custom.accent = .pink
        var values = EnvironmentValues()
        values.touchpointTheme = custom
        #expect(values.touchpointTheme.accent == .pink)
    }

    @Test("No colour token is expressed as a hex string anywhere in the public surface")
    func noHexStrings() {
        // A hex string cannot carry a light and dark pair. Colour tokens are `Color`; the only
        // non-Color stored properties are the two radii, the surface style, the depth-layer flag
        // and the optional font-family name (OP-6).
        let mirror = Mirror(reflecting: TouchpointTheme.default)
        var colors = 0
        for child in mirror.children {
            let label = child.label ?? "?"
            if child.value is Color || child.value is Color? { colors += 1; continue }
            if child.value is TouchpointTheme.SurfaceStyle { #expect(label == "surface"); continue }
            if child.value is Bool { #expect(label == "backgroundDepthLayer"); continue }
            // `fontFamily` is a face name, never a colour: it cannot encode one, so it is exempt.
            if child.value is String || child.value is String? { #expect(label == "fontFamily"); continue }
            #expect(child.value is CGFloat, "token \(label) is \(type(of: child.value))")
            #expect(label.contains("Radius"), "unexpected non-colour token \(label)")
        }
        #expect(colors >= 11)
    }

    // MARK: Radii and metrics (T6)

    @Test("Two radii, web values, scaled with text like every other dimension")
    func radii() {
        let t = TouchpointTheme.default
        #expect(t.innerCornerRadius == 20)
        #expect(t.outerCornerRadius == 28)
        let m1 = TranscriptMetrics(scale: 1, theme: t), m2 = TranscriptMetrics(scale: 2, theme: t)
        #expect(m1.innerRadius == 20 && m2.innerRadius == 40)
        #expect(m1.outerRadius == 28 && m2.outerRadius == 56)
        var custom = t
        custom.innerCornerRadius = 8
        #expect(TranscriptMetrics(scale: 1, theme: custom).innerRadius == 8)
    }

    @Test("Control geometry scales linearly; the 44pt tap target is a floor at every scale")
    func metricsScale() {
        let small = TranscriptMetrics(scale: 1.0)
        let huge = TranscriptMetrics(scale: 3.0)
        #expect(small.iconButtonDiameter == 40 && small.compactIconButtonDiameter == 32)
        #expect(small.controlPadding == 8 && small.controlPaddingWide == 12 && small.controlGap == 4)
        #expect(small.statusGlyphSize == 14 && huge.statusGlyphSize == 42)
        #expect(small.userGutter == 48 && small.responseSpacing == 32 && small.messageSpacing == 8)
        #expect(small.launchButtonSize == 56 && small.hairline == 1 && small.rippleRingWidth == 2)
        #expect(small.chipHorizontalPadding == 12 && small.chipVerticalPadding == 8)
        #expect(small.shimmerBandWidth == 80)
        #expect(huge.bubbleHorizontalPadding > small.bubbleHorizontalPadding)
        // Controls stop growing at the first accessibility size (1.6×): a rail of four 112pt
        // buttons would not fit a phone. Text and spacing keep scaling.
        #expect(huge.controlScale == 1.6)
        #expect(huge.iconButtonDiameter == 64 && huge.launchButtonSize == 56 * 1.6)
        #expect(TranscriptMetrics(scale: 1.3).controlScale == 1.3)
        #expect(huge.responseSpacing == 96)
        #expect(huge.minimumTapTarget == small.minimumTapTarget)
        #expect(small.minimumTapTarget >= 44)
        #expect(TranscriptMetrics(scale: 0.5).minimumTapTarget == 44)
    }

    // MARK: Unchanged from

    @Test("Presentation has exactly the cases we build: embedded and sheet")
    func presentationCases() {
        #expect(TouchpointPresentation.allCasesBuilt.count == 2)
        #expect(TouchpointPresentation.embedded == .embedded)
        let sheet = TouchpointPresentation.sheet(detents: [.medium, .large])
        if case .sheet(let detents) = sheet { #expect(detents.count == 2) } else { Issue.record("expected sheet") }
    }

    @Test("Every user-facing string the UI needs resolves through the catalog")
    func stringsResolve() {
        for s in [TouchpointStrings.composerPlaceholder, TouchpointStrings.sendButtonLabel,
                  TouchpointStrings.transcriptLabel, TouchpointStrings.agentSenderLabel,
                  TouchpointStrings.youSenderLabel, TouchpointStrings.statusSending,
                  TouchpointStrings.statusSent, TouchpointStrings.statusDelivered,
                  TouchpointStrings.statusRead, TouchpointStrings.statusFailed,
                  TouchpointStrings.retryButtonLabel, TouchpointStrings.loadEarlierLabel,
                  TouchpointStrings.closeButtonLabel, TouchpointStrings.connectingStatus,
                  TouchpointStrings.reconnectingStatus, TouchpointStrings.endedStatus] {
            #expect(!s.isEmpty)
            #expect(!s.hasPrefix("touchpoint."), "unresolved catalog key: \(s)")
        }
    }

    @Test("Delivery state has a localised, non-empty accessibility description for each case")
    func deliveryStateDescriptions() {
        for state in DeliveryState.allCases {
            #expect(!state.accessibilityDescription.isEmpty)
        }
        #expect(DeliveryState.failed.accessibilityDescription != DeliveryState.sent.accessibilityDescription)
    }
}
