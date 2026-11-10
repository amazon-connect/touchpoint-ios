import SwiftUI
import Testing
import TouchpointCore
@testable import TouchpointChat

/// Design QA: markdown takes its natural width, so a bubble hugs its words (c56) and a centred
/// welcome greeting centres every line (c22), at web's 18pt greeting size.
@Suite("Markdown layout")
@MainActor
struct MarkdownLayoutTests {
    private let metrics = TranscriptMetrics(scale: 1, theme: .default)

    /// Renders on a transparent canvas at 2× and returns the ink's horizontal centroid (0…1) and the
    /// ink's bounding width and the image height, in points.
    private func probe(_ view: some View, width: CGFloat, rows: ClosedRange<Double> = 0...1)
        -> (centroid: Double, inkWidth: CGFloat, height: CGFloat, mass: Double) {
        let renderer = ImageRenderer(content: view.frame(width: width, alignment: .leading))
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return (0, 0, 0, 0) }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (0, 0, 0, 0) }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var weighted = 0.0, mass = 0.0, minX = w, maxX = -1
        let band = Int(rows.lowerBound * Double(h))..<max(Int(rows.lowerBound * Double(h)) + 1, Int(rows.upperBound * Double(h)))
        for y in band {
            for x in 0..<w where Double(bytes[(y * w + x) * 4 + 3]) / 255 > 0.05 {
                weighted += Double(x); mass += 1
                minX = min(minX, x); maxX = max(maxX, x)
            }
        }
        let inkWidth = maxX >= minX ? CGFloat(maxX - minX + 1) / 2 : 0
        return (mass > 0 ? weighted / mass / Double(w) : 0, inkWidth, CGFloat(h) / 2, mass)
    }

    @Test("A centred one-line message sits in the middle of the column, not on its leading edge")
    func centredLine() {
        let view = ChatMarkdownText("What would you like to try?", metrics: metrics, alignment: .center)
            .frame(maxWidth: .infinity)
        let centroid = probe(view, width: 360).centroid
        #expect(abs(centroid - 0.5) < 0.01, "centroid \(centroid)")
    }

    @Test("Every line of a wrapped centred message is centred, the short last one included")
    func centredWrappedLines() {
        // Wraps in 200pt; the last line is one short word, so a leading-aligned last line would sit
        // well left of centre. Bitmap rows run top-down, so the bottom band is the last line.
        let text = "Everything everything everything everything everything everything ok"
        let view = ChatMarkdownText(text, metrics: metrics, alignment: .center).frame(maxWidth: .infinity)
        let last = probe(view, width: 200, rows: 0.7...1).centroid
        #expect(abs(last - 0.5) < 0.03, "last line centroid \(last)")
        // The text must really wrap to a short last line, or the check above proves nothing: the
        // same text leading-aligned puts that line well left of centre.
        let leading = ChatMarkdownText(text, metrics: metrics).frame(maxWidth: .infinity, alignment: .leading)
        let leadingLast = probe(leading, width: 200, rows: 0.7...1).centroid
        #expect(leadingLast < 0.45, "leading last line centroid \(leadingLast)")
    }

    @Test("A short message is only as wide as its words, so a bubble around it hugs them")
    func hugsShortText() {
        let view = ChatMarkdownText("Okay cool", metrics: metrics).background(Color.black)
        let ink = probe(view, width: 360).inkWidth
        #expect(ink > 0)
        #expect(ink < 180, "a two-word message filled \(ink) of 360pt")
    }

    @Test("A long message still wraps at the column rather than growing past it")
    func longTextWraps() {
        let long = String(repeating: "word ", count: 60)
        // The column is 300pt inside a 500pt canvas, so text that ignored the column would ink past
        // 300 rather than be cut off at the image's edge.
        let view = ChatMarkdownText(long, metrics: metrics).frame(width: 300, alignment: .leading)
        let result = probe(view, width: 500)
        #expect(result.inkWidth > 200)
        #expect(result.inkWidth <= 300)
        #expect(result.height > 60)
    }

    @Test("The greeting font reaches the text: an 18pt greeting is taller than the 16pt body")
    func greetingFont() {
        let body = probe(ChatMarkdownText("Hi", metrics: metrics), width: 360).height
        let greeting = probe(ChatMarkdownText("Hi", metrics: metrics, font: metrics.greetingFont), width: 360).height
        // 18 against 16: the line is at least 10% taller.
        #expect(greeting >= body * 1.1, "greeting \(greeting) vs body \(body)")
    }

    @Test("A heading is bold: the font reaches the Text, so it inks more than the same words plain")
    func headingIsBold() {
        let plain = probe(ChatMarkdownText("Account summary", metrics: metrics), width: 360).mass
        let heading = probe(ChatMarkdownText("# Account summary", metrics: metrics), width: 360).mass
        #expect(heading > plain * 1.1, "heading \(heading) vs plain \(plain)")
    }
}


/// Design QA c16 and c33: no welcome screen in the phone's bottom-half dock; carousel cards at
/// web's 320, never wider than the scroll view.
@Suite("Welcome in the dock, carousel width")
@MainActor
struct DockAndCarouselTests {
    @Test("The phone's half dock has no welcome screen; full, mini and the tablet's half keep it")
    func welcomeGate() {
        #expect(!ChatWindowModifier<EmptyView>.isBottomDock(mode: .full, windowWidth: 393))
        #expect(!ChatWindowModifier<EmptyView>.isBottomDock(mode: .mini, windowWidth: 393))
        #expect(ChatWindowModifier<EmptyView>.isBottomDock(mode: .half, windowWidth: 393))
        #expect(!ChatWindowModifier<EmptyView>.isBottomDock(mode: .half, windowWidth: 1024))
        #expect(TranscriptLayout.showsWelcomeScreen(enabled: true, isBottomDock: false))
        #expect(!TranscriptLayout.showsWelcomeScreen(enabled: true, isBottomDock: true))
        #expect(!TranscriptLayout.showsWelcomeScreen(enabled: false, isBottomDock: false))
    }

    @Test("Carousel cards are 320 wide, capped to the container at large text sizes")
    func carouselCardWidth() {
        let regular = TranscriptMetrics(scale: 1, theme: .default)
        #expect(ModalityCarouselView.cardWidth(in: 362, metrics: regular) == 320)
        #expect(ModalityCarouselView.cardWidth(in: 200, metrics: regular) == 200)
        let large = TranscriptMetrics(scale: 2.8, theme: .default)
        #expect(ModalityCarouselView.cardWidth(in: 362, metrics: large) == 362)
    }
}
