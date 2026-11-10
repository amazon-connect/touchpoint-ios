import SwiftUI
import Testing
@testable import TouchpointCore

/// The surface, the control styles and the ambient motion that give the SDK the web
/// product's look. Rendered through `ImageRenderer`, measured as properties.
@Suite("Design system", .serialized)
@MainActor
struct DesignSystemTests {
    /// The layer tests below describe the `.glass` treatment (wash, sheen, grain), so they render
    /// it explicitly; `.flat` is the default and has its own test.
    private var glass: TouchpointTheme { TouchpointTheme(surface: .glass) }
    private var hostTheme: TouchpointTheme {
        var t = glass
        t.background = Color(red: 0.1, green: 0.1, blue: 0.1)
        return t
    }

    // MARK: Surface (T8)

    @Test("The surface is opaque enough to read as a panel, and follows the colour scheme")
    func surfaceIsOpaqueAndSchemed() throws {
        let light = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(glass), width: 390, height: 300, colorScheme: .light))
        let dark = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(glass), width: 390, height: 300, colorScheme: .dark))
        #expect(light.transparentFraction() == 0)
        #expect(dark.transparentFraction() == 0)
        let lL = light.meanLuminance(), lD = dark.meanLuminance()
        #expect(lL > 0.8, "light surface luminance \(lL)")
        #expect(lD < 0.2, "dark surface luminance \(lD)")
    }

    @Test("Glass is the default, and the flat deviation is a solid card with none of its layers")
    func flatIsOptInAndSolid() throws {
        #expect(TouchpointTheme.default.surface == .glass, "web has one surface; it is the default")
        let flat = TouchpointTheme(surface: .flat)
        for scheme in [ColorScheme.light, .dark] {
            // Rendered inset so the shadow has somewhere to fall; the card itself is sampled.
            let p = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(flat).padding(40), width: 390, height: 300, colorScheme: scheme))
            // No wash: no blue bias from one side of the card to the other.
            #expect(abs(blueBias(p, xRange: 0.75...0.85) - blueBias(p, xRange: 0.15...0.25)) < 0.005, "\(scheme) flat card carries a wash")
            // No grain: adjacent pixels in the card are identical.
            let a = p.rgba(x: p.width / 2, y: p.height / 2), b = p.rgba(x: p.width / 2 + 1, y: p.height / 2)
            #expect(abs(a.r - b.r) < 0.002 && abs(a.g - b.g) < 0.002 && abs(a.b - b.b) < 0.002, "\(scheme) flat card has grain")
            // Lifted: the shadow darkens the host just outside the card's top edge.
            let outside = p.rgba(x: p.width / 2, y: 30), far = p.rgba(x: p.width / 2, y: 2)
            #expect(outside.a > far.a + 0.01, "\(scheme) no shadow above the card")
        }
    }

    /// Blue minus red over a band — the wash is the only blue-biased layer.
    private func blueBias(_ p: PixelProbe.Pixels, xRange: ClosedRange<Double>, yRange: ClosedRange<Double> = 0.4...0.56) -> Double {
        var blue = 0.0, red = 0.0, n = 0.0
        let x0 = Int(Double(p.width) * xRange.lowerBound), x1 = Int(Double(p.width) * xRange.upperBound)
        let y0 = Int(Double(p.height) * yRange.lowerBound), y1 = Int(Double(p.height) * yRange.upperBound)
        for y in y0..<y1 { for x in x0..<x1 { let c = p.rgba(x: x, y: y); blue += c.b; red += c.r; n += 1 } }
        return (blue - red) / n
    }

    @Test("The default surface carries the right-edge wash in both schemes; a host-set background drops it (web rule)")
    func washFollowsBrandIntent() throws {
        for scheme in [ColorScheme.light, .dark] {
            let themed = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(glass), width: 390, height: 300, colorScheme: scheme))
            #expect(blueBias(themed, xRange: 0.85...1.0) > blueBias(themed, xRange: 0.0...0.15) + 0.01, "\(scheme)")
            // The ellipse is the full height tall: still visible near the right edge at 90% height.
            #expect(blueBias(themed, xRange: 0.9...1.0, yRange: 0.86...0.94) > blueBias(themed, xRange: 0.0...0.15) + 0.005, "\(scheme) wash too short")
            let plain = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(hostTheme), width: 390, height: 300, colorScheme: scheme))
            #expect(abs(blueBias(plain, xRange: 0.85...1.0) - blueBias(plain, xRange: 0.0...0.15)) < 0.005, "\(scheme)")
        }
    }

    @Test("Depth: the sheen lights the top-left more than the top-right in the same row — only the sheen can do that")
    func surfaceHasDepth() throws {
        // A host background drops the wash, and the shade is constant across a row, so a left/right
        // difference in one row is the sheen alone.
        let p = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(hostTheme), width: 390, height: 300, colorScheme: .dark))
        let left = p.meanLuminance(xRange: 0...0.15, yRange: 0.05...0.15)
        let right = p.meanLuminance(xRange: 0.85...1.0, yRange: 0.05...0.15)
        #expect(left > right + 0.005, "left \(left) right \(right)")
        // And the shade: the same column is darker at the bottom than the top.
        let top = p.meanLuminance(xRange: 0.45...0.55, yRange: 0.0...0.1)
        let bottom = p.meanLuminance(xRange: 0.45...0.55, yRange: 0.9...1.0)
        #expect(top > bottom, "top \(top) bottom \(bottom)")
    }

    @Test("A bordered, shaped surface is clipped to the shape and draws the hairline")
    func borderedSurface() throws {
        let surface = TouchpointSurface(in: RoundedRectangle(cornerRadius: 28), bordered: true)
        let p = try #require(PixelProbe.render(surface, width: 200, height: 100, colorScheme: .light))
        // Clipped: the very corner pixel is outside a 28pt radius, so it holds at most the flat
        // card's soft shadow — never the fill.
        #expect(p.rgba(x: 0, y: 0).a < 0.3)
        #expect(p.rgba(x: p.width / 2, y: p.height / 2).a > 0.9)
        // Hairline: the top edge mid-row is darker than the row just inside it (tier-10 ink).
        let edge = p.meanLuminance(xRange: 0.4...0.6, yRange: 0.0...0.01, overWhite: true)
        let inside = p.meanLuminance(xRange: 0.4...0.6, yRange: 0.06...0.1, overWhite: true)
        #expect(edge < inside - 0.02, "edge \(edge) inside \(inside)")
    }

    @Test("Tier-60 ink over the finished surface (wash and all) still clears AA at the washed edge")
    func inkOverRenderedSurfaceClearsAA() throws {
        let t = TouchpointTheme.default
        for scheme in [ColorScheme.light, .dark] {
            let p = try #require(PixelProbe.render(TouchpointSurface().touchpointTheme(glass), width: 390, height: 300, colorScheme: scheme))
            // Sample the surface where the wash is strongest.
            let c = p.rgba(x: p.width - 2, y: Int(Double(p.height) * 0.48))
            var env = EnvironmentValues(); env.colorScheme = scheme
            let ink = PixelProbe.composite(t.primary(.t60).resolve(in: env), over: (c.r, c.g, c.b))
            let contrast = PixelProbe.contrast(PixelProbe.relativeLuminance(r: ink.r, g: ink.g, b: ink.b),
                                               PixelProbe.relativeLuminance(r: c.r, g: c.g, b: c.b))
            #expect(contrast >= 4.5, "\(scheme) contrast at the washed edge \(contrast)")
        }
    }

    // MARK: Grain (T9)

    @Test("The grain tile exists, is 160pt at the display scale, seeded (deterministic) and grainy")
    func noiseTile() throws {
        #expect(NoiseTile.shared(pixelsPerPoint: 3) != nil)
        let a = try #require(NoiseTile.image(seed: 7))
        let b = try #require(NoiseTile.image(seed: 7))
        let c = try #require(NoiseTile.image(seed: 8))
        #expect(a.width == 160 && a.height == 160)
        // One sample per device pixel, so the tile is still 160pt wide on a 3x screen.
        let retina = try #require(NoiseTile.image(seed: 7, pixelsPerPoint: 3))
        #expect(retina.width == 480 && retina.height == 480)
        let pa = try #require(PixelProbe.pixels(a)), pb = try #require(PixelProbe.pixels(b)), pc = try #require(PixelProbe.pixels(c))
        #expect(pa.bytes == pb.bytes)
        #expect(pa.bytes != pc.bytes)
        let alphas = stride(from: 3, to: pa.bytes.count, by: 4).map { Int(pa.bytes[$0]) }
        // Grain, not a flat fill.
        #expect((alphas.max() ?? 0) - (alphas.min() ?? 0) > 64)
    }

    @Test("The tile is cached per display scale, so the surface does not regenerate it per frame")
    func noiseTileCached() throws {
        let first = try #require(NoiseTile.shared(pixelsPerPoint: 2))
        let second = try #require(NoiseTile.shared(pixelsPerPoint: 2))
        #expect(first === second)
        let other = try #require(NoiseTile.shared(pixelsPerPoint: 3))
        #expect(first !== other)
    }

    @Test("The grain is a fractal sum, so it is a film rather than hard static")
    func noiseIsFractal() throws {
        // At the density it is actually drawn: one sample per device pixel on a 3x screen.
        let tile = try #require(NoiseTile.image(seed: 7, pixelsPerPoint: 3))
        let p = try #require(PixelProbe.pixels(tile))
        let alphas = (0..<(p.width * p.height)).map { Double(p.bytes[$0 * 4 + 3]) }
        let mean = alphas.reduce(0, +) / Double(alphas.count)
        let sd = (alphas.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(alphas.count)).squareRoot()
        var deltas: [Double] = []
        for y in 0..<p.height {
            for x in 1..<p.width {
                deltas.append(abs(alphas[y * p.width + x] - alphas[y * p.width + x - 1]))
            }
        }
        let meanDelta = deltas.reduce(0, +) / Double(deltas.count)

        // This tile used to be one uniform random byte per pixel: sd 74, and neighbours differing
        // by 86 on average — the maximum contrast noise can have, which on a near-black panel read
        // as hard static rather than the film web paints. Web's `feTurbulence` is a fractal sum
        // (`index.css:277`), which puts most of its energy in the coarsest octave, and the browser
        // evaluates it at device resolution, so neighbouring device pixels sit close together.
        #expect(sd < 50, "grain amplitude \(sd) — too close to uniform noise (74)")
        #expect(meanDelta < 25, "mean neighbour delta \(meanDelta) — too close to uncorrelated (86)")
        // Still grain, not a flat or smoothly-ramped fill.
        #expect(meanDelta > 2)
        #expect(sd > 15)
    }

    @Test("The tile wraps: no seam where it repeats")
    func noiseTileWraps() throws {
        let tile = try #require(NoiseTile.image(seed: 7, pixelsPerPoint: 3))
        let p = try #require(PixelProbe.pixels(tile))
        func alpha(_ x: Int, _ y: Int) -> Double { Double(p.bytes[(y * p.width + x) * 4 + 3]) }
        // The step from the tile's last column to the next tile's first must be no larger than a
        // step within the tile — otherwise the repeat draws a visible grid on the panel.
        var across: [Double] = [], within: [Double] = []
        for y in 0..<p.height {
            across.append(abs(alpha(p.width - 1, y) - alpha(0, y)))
            within.append(abs(alpha(p.width / 2, y) - alpha(p.width / 2 - 1, y)))
        }
        let meanAcross = across.reduce(0, +) / Double(across.count)
        let meanWithin = within.reduce(0, +) / Double(within.count)
        #expect(meanAcross < meanWithin * 3, "seam: \(meanAcross) across the join vs \(meanWithin) within")
    }

    // MARK: Icon buttons (T10)

    private func iconButton(_ variant: TouchpointIconButtonStyle.Variant, size: TouchpointIconButtonStyle.Size = .regular,
                            disabled: Bool = false, scheme: ColorScheme = .light, framed: Bool = true) -> PixelProbe.Pixels? {
        let button = Button {} label: { TouchpointIconView(.close) }
            .buttonStyle(TouchpointIconButtonStyle(variant, size: size))
            .disabled(disabled)
        return framed ? PixelProbe.render(button, width: 60, height: 60, colorScheme: scheme)
                      : PixelProbe.render(button, width: nil, colorScheme: scheme)
    }

    @Test("An icon button is a 40pt circle (compact 32) and occupies 40pt in layout, as web does")
    func iconButtonGeometry() throws {
        let p = try #require(iconButton(.subtle))
        let bounds = try #require(p.inkBounds(scale: 2, minAlpha: 0.02))
        #expect(abs(bounds.width - 40) <= 1.5 && abs(bounds.height - 40) <= 1.5, "visual \(bounds)")
        let compact = try #require(iconButton(.subtle, size: .compact))
        let cb = try #require(compact.inkBounds(scale: 2, minAlpha: 0.02))
        #expect(abs(cb.width - 32) <= 1.5 && abs(cb.height - 32) <= 1.5, "compact \(cb)")
        // Unframed, the layout size is web's 40pt disc (80 px at 2×) — NOT the 44pt tap floor. The
        // floor is met by an outset hit shape, which does not participate in layout; inflating the
        // frame made a header 60 tall and pushed web's 8pt gaps to 12.
        let loose = try #require(iconButton(.subtle, framed: false))
        #expect(loose.width == 80 && loose.height == 80, "\(loose.width)×\(loose.height)")
    }

    @Test("The glyph renders near the web's 16pt box (12pt compact)")
    func glyphSize() throws {
        let ghost = try #require(iconButton(.ghost))
        let g = try #require(ghost.inkBounds(scale: 2, minAlpha: 0.1))
        // Web's Close spans x 5…19 of its 24-unit box: 14/24 of 16pt is 9.3pt, of 12pt is 7pt.
        #expect(abs(g.width - 16 * 14 / 24) <= 1, "regular glyph \(g)")
        let compact = try #require(iconButton(.ghost, size: .compact))
        let c = try #require(compact.inkBounds(scale: 2, minAlpha: 0.1))
        #expect(abs(c.width - 12 * 14 / 24) <= 1 && c.width < g.width, "compact glyph \(c)")
    }

    @Test("Variants: ghost/selected/unselected have no fill, subtle a quiet fill, main an ink fill, error a red fill")
    func iconButtonVariants() throws {
        let ghost = try #require(iconButton(.ghost))
        let subtle = try #require(iconButton(.subtle))
        let main = try #require(iconButton(.main))
        let error = try #require(iconButton(.error))
        // Unfilled variants draw only the glyph: no ink in the ring between radius 12 and 20.
        func ringAlpha(_ p: PixelProbe.Pixels) -> Double {
            var total = 0.0, n = 0.0
            let cx = Double(p.width) / 2, cy = Double(p.height) / 2
            for y in 0..<p.height { for x in 0..<p.width {
                let r = hypot(Double(x) - cx, Double(y) - cy) / 2   // points
                guard r > 13, r < 19 else { continue }
                total += p.rgba(x: x, y: y).a; n += 1
            } }
            return total / n
        }
        for v in [TouchpointIconButtonStyle.Variant.ghost, .selected, .unselected] {
            #expect(ringAlpha(try #require(iconButton(v))) < 0.01, "\(v) has a fill")
        }
        #expect(ringAlpha(subtle) > 0.08 && ringAlpha(subtle) < 0.15)   // tier 10
        #expect(ringAlpha(main) > 0.85)                                  // tier 90
        #expect(ringAlpha(error) > 0.95)                                 // opaque semantic colour
        #expect(main.meanLuminance(minAlpha: 0.5, overWhite: true) < 0.3)
        #expect(error.redDominance() > 0.25)
        _ = ghost
    }

    @Test("The accent variant (web IconButton main): accent fill with readable ink; accent-20 when disabled")
    func accentVariant() throws {
        func ring(_ p: PixelProbe.Pixels) -> (r: Double, g: Double, b: Double, a: Double) {
            var r = 0.0, g = 0.0, b = 0.0, a = 0.0, n = 0.0
            let cx = Double(p.width) / 2, cy = Double(p.height) / 2
            for y in 0..<p.height { for x in 0..<p.width {
                let d = hypot(Double(x) - cx, Double(y) - cy) / 2
                guard d > 13, d < 19 else { continue }
                let px = p.rgba(x: x, y: y); r += px.r; g += px.g; b += px.b; a += px.a; n += 1
            } }
            return (r / n, g / n, b / n, a / n)
        }
        func render(_ theme: TouchpointTheme, disabled: Bool = false) throws -> PixelProbe.Pixels {
            let button = Button {} label: { TouchpointIconView(.send) }
                .buttonStyle(TouchpointIconButtonStyle(.accent))
                .disabled(disabled)
                .environment(\.touchpointTheme, theme)
            return try #require(PixelProbe.render(button, width: 60, height: 60))
        }
        // The default accent is the default ink, so the control looks like `main`, as web's does.
        #expect(ring(try render(.default)).a > 0.85)
        // A brand accent fills it: teal, opaque, with white ink (black would read worse on it).
        let brand = TouchpointTheme(accent: Color(red: 0, green: 0.42, blue: 0.45))
        let on = ring(try render(brand))
        #expect(on.a > 0.95 && on.g > on.r + 0.2, "brand fill \(on)")
        // Disabled: the accent at 20%.
        let off = ring(try render(brand, disabled: true))
        #expect(abs(off.a - 0.2) < 0.05, "disabled fill alpha \(off.a)")
    }

    @Test("Glyph tiers: selected is the strongest ink, ghost and unselected share the AA floor, disabled is faintest")
    func glyphTiers() throws {
        // Darker ink over white = lower luminance. Measured on the glyph pixels only.
        func glyphLum(_ v: TouchpointIconButtonStyle.Variant, disabled: Bool = false) throws -> Double {
            try #require(iconButton(v, disabled: disabled)).meanLuminance(minAlpha: 0.02, overWhite: true)
        }
        let selected = try glyphLum(.selected), ghost = try glyphLum(.ghost), unselected = try glyphLum(.unselected)
        #expect(selected < ghost, "selected \(selected) should be stronger than ghost \(ghost)")
        // `unselected` sits at the same tier 60 as `ghost`: the sibling of a chosen action is still
        // tappable, and tier 40 lands near 2.5:1 on the light surface (WCAG 1.4.11). The filled
        // versus outlined glyph carries the state instead of the ink.
        #expect(abs(unselected - ghost) < 0.01, "unselected \(unselected) should match ghost \(ghost)")
        for v in [TouchpointIconButtonStyle.Variant.ghost, .selected, .unselected] {
            #expect(try glyphLum(v, disabled: true) > glyphLum(v) + 0.05, "\(v) disabled did not lighten")
        }
        // Filled variants: disabled drops the fill (tier 10 / 5 / secondary-20), so the whole
        // control is lighter.
        for v in [TouchpointIconButtonStyle.Variant.main, .subtle, .error] {
            let on = try #require(iconButton(v)).meanLuminance(minAlpha: 0.02, overWhite: true)
            let off = try #require(iconButton(v, disabled: true)).meanLuminance(minAlpha: 0.02, overWhite: true)
            #expect(off > on + 0.05, "\(v) disabled did not lighten: \(on) → \(off)")
        }
    }

    @Test("Chips are pills: wider than tall, drawn small over a 44pt tap floor, and the chosen (disabled) one is lighter")
    func chipStyle() throws {
        let chip = Button {} label: { Text(verbatim: "Reset my password") }.buttonStyle(TouchpointChipStyle())
        let p = try #require(PixelProbe.render(chip, width: 300, height: 80))
        let bounds = try #require(p.inkBounds(scale: 2, minAlpha: 0.02))
        #expect(bounds.width > bounds.height * 2)
        // design-05…12: the pill is a quiet shortcut, drawn at the footnote's natural height — well
        // under the tap floor — while the control's frame (not its ink) still spans 44pt.
        #expect(bounds.height < 40, "the drawn pill should be smaller than the tap target: \(bounds.height)")
        #expect(bounds.height >= 26, "but still a pill, not a line: \(bounds.height)")
        let framed = try #require(PixelProbe.render(chip.background(Color.red.opacity(0.5)), width: 300, height: 80))
        let frame = try #require(framed.inkBounds(scale: 2, minAlpha: 0.02))
        #expect(frame.height >= 44 - 0.5, "a chip is a tap target: \(frame.height)")
        let chosen = try #require(PixelProbe.render(chip.disabled(true), width: 300, height: 80))
        #expect(chosen.meanLuminance(minAlpha: 0.02, overWhite: true) > p.meanLuminance(minAlpha: 0.02, overWhite: true) + 0.03)
    }

    // MARK: Motion (T11)

    @Test("Shimmer phase wraps every 1.5s")
    func shimmerPhase() {
        #expect(Shimmer.period == 1.5)
        #expect(Shimmer.phase(at: 0) == 0)
        #expect(abs(Shimmer.phase(at: 0.75) - 0.5) < 0.001)
        #expect(abs(Shimmer.phase(at: 1.5)) < 0.001)
    }

    @Test("A shimmer frame with no phase (Reduce Motion) is static tier-60 text; a phased frame adds the brighter band")
    func shimmerFrames() throws {
        let text = { Text(verbatim: "Connecting…").font(.body) }
        let still1 = try #require(PixelProbe.render(ShimmerFrame(phase: nil, content: text), width: 200, height: 40))
        let still2 = try #require(PixelProbe.render(ShimmerFrame(phase: nil, content: text), width: 200, height: 40))
        #expect(still1.bytes == still2.bytes)
        // The band is brighter ink (tier 90): with it present, mean ink luminance over white drops.
        let moving = try #require(PixelProbe.render(ShimmerFrame(phase: 0.5, content: text), width: 200, height: 40))
        let stillLum = still1.meanLuminance(minAlpha: 0.05, overWhite: true)
        let movingLum = moving.meanLuminance(minAlpha: 0.05, overWhite: true)
        #expect(movingLum < stillLum - 0.01, "still \(stillLum) moving \(movingLum)")
        // The modifier owns the colour: an inner style would hide the sweep, so the frame must be
        // the one that draws at tier 60.
        var env = EnvironmentValues(); env.colorScheme = .light
        let expected = TouchpointTheme.default.primary(.t60).resolve(in: env)
        let densest = (0..<still1.height).flatMap { y in (0..<still1.width).map { x in still1.rgba(x: x, y: y).a } }.max() ?? 0
        #expect(abs(densest - Double(expected.opacity)) < 0.05, "ink alpha \(densest) vs tier 60 \(expected.opacity)")
    }

    @Test("Ripple: four rings staggered by 0.18s over a 1.5s cycle, easing out; at rest after 75%")
    func rippleTiming() {
        #expect(RippleView.ringCount == 4)
        #expect(RippleView.period == 1.5)
        #expect(RippleView.delays == [0, 0.18, 0.36, 0.54])
        let start = RippleView.ring(progress: 0)
        #expect(start.scale == 1 && start.opacity == 1)
        // Ease-out: past halfway in scale before halfway in time.
        let mid = RippleView.ring(progress: 0.375)
        #expect(mid.scale > 1.5 && mid.opacity < 0.5 && abs(mid.scale - 1 + mid.opacity - 1) < 0.001)
        let rest = RippleView.ring(progress: 0.9)
        #expect(rest.scale == 2 && rest.opacity == 0)
    }

    @Test("A ripple frame with no time (Reduce Motion) is one static ring; the hole mask is open over the control only")
    func rippleFrames() throws {
        let m = TranscriptMetrics(scale: 1)
        let a = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: nil), width: 80, height: 80))
        let b = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: nil), width: 80, height: 80))
        #expect(a.bytes == b.bytes)
        // Static: ink only in the thin ring just outside radius 20.
        #expect(a.rgba(x: a.width / 2, y: a.height / 2).a < 0.01)
        #expect(a.rgba(x: a.width / 2, y: Int(Double(a.height) / 2 - 21 * 2)).a > 0.3)
        #expect(a.rgba(x: a.width / 2, y: Int(Double(a.height) / 2 - 30 * 2)).a < 0.01)
        // Moving: the rings add ink outside the control but still none inside it.
        let moving = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: 0.3), width: 80, height: 80))
        #expect(moving.rgba(x: moving.width / 2, y: moving.height / 2).a < 0.01, "ring painted over the control")
        #expect(moving.rgba(x: moving.width / 2, y: Int(Double(moving.height) / 2 - 30 * 2)).a > 0.01, "no ring outside the control")
        // The mask itself: transparent centre, opaque corner.
        let mask = try #require(PixelProbe.render(RippleHoleMask(diameter: 40), width: 80, height: 80))
        #expect(mask.rgba(x: mask.width / 2, y: mask.height / 2).a < 0.01)
        #expect(mask.rgba(x: 2, y: 2).a > 0.99)
    }

    @Test("Reduce Motion leaves the ripple a static ring: rendered at two different times, nothing moves")
    func rippleHonoursReduceMotion() throws {
        let m = TranscriptMetrics(scale: 1)
        // The environment flag cannot be set in a unit test, so this asserts the branch the view
        // takes under it: `RippleView` with Reduce Motion renders `RippleFrame(now: nil)`, and that
        // frame is identical whenever it is drawn. The moving frame, by contrast, differs with time.
        let stillA = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: nil), width: 80, height: 80))
        let stillB = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: nil), width: 80, height: 80))
        #expect(stillA.bytes == stillB.bytes)
        let movingA = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: 0.0), width: 80, height: 80))
        let movingB = try #require(PixelProbe.render(RippleFrame(diameter: 40, metrics: m, now: 0.5), width: 80, height: 80))
        #expect(movingA.bytes != movingB.bytes, "the animated ripple did not change between two times")
        // And the static frame is not merely the animated one at t=0: no rings, only the ring.
        #expect(stillA.bytes != movingA.bytes)
    }

    @Test("Ink on a filled accent is whichever of black or white reads against it, not the scheme's inverse")
    func inkOnAccent() {
        // A host brand rarely follows the colour scheme, so the scheme's inverse is unsafe: a
        // dark teal would take near-black ink in dark mode (~3.2:1), and a yellow brand would
        // take white (~1.3:1).
        func resolved(_ r: Double, _ g: Double, _ b: Double) -> Color.Resolved {
            var env = EnvironmentValues(); env.colorScheme = .light
            return Color(red: r, green: g, blue: b).resolve(in: env)
        }
        // Dark teal (a typical bank brand) → white ink, in either scheme.
        #expect(TouchpointTheme.readableInk(on: resolved(0, 0.42, 0.45)) == .white)
        // Light yellow → black ink.
        #expect(TouchpointTheme.readableInk(on: resolved(1, 0.9, 0.2)) == .black)
        #expect(TouchpointTheme.readableInk(on: resolved(0, 0, 0)) == .white)
        #expect(TouchpointTheme.readableInk(on: resolved(1, 1, 1)) == .black)

        // And the chosen ink clears AA on each: the point of choosing it at all.
        for (r, g, b) in [(0.0, 0.42, 0.45), (1.0, 0.9, 0.2), (0.5, 0.0, 0.5), (0.2, 0.7, 0.3)] {
            let fill = resolved(r, g, b)
            let ink = TouchpointTheme.readableInk(on: fill)
            var env = EnvironmentValues(); env.colorScheme = .light
            let inkResolved = ink.resolve(in: env)
            let lFill = PixelProbe.relativeLuminance(r: Double(fill.red), g: Double(fill.green), b: Double(fill.blue))
            let lInk = PixelProbe.relativeLuminance(r: Double(inkResolved.red), g: Double(inkResolved.green), b: Double(inkResolved.blue))
            #expect(PixelProbe.contrast(lInk, lFill) >= 4.5, "ink on (\(r), \(g), \(b)) is \(PixelProbe.contrast(lInk, lFill)):1")
        }
    }

    @Test("Ripple colour showcases a host accent and falls back to the focus blue at the tier alpha, applied once")
    func rippleColour() {
        var env = EnvironmentValues(); env.colorScheme = .dark
        let fallback = TouchpointTheme.default.rippleColor(.t20).resolve(in: env)
        #expect(abs(Double(fallback.opacity) - 0.2) < 0.01, "fallback alpha \(fallback.opacity) — not multiplied by the focus colour's own alpha")
        #expect(Double(fallback.blue) > 0.9 && Double(fallback.red) < 0.1)   // rgb(0,149,255)
        var branded = TouchpointTheme.default
        branded.accent = Color(red: 0.5, green: 0, blue: 0.5)
        let ring = branded.rippleColor(.t50).resolve(in: env)
        #expect(abs(Double(ring.opacity) - 0.5) < 0.01 && abs(Double(ring.red) - 0.5) < 0.01 && Double(ring.green) < 0.01)
    }

    // MARK: Launch button (S1)

    @Test("The launch button is a 56pt disc at the default text size, and grows a pill when given a label")
    func launchButtonGeometry() throws {
        let bare = try #require(PixelProbe.render(TouchpointLaunchButton {}, width: 200, height: 120))
        let discBounds = try #require(bare.inkBounds(scale: 2, minAlpha: 0.5))   // above the shadow's alpha: the disc itself
        #expect(abs(discBounds.width - 56) <= 2 && abs(discBounds.height - 56) <= 2, "disc \(discBounds)")
        let labelled = try #require(PixelProbe.render(TouchpointLaunchButton(label: "Support") {}, width: 300, height: 120))
        let pillBounds = try #require(labelled.inkBounds(scale: 2, minAlpha: 0.5))
        #expect(pillBounds.width > discBounds.width + 20, "a label should widen the pill: \(pillBounds)")
        #expect(abs(pillBounds.height - discBounds.height) <= 4, "the pill keeps the disc's height")
    }

    @Test("The launch button's glyph is flat ink even under a brand accent, as web draws it; tapping runs the host's action")
    func launchButtonInkAndAction() throws {
        var tapped = 0
        let button = TouchpointLaunchButton { tapped += 1 }
        #expect(PixelProbe.render(button, width: 200, height: 120) != nil)
        // The action is the host's: invoked directly, since a render cannot tap.
        button.action()
        #expect(tapped == 1)
        // Web's launch glyph is `text-primary-80` and does not take the accent
        // (`ui/LaunchButton.tsx:23`) — the accent reaches it only on the `.prominent` deviation,
        // where it is the *fill* and the glyph becomes contrast-chosen ink. So a brand accent must
        // leave the default button's mark as plain ink. Measured on the glyph's own pixels.
        var branded = TouchpointTheme.default
        branded.accent = Color(red: 0.9, green: 0.1, blue: 0.1)
        let tinted = try #require(PixelProbe.render(TouchpointLaunchButton {}.touchpointTheme(branded), width: 200, height: 120))
        let plain = try #require(PixelProbe.render(TouchpointLaunchButton {}, width: 200, height: 120))
        func stronglyRedFraction(_ p: PixelProbe.Pixels) -> Double {
            var n = 0.0
            for y in 0..<p.height {
                for x in 0..<p.width {
                    let c = p.rgba(x: x, y: y)
                    guard c.a > 0.3 else { continue }
                    if c.r - (c.g + c.b) / 2 > 0.3 { n += 1 }
                }
            }
            return n / Double(p.width * p.height)
        }
        #expect(stronglyRedFraction(tinted) < 0.0001, "web's launch glyph ignores the accent")
        #expect(stronglyRedFraction(plain) < 0.0001, "and is ink by default")
        // The accent does reach the `.prominent` deviation, as its fill.
        let prominent = try #require(PixelProbe.render(
            TouchpointLaunchButton(style: .prominent) {}.touchpointTheme(branded), width: 200, height: 120))
        #expect(stronglyRedFraction(prominent) > 0.001, "the prominent style fills with the accent")
    }
}
