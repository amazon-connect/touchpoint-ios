import SwiftUI
import UIKit
import TouchpointCore

/// Acme Bank's palette. Invented for the demo; nothing here reproduces another bank's identity.
/// `Partner` holds the colours a partner's web chat configuration sets, which the demo can apply to
/// the chat alone; no logo or name comes with them.
enum Palette {
    /// Deep teal: the brand colour, used for primary actions and the header bar.
    /// A partner brand's tint replaces it (`PartnerBrand.tint`).
    static let brand = PartnerBrand.tint ?? Color(.sRGB, red: 0.00, green: 0.42, blue: 0.45)
    static let brandDark = Color(.sRGB, red: 0.00, green: 0.30, blue: 0.33)
    /// Warm sand: tints and secondary surfaces.
    static let sand = Color(.sRGB, red: 0.96, green: 0.93, blue: 0.86)
    /// A text field's surface. Sand is a **fixed light** colour, so using it directly put the
    /// system's adaptive label — white in dark mode — on a near-white background and the typed text
    /// was invisible. Inputs therefore adapt like the rest of the screens do: sand in light, a dark
    /// elevated grey in dark, both of which the default label reads against.
    static let field = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.17, green: 0.17, blue: 0.18, alpha: 1) : UIColor(red: 0.96, green: 0.93, blue: 0.86, alpha: 1) })
    static let ink = Color.primary
    /// Secondary text that still clears WCAG AA: the system `.secondary` lands near 3.3:1 on white.
    static let muted = Color.primary.opacity(0.72)
    /// Semantic colours carry a light and a dark value. The light `positive` was 4.28:1 on white —
    /// below WCAG AA's 4.5:1 and untested; it is now a deeper forest green at ~5.8:1, comfortably
    /// clear with headroom, same hue. A red deep enough to read on white lands near 2.6:1 on
    /// a dark card, which is why each has a dark value too; those clear AA against the dark
    /// grouped-cell background (positive 8.4:1, negative 6.4:1).
    static let positive = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0.35, green: 0.80, blue: 0.50, alpha: 1) : UIColor(red: 0.05, green: 0.46, blue: 0.24, alpha: 1) })
    static let negative = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1.00, green: 0.45, blue: 0.45, alpha: 1) : UIColor(red: 0.70, green: 0.16, blue: 0.16, alpha: 1) })
    /// The assistant's call-to-action. The bank screens (design-05…12) give the "Voice mode" pill a
    /// warm, saturated colour that is deliberately *not* the brand teal, so it reads as the one thing
    /// on the panel asking to be tapped. Deep enough that white ink clears AA with headroom (5.5:1)
    /// and beats black (3.8:1), so the SDK's contrast-chosen ink is white, as the design draws it.
    /// The headroom is not decoration: the accessibility audit measures rendered pixels, and at
    /// 4.8:1 the anti-aliased label edges on the launcher failed it in dark mode.
    static let voice = Color(.sRGB, red: 0.72, green: 0.26, blue: 0.00)

    /// The chat surface. Web parity is the bar, so the demo takes the SDK's defaults — the
    /// translucent glass panel, the monochrome alpha ladder — and sets only an accent, which is what
    /// a real integrator does. Web uses the accent sparingly (caret, loader, ripple, selected card),
    /// so the brand teal reads as a signature rather than paint.
    static var chatTheme: TouchpointTheme { TouchpointTheme(accent: brand) }

    // MARK: Partner bank look

    /// The colours a partner bank's web configuration sets (its Touchpoint web `theme` and
    /// `headerStyle`), so the iOS chat can be shown to that partner with the same options. Only the
    /// options: the logo and name stay Acme's.
    enum Partner {
        static let ink = Color(.sRGB, red: 28 / 255, green: 28 / 255, blue: 28 / 255)
        static let green = Color(.sRGB, red: 0, green: 138 / 255, blue: 0)
        static let header = Color(.sRGB, red: 0, green: 0x2B / 255, blue: 0x1A / 255)
        /// The bubbles' `1px solid #cccccc`.
        static let bubbleBorder = Color(.sRGB, red: 0xCC / 255, green: 0xCC / 255, blue: 0xCC / 255)

        /// `theme` with `backgroundDepthLayer: false` and `fontFamily: "Helvetica"`. Its
        /// `light-dark()` pairs stay pairs: the chat is held light (`colorMode: "light"`), but the
        /// header's `colorScheme: "dark"` resolves the dark side, which is what draws its controls
        /// white on the green bar.
        static var chatTheme: TouchpointTheme {
            TouchpointTheme(primary: pair(light: ink, dark: .white), secondary: pair(light: .white, dark: ink),
                            accent: green, background: pair(light: .white, dark: ink), focus: green,
                            backgroundDepthLayer: false, fontFamily: "Helvetica")
        }

        /// CSS `light-dark(light, dark)`.
        static func pair(light: Color, dark: Color) -> Color {
            Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light) })
        }
    }
}
