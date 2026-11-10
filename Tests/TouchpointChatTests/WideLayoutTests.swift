import SwiftUI
import Testing
import TouchpointCore

@testable import TouchpointChat

/// B6 tablets / wide layouts (TB-1…TB-3). The width thresholds are pure and tested here; the layout
/// they drive is checked on the simulator by the integrator. Breakpoints are web's, matched by the
/// Android SDK (`TouchpointMetrics.kt`): 768, 1280, the 640 content cap, the 632 half-panel.
@Suite("Tablet and wide layouts (B6)")
struct WideLayoutTests {
    @Test("The breakpoints are web's / Android's: 768, 1280, 640 content, 632 half-panel")
    func constants() {
        #expect(WideLayout.wideBreakpoint == 768)
        #expect(WideLayout.largeWindow == 1280)
        #expect(WideLayout.contentCap == 640)
        #expect(WideLayout.halfPanelCap == 632)
        #expect(WideLayout.narrowInset == 8 && WideLayout.wideInset == 12)
    }

    // MARK: TB-1 content cap + inset

    @Test("TB-1: a phone fills the surface; from 768 the content caps at 640")
    func contentWidth() {
        #expect(WideLayout.contentWidth(390) == nil)     // iPhone portrait
        #expect(WideLayout.contentWidth(767) == nil)     // just below the breakpoint
        #expect(WideLayout.contentWidth(768) == 640)     // at it
        #expect(WideLayout.contentWidth(1024) == 640)    // iPad portrait
        #expect(!WideLayout.isWide(767) && WideLayout.isWide(768))
    }

    @Test("TB-1: the block inset is 8 on a phone and 12 when wide, scaled with text")
    func blockInset() {
        #expect(WideLayout.blockInset(390, scale: 1) == 8)
        #expect(WideLayout.blockInset(768, scale: 1) == 12)
        #expect(WideLayout.blockInset(768, scale: 2) == 24) // grows with Dynamic Type
        #expect(WideLayout.blockInset(390, scale: 2) == 16)
    }

    // MARK: TB-2 floating header

    @Test("TB-2: the header floats over the content from a 768-wide surface")
    func headerFloats() {
        #expect(!WideLayout.headerFloats(500))
        #expect(!WideLayout.headerFloats(767))
        #expect(WideLayout.headerFloats(768))
        #expect(WideLayout.headerFloats(1200))
    }

    // MARK: TB-3 half-screen dock

    @Test("TB-3: a phone keeps the bottom-half dock; a tablet docks the right half, 632 from 1280")
    func halfPanelWidth() {
        #expect(WideLayout.halfPanelWidth(windowWidth: 390) == nil)        // phone → bottom-half dock
        #expect(WideLayout.halfPanelWidth(windowWidth: 767) == nil)
        #expect(WideLayout.halfPanelWidth(windowWidth: 768) == 384)        // half the window at md:
        #expect(WideLayout.halfPanelWidth(windowWidth: 1024) == 512)       // iPad portrait: half
        #expect(WideLayout.halfPanelWidth(windowWidth: 1280) == 632)       // caps at 632 from xl:
        #expect(WideLayout.halfPanelWidth(windowWidth: 1366) == 632)       // iPad landscape: held at 632
    }

    @Test("Window alignment: mini floats bottom-trailing, a tablet half docks trailing, else bottom")
    func windowAlignment() {
        #expect(ChatWindowModifier<EmptyView>.windowAlignment(mini: true, rightHalf: false) == .bottomTrailing)
        #expect(ChatWindowModifier<EmptyView>.windowAlignment(mini: false, rightHalf: true) == .trailing)
        #expect(ChatWindowModifier<EmptyView>.windowAlignment(mini: false, rightHalf: false) == .bottom)
    }
}
