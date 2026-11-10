import SwiftUI
import TouchpointCore

/// Width thresholds for tablet and wide layouts (B6 / TB-1…TB-3), as pure functions so every
/// decision is unit-testable without rendering. The breakpoints are web's, matched by the Android
/// SDK (`TouchpointMetrics.kt`): 768 (`md:` / `@container md` / `@3xl/main`), 1280 (`xl:`), the
/// 640 content cap (`--container-content`) and the 632 half-panel (`grid-cols-[1fr_632px]`).
///
/// Web keys TB-1 (insets, content cap) and TB-2 (floating header) off the panel's **own** width
/// (CSS container queries on `@container/main`); the SDK does the same by driving them off the chat
/// surface's available width. TB-3 (the half-screen dock) is sized from the **window** width, as
/// web's grid is. Below the breakpoint every value is the phone's, so a phone renders exactly as
/// before.
enum WideLayout {
    /// Web's `md:` / `@3xl/main` breakpoint — wider insets, the content cap, and the floating header.
    static let wideBreakpoint: CGFloat = 768
    /// Web's `xl:` — where the half-screen panel stops being half and holds at `halfPanelWidth`.
    static let largeWindow: CGFloat = 1280
    /// Web's `--container-content`: transcript, composer, welcome and settings cap here and centre.
    static let contentCap: CGFloat = 640
    /// Web's half-screen panel at `xl:` (`grid-cols-[1fr_632px]`).
    static let halfPanelCap: CGFloat = 632
    /// Web's block inset: `p-2` (8) on a phone, `p-3` (12) from the breakpoint.
    static let narrowInset: CGFloat = 8
    static let wideInset: CGFloat = 12

    /// TB-1/TB-2: whether a surface of `width` gets the tablet treatment.
    static func isWide(_ width: CGFloat) -> Bool { width >= wideBreakpoint }

    /// TB-1: the content column's maximum width — `nil` (fill the surface) on a phone, 640 when
    /// wide. The caller centres the capped column.
    static func contentWidth(_ width: CGFloat) -> CGFloat? {
        isWide(width) ? contentCap : nil
    }

    /// TB-1: the block inset around the capped content, scaled with text: 12 when wide, 8
    /// otherwise. `base` is the Dynamic Type scale.
    static func blockInset(_ width: CGFloat, scale: CGFloat) -> CGFloat {
        (isWide(width) ? wideInset : narrowInset) * scale
    }

    /// TB-2: whether the header floats over the content (web's `@3xl/main:absolute`), from the
    /// panel's own width.
    static func headerFloats(_ width: CGFloat) -> Bool { width >= wideBreakpoint }

    /// TB-3: a half-screen panel's width for a window of `windowWidth` — `nil` below the breakpoint
    /// (a phone keeps the bottom-half dock), half the window from 768, capped at 632 from 1280.
    static func halfPanelWidth(windowWidth: CGFloat) -> CGFloat? {
        if windowWidth >= largeWindow { return halfPanelCap }
        if windowWidth >= wideBreakpoint { return windowWidth / 2 }
        return nil
    }
}

/// Caps content at web's 640 and centres it when the surface is wide, with the tablet block inset
/// (TB-1); a no-op on a phone, so phone layout is untouched. Applied to the transcript, composer,
/// welcome and settings — the blocks web holds to `md:max-w-content md:mx-auto`.
struct TabletContentFrame: ViewModifier {
    let width: CGFloat
    let scale: CGFloat

    func body(content: Content) -> some View {
        if let cap = WideLayout.contentWidth(width) {
            content
                .frame(maxWidth: cap)
                .frame(maxWidth: .infinity)                       // centre the capped column
                .padding(.horizontal, WideLayout.blockInset(width, scale: scale) - WideLayout.narrowInset * scale)
        } else {
            content
        }
    }
}

extension View {
    /// See ``TabletContentFrame``. `width` is the surface's available width; `scale` the Dynamic
    /// Type scale, so the inset grows with text.
    func tabletContentFrame(width: CGFloat, scale: CGFloat) -> some View {
        modifier(TabletContentFrame(width: width, scale: scale))
    }
}
