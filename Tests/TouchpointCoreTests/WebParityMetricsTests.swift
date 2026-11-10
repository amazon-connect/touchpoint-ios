import SwiftUI
import Testing

@testable import TouchpointCore

/// The metric grid, asserted against the web SDK's own numbers.
///
/// These assertions **are** the audit table — a prose copy would only drift from them. Each case
/// carries web's value and the `file:line` it came from, so a future change can be checked against
/// the source rather than against someone's memory of it.
///
/// Everything is measured at `scale == 1`, which is what `DynamicTypeSize.large` — the iOS default
/// — resolves to. That matters: the SDK multiplies spacing by a Dynamic Type factor, and it would
/// be easy to assume that factor puts us off web's grid at the default size. It does not.
@Suite("Web parity: the metric grid")
struct WebParityMetricsTests {
    private var m: TranscriptMetrics { TranscriptMetrics(scale: 1, theme: .default) }

    @Test("The default content size is the unit of the grid, so web's fixed pixels are comparable")
    func defaultScaleIsOne() {
        #expect(TranscriptMetrics.scale(for: .large) == 1)
    }

    @Test("Spacing and padding match web at the default content size")
    func spacingGrid() {
        // Web's 768px `md:` step raises several of these to 12px, but no iPhone is that wide, so
        // the SDK takes the small-screen column everywhere.
        #expect(m.transcriptPadding == 8)        // Messages.tsx:522 — p-2
        #expect(m.controlPadding == 8)           // Layout.tsx:34-58 — p-2
        #expect(m.controlPaddingWide == 12)      // the md+ step, kept for hosts that want it
        #expect(m.controlGap == 4)               // Input.tsx:275 — gap-1, items-end
        #expect(m.responseSpacing == 32)         // Messages.tsx — space-y-8
        #expect(m.messageSpacing == 8)           // Messages.tsx — space-y-2, within one payload
        #expect(m.composerSpacing == 8)          // Layout.tsx:44-58 — gap to the choices above
    }

    @Test("Bubble and row geometry match web")
    func bubbleGeometry() {
        #expect(m.bubbleHorizontalPadding == 12) // Messages.tsx:229-284 — px-3
        #expect(m.bubbleVerticalPadding == 8)    // py-2
        #expect(m.userGutter == 48)              // pl-12 (8cebb4d)
        #expect(m.innerRadius == 20)             // Theme.tsx — --radius-inner
        #expect(m.outerRadius == 28)             // --radius-outer
    }

    @Test("Control geometry matches web, with the 44pt hit area as a named iOS deviation")
    func controlGeometry() {
        // Web draws a 40×40 disc with a 16px glyph (12px padding). We draw the same disc and the
        // same glyph; the only difference is that the *hit area* is inflated to the iOS 44pt floor,
        // which is a deviation from web's 40 and is deliberate (Apple HIG).
        #expect(m.iconButtonDiameter == 40)      // ui/IconButton.tsx
        #expect(m.iconGlyphSize == 16)           // 40 − 2×12
        #expect(m.minimumTapTarget == 44)        // iOS deviation, not web
        #expect(m.minimumTapTarget > m.iconButtonDiameter, "the hit area inflates, the disc does not")
        // The composer shell no longer compensates for an inflated frame, so it is web's plain 8.
        #expect(m.composerShellPadding == m.controlPadding)
        // That the control *occupies* 40pt rather than 44 is a layout fact, not a constant, so it
        // is asserted where the layout is actually measured: `DesignSystemTests.iconButtonGeometry`
        // renders unframed and requires 80px at 2×. A probe of glyph ink cannot show it — a `.ghost`
        // button draws no disc, so its ink is the 16pt glyph and would pass at any frame size.
    }

    @Test("Typography is web's point sizes, all regular")
    func typography() {
        // Web: text-base 16/24 bodies and composer, text-sm 14/20, text-xs 12/16 status and
        // badges, text-lg 18/28 greeting, text-xl 20/28 titles (the catalogue's typography section).
        #expect(m.bodyFont == .system(size: 16))
        #expect(m.smallFont == .system(size: 14))
        #expect(m.captionFont == .system(size: 12))
        #expect(m.greetingFont == .system(size: 18))
        #expect(m.titleFont == .system(size: 20))
        // iOS `.body` is 17pt, which is what these replace — the whole point of the chunk.
        #expect(m.bodyFont != .body)
        // Leading is approached, not matched: see the note on `bodyLineSpacing`.
        #expect(m.bodyLineSpacing > 0)
    }

    @Test("Type scales with Dynamic Type, which web has no equivalent of")
    func typeScales() {
        let big = TranscriptMetrics(scale: TranscriptMetrics.scale(for: .accessibility3), theme: .default)
        #expect(big.bodyFont != m.bodyFont)
        #expect(big.bodyLineSpacing > m.bodyLineSpacing)
    }

    @Test("The launch button is web's: a 32pt glyph in 12pt padding, which is what makes it 56")
    func launchGeometry() {
        // ui/LaunchButton.tsx:32 — `w-8 h-8` glyph inside `p-3`.
        #expect(m.launchGlyphSize == 32)
        #expect(m.launchPadding == 12)
        #expect(m.launchButtonSize == m.launchGlyphSize + 2 * m.launchPadding,
                "56 is derived from the glyph and its padding, not chosen")
    }

    @Test("TextButton padding matches web, which is what the suggested replies are built from")
    func textButtonGeometry() {
        #expect(m.textButtonHorizontalPadding == 20)  // ui/TextButton.tsx — px-5
        #expect(m.textButtonVerticalPadding == 16)    // py-4
    }

    @Test("Text-driven space scales linearly; control geometry stops at 1.6× — the settled deviation")
    func scalingPolicy() {
        let big = TranscriptMetrics(scale: TranscriptMetrics.scale(for: .accessibility3), theme: .default)
        // Text and the space around it grow with the text they separate.
        #expect(big.responseSpacing > m.responseSpacing)
        #expect(big.bodyFont != m.bodyFont)
        // Controls stop at 1.6×, so a four-item rail still fits a phone. Web has no Dynamic Type,
        // so this is an iOS-only choice; it is the owner's decision, not an open question.
        #expect(big.iconButtonDiameter == 40 * 1.6)
        #expect(big.launchGlyphSize == 32 * 1.6)
        // The raw factor at this size is well above the cap — i.e. the cap is actually binding.
        #expect(TranscriptMetrics.scale(for: .accessibility3) > 1.6)
        // And the cap never shrinks a control below web's size at the default content size.
        #expect(m.iconButtonDiameter == 40)
    }
}
