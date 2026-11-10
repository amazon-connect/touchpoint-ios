import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

#if canImport(UIKit)

/// The suggested replies (design-05…12), as web's stacked full-width rows.
@Suite("Suggested replies")
@MainActor
struct SuggestedRepliesTests {
    private func render(_ view: some View, width: CGFloat) -> CGSize {
        let renderer = ImageRenderer(content: view.frame(width: width))
        renderer.scale = 2
        return renderer.uiImage?.size ?? .zero
    }

    @Test("Replies wrap rather than scroll: the same set is taller in a narrow container")
    func wraps() {
        let replies = ["I forgot my password", "I forgot my username", "What's Access Card?"]
        let wide = render(TouchpointSuggestedReplies(replies) { _ in }, width: 700)
        let narrow = render(TouchpointSuggestedReplies(replies) { _ in }, width: 200)
        #expect(wide.height > 0)
        #expect(narrow.height > wide.height, "narrow \(narrow.height) should exceed wide \(wide.height) — it did not wrap")
    }

    @Test("Right-to-left fills each row from the trailing edge: a custom Layout is not mirrored for free")
    func rtlMirrors() {
        // One narrow pill, so its horizontal position is unambiguous.
        func centroid(_ direction: LayoutDirection) -> Double {
            let view = TouchpointSuggestedReplies(["ok"]) { _ in }
                .frame(width: 390)
                .environment(\.layoutDirection, direction)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let cg = renderer.uiImage?.cgImage else { return 0.5 }
            let width = cg.width, height = cg.height
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0.5 }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            var weighted = 0.0, mass = 0.0
            for y in 0..<height {
                for x in 0..<width where Double(bytes[(y * width + x) * 4 + 3]) / 255 > 0.05 {
                    weighted += Double(x); mass += 1
                }
            }
            return mass > 0 ? weighted / mass / Double(width) : 0.5
        }
        let ltr = centroid(.leftToRight), rtl = centroid(.rightToLeft)
        #expect(ltr < 0.4, "LTR pill should sit on the leading edge: \(ltr)")
        #expect(rtl > 0.6, "RTL pill should sit on the trailing edge: \(rtl)")
    }

    @Test("A chosen reply is still drawn — the reader keeps the context of what they picked")
    func chosenStaysVisible() {
        let replies = ["one", "two"]
        let open = render(TouchpointSuggestedReplies(replies) { _ in }, width: 390)
        let chosen = render(TouchpointSuggestedReplies(replies, chosen: "one") { _ in }, width: 390)
        #expect(chosen.height == open.height)
    }

    @Test("Every reply the host offers gets a pill, and the row grows with the count")
    func allRepliesDrawn() {
        let one = render(TouchpointSuggestedReplies(["only"]) { _ in }, width: 200)
        let many = render(TouchpointSuggestedReplies(["only", "second", "third", "fourth"]) { _ in }, width: 200)
        #expect(many.height > one.height)
    }
}

#endif
