import SwiftUI
import Testing
@testable import TouchpointCore

/// Web's `LoaderAnimation` (`ui/Loader.tsx`).
@Suite("Loader")
struct TouchpointLoaderTests {
    @Test("Web's timing: 990 ms of movement, then a 300 ms pause with the dots merged and glowing")
    func timing() {
        #expect(TouchpointLoader.totalDuration == 1290)
        let rest = TouchpointLoader.frame(atMilliseconds: 1000)
        #expect(rest.distance == 0 && rest.spin == 0 && rest.glow == 5 && rest.opacity == 1)
        // Mid-move the dots are apart (the hold at full distance, t in 1/3…2/3), dimmed and unglowing.
        let apart = TouchpointLoader.frame(atMilliseconds: 495)
        #expect(apart.distance == 1 && apart.glow == 0 && abs(apart.opacity - 0.75) < 0.001)
        // The first cycle turns from a quarter to a half; the next from nothing to a quarter.
        #expect(TouchpointLoader.frame(atMilliseconds: 10).spin >= 1)
        #expect(TouchpointLoader.frame(atMilliseconds: 1290 + 10).spin < 1)
    }

    @Test("The goo bridge is drawn only while the dots are close")
    func goo() {
        let close = TouchpointLoader.pair(halfDistance: 5).boundingRect
        let apart = TouchpointLoader.pair(halfDistance: 30).boundingRect
        #expect(abs(close.width - (10 + 34)) < 0.5)
        #expect(abs(apart.width - (60 + 34)) < 0.5)
        // At 30 (limitRatio ≈ 0.63) no bridge: the middle is empty.
        #expect(!TouchpointLoader.pair(halfDistance: 30).contains(.zero))
        #expect(TouchpointLoader.pair(halfDistance: 5).contains(.zero))
        // In the goo-only band (outside both circles, between them): filled, not cancelled.
        // At d = 12 the bridge's top edge at x = 0 is y ≈ 13.9 (web's bezier); 13.5 is inside it.
        let d: CGFloat = 12
        let band = CGPoint(x: 0, y: 13.5)
        #expect(hypot(band.x - d, band.y) > TouchpointLoader.rc, "the probe point must lie outside the circles")
        #expect(TouchpointLoader.pair(halfDistance: d).contains(band), "the goo bridge is missing")
    }

    @Test("Under Reduce Motion it draws the resting frame; it is a labelled, updating status")
    @MainActor
    func reduceMotionAndLabel() throws {
        var still = TouchpointLoader(size: 32, label: "Connecting…")
        still.reduceMotionOverride = true
        let renderer = ImageRenderer(content: still)
        renderer.scale = 2
        let cg = try #require(renderer.cgImage)
        #expect(cg.width == 64 && cg.height == 64)
        // The resting frame is one merged dot at the centre.
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        let ctx = CGContext(data: &bytes, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 64 * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(bytes[(32 * 64 + 32) * 4 + 3] > 200, "no dot at the centre")
        // The resting dot is 17/100 of 32 = 5.4pt in radius; the glow carries ink a few points past it.
        let glowPoint = Int((32 / 2 + 5.4 + 2.5) * 2)
        #expect(bytes[(32 * 64 + glowPoint) * 4 + 3] > 8, "no glow outside the dot")
        #expect(bytes[(32 * 64 + 1) * 4 + 3] < 40, "ink at the edge: not the resting frame")
    }
}
