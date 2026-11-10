import CoreGraphics
import SwiftUI
import Testing
@testable import TouchpointVoice

/// Web's `useDraggable`: the widget keeps its anchor and moves by a translate offset, clamped so it
/// stays wholly inside the viewport less an 8pt margin.
@Suite("Draggable voice widget (web useDraggable)")
struct DraggableTests {
    let container = CGSize(width: 400, height: 800)
    let content = CGSize(width: 60, height: 300)

    @Test("Anchored bottom-leading, the widget can travel to every edge but never past the margin")
    func clampBottomLeading() {
        // Base: 8pt in from the leading edge, 8pt up from the bottom.
        let far = Draggable.clamp(CGSize(width: 10_000, height: -10_000), content: content, container: container, anchor: .bottomLeading)
        #expect(far.width == CGFloat(400 - 8 - 60 - 8))        // right edge less margin
        #expect(far.height == CGFloat(-(800 - 8 - 300 - 8)))   // top edge less margin
        let back = Draggable.clamp(CGSize(width: -50, height: 50), content: content, container: container, anchor: .bottomLeading)
        #expect(back == .zero, "it cannot go past the anchor's own margins")
        let inside = Draggable.clamp(CGSize(width: 100, height: -200), content: content, container: container, anchor: .bottomLeading)
        #expect(inside == CGSize(width: 100, height: -200))
    }

    @Test("Anchored bottom-trailing (web's own corner), the range mirrors")
    func clampBottomTrailing() {
        let far = Draggable.clamp(CGSize(width: -10_000, height: 0), content: content, container: container, anchor: .bottomTrailing)
        #expect(far.width == CGFloat(-(400 - 8 - 60 - 8)))
        #expect(Draggable.clamp(CGSize(width: 20, height: 0), content: content, container: container, anchor: .bottomTrailing).width == 0)
    }

    @Test("Content larger than the room pins to the anchor rather than inverting the range")
    func oversized() {
        let huge = CGSize(width: 500, height: 900)
        #expect(Draggable.clamp(CGSize(width: 40, height: -40), content: huge, container: container, anchor: .bottomLeading) == .zero)
    }

    @Test("A smaller container (rotation, Dynamic Type) pulls an offset back inside")
    func reclampOnResize() {
        let moved = CGSize(width: 324, height: -484)
        let smaller = CGSize(width: 300, height: 600)
        let clamped = Draggable.clamp(moved, content: content, container: smaller, anchor: .bottomLeading)
        #expect(clamped == CGSize(width: 300 - 16 - 60, height: -(600 - 16 - 300)))
    }

    @Test("Before anything is measured, nothing moves")
    func unmeasured() {
        #expect(Draggable.clamp(CGSize(width: 30, height: 30), content: .zero, container: .zero, anchor: .bottomLeading) == .zero)
    }

    @Test("A container that shrinks for a while and grows back draws the rail where it was asked to be")
    func shrinkAndRegrow() {
        // The modifier keeps the asked offset and clamps only to draw — the phone's half chat
        // insets the screen while it is open, which must not cost the rail its place.
        let asked = CGSize(width: 100, height: -400)
        let halved = CGSize(width: 400, height: 400)
        #expect(Draggable.clamp(asked, content: content, container: halved, anchor: .bottomLeading).height == CGFloat(-(400 - 16 - 300)))
        #expect(Draggable.clamp(asked, content: content, container: container, anchor: .bottomLeading) == asked)
    }
}
