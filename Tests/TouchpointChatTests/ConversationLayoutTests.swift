import CoreGraphics
import SwiftUI
import Testing
@testable import TouchpointChat

@Suite("Conversation layout (c53)")
struct ConversationLayoutTests {
    private func arrange(height: CGFloat, content: CGFloat, accessory: CGFloat?, composer: CGFloat?, welcome: Bool = true)
        -> ConversationLayout.Arrangement {
        ConversationLayout.arrange(height: height, content: content, accessory: accessory, composer: composer,
                                   isWelcome: welcome, accessorySpacing: 8, welcomeGap: 8)
    }

    @Test("Welcome that fits: greeting, composer, choices, centred as one group")
    func inline() {
        let a = arrange(height: 800, content: 200, accessory: 100, composer: 60)
        #expect(a.isInline)
        // 200 + 8 + 60 + 100 = 368, centred in 800.
        #expect(a.content == 216...416)
        #expect(a.composer == 424...484)
        // Edge to edge on purpose: the composer's own outer padding is web's 8pt gap (c44).
        #expect(a.accessory == 484...584)
    }

    @Test("Welcome that doesn't fit pins the composer to the bottom, choices above it, greeting in what's left")
    func pinned() {
        let a = arrange(height: 400, content: 300, accessory: 100, composer: 60)
        #expect(!a.isInline)
        #expect(a.composer == 340...400)
        #expect(a.accessory == 240...340)
        // 232 left above the choices and their gap; the 300-tall greeting takes all of it and scrolls.
        #expect(a.content == 0...232)
    }

    @Test("A composer taller than the room left squeezes the choices, never itself")
    func composerWins() {
        let a = arrange(height: 400, content: 300, accessory: 300, composer: 350)
        #expect(a.composer == 50...400)
        #expect(a.accessory == 8...50)
        #expect(a.content.upperBound - a.content.lowerBound == 0)
        let b = arrange(height: 400, content: 300, accessory: 300, composer: 500)
        #expect(b.composer == 0...400)
        #expect(b.accessory.map { $0.upperBound - $0.lowerBound } == 0)
    }

    @Test("The transcript always gives its content the rest, with the composer at the bottom")
    func transcript() {
        let a = arrange(height: 800, content: 10, accessory: 100, composer: 60, welcome: false)
        #expect(!a.isInline)
        #expect(a.composer == 740...800)
        #expect(a.accessory == 640...740)
        #expect(a.content == 0...632)
        let none = arrange(height: 800, content: 10, accessory: nil, composer: nil, welcome: false)
        #expect(none.content == 0...800)
    }

    @Test("A welcome without choices is not lifted: the composer stays at the bottom, as before")
    func welcomeWithoutChoices() {
        let a = arrange(height: 800, content: 200, accessory: nil, composer: 60)
        #expect(!a.isInline)
        #expect(a.composer == 740...800)
        #expect(a.content == 270...470)
    }

    /// The choice between inline and pinned rests on a bare ScrollView reporting its content's
    /// height when offered no height. Pinned here, so wrapping the welcome content in something
    /// that reports otherwise (a GeometryReader) fails a test rather than forcing pinned mode.
    @Test("A bare ScrollView reports its content's height when offered none")
    @MainActor
    func scrollViewNaturalHeight() {
        let box = MeasuredHeight()
        let probe = Probe(box: box) { ScrollView { Color.clear.frame(height: 123) } }
        let renderer = ImageRenderer(content: probe.frame(width: 300, height: 600))
        _ = renderer.cgImage
        #expect(box.value == 123)
    }
}

private final class MeasuredHeight: @unchecked Sendable { var value: CGFloat? }

private struct Probe<Content: View>: View {
    let box: MeasuredHeight
    @ViewBuilder let content: Content
    var body: some View { Measure(box: box) { content } }

    struct Measure: Layout {
        let box: MeasuredHeight
        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            proposal.replacingUnspecifiedDimensions()
        }
        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            box.value = subviews.first?.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
            subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}
