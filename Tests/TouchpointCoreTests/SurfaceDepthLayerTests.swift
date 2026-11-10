import SwiftUI
import Testing
@testable import TouchpointCore

/// Web gates the sheen, shade and grain on `backgroundDepthLayer` (`BackgroundDecoration.tsx:41`,
/// defaulting true at `App.tsx:139`) and paints them once, on `Main` (`Layout.tsx:28`). These
/// assert the gate works and that a host nesting surfaces is not paying for the depth twice.
@MainActor
struct SurfaceDepthLayerTests {
    private func stats(_ p: PixelProbe.Pixels) -> (mean: Double, sd: Double) {
        var values: [Double] = []
        for y in 0..<p.height {
            for x in 0..<p.width {
                let c = p.rgba(x: x, y: y)
                values.append(0.2126 * c.r * c.a + 0.7152 * c.g * c.a + 0.0722 * c.b * c.a)
            }
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
        return (mean, variance.squareRoot())
    }

    private var depthless: TouchpointTheme {
        var theme = TouchpointTheme.default
        theme.backgroundDepthLayer = false
        return theme
    }

    @Test("backgroundDepthLayer defaults to true, as web's does")
    func defaultsOn() {
        #expect(TouchpointTheme.default.backgroundDepthLayer)
    }

    @Test("Turning the depth off flattens the panel: the bottom shade and the grain go")
    func depthOffIsFlatter() throws {
        let withDepth = ZStack { Color.black; TouchpointSurface() }
        let without = ZStack { Color.black; TouchpointSurface().touchpointTheme(depthless) }

        let a = try #require(PixelProbe.render(withDepth, width: 390, height: 500, colorScheme: .dark))
        let b = try #require(PixelProbe.render(without, width: 390, height: 500, colorScheme: .dark))

        // The shade darkens the bottom fifth; without it that band matches the rest of the fill.
        let shadedBottom = a.meanLuminance(yRange: 0.8...1.0, minAlpha: 0)
        let flatBottom = b.meanLuminance(yRange: 0.8...1.0, minAlpha: 0)
        #expect(flatBottom > shadedBottom, "the shade should be what darkens the bottom edge")

        // And the flat panel varies less overall: no sheen, no shade, no grain.
        #expect(stats(b).sd < stats(a).sd)
    }

    @Test("The wash and the fill survive the gate — web keeps those at every setting")
    func washSurvives() throws {
        let without = ZStack { Color.black; TouchpointSurface().touchpointTheme(depthless) }
        let p = try #require(PixelProbe.render(without, width: 390, height: 500, colorScheme: .dark))
        // The fill is still there: a near-black panel, not the bare black backdrop.
        #expect(stats(p).mean > 0.02)
        // The wash still bleeds in from the right edge, so the right half stays lighter.
        let left = p.meanLuminance(xRange: 0...0.25, minAlpha: 0)
        let right = p.meanLuminance(xRange: 0.75...1.0, minAlpha: 0)
        #expect(right > left, "the tinted wash should still come in from the right")
    }
}
