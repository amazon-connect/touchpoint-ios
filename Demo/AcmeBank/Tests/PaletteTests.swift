import SwiftUI
import Testing
@testable import AcmeBank

/// The demo's chat theme puts white text on the brand teal. WCAG AA needs 4.5:1; measured, not assumed.
@Suite("Acme Bank palette")
struct PaletteTests {
    /// Relative luminance of `c` composited over `background` — opacity matters: `.primary.opacity(0.72)`
    /// is not black, and a test that ignored alpha would pass at any opacity.
    private func luminance(_ c: Color, over background: Color) -> Double {
        var env = EnvironmentValues(); env.colorScheme = .light
        let f = c.resolve(in: env), b = background.resolve(in: env)
        let a = Double(f.opacity)
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        func ch(_ fv: Float, _ bv: Float) -> Double { lin(Double(fv) * a + Double(bv) * (1 - a)) }
        return 0.2126 * ch(f.red, b.red) + 0.7152 * ch(f.green, b.green) + 0.0722 * ch(f.blue, b.blue)
    }
    private func contrast(_ text: Color, on background: Color) -> Double {
        let l1 = luminance(text, over: background), l2 = luminance(background, over: background)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    @Test("The chat theme sets only an accent, on the SDK's web-parity glass surface")
    func brandAccent() {
        let theme = Palette.chatTheme
        #expect(theme.accentIsBrand)
        #expect(theme.accent == Palette.brand)
        #expect(theme.surface == .glass, "web has one surface; the demo takes the default")
    }

    @Test("White on the voice colour (the Voice mode pill) clears AA")
    func whiteOnVoice() {
        #expect(contrast(.white, on: Palette.voice) >= 4.5)
    }

    @Test("The partner look's inks clear AA: its text on white, white on its green and on its header")
    func partnerContrast() {
        #expect(contrast(Palette.Partner.ink, on: .white) >= 4.5)
        #expect(contrast(.white, on: Palette.Partner.green) >= 4.5)
        #expect(contrast(.white, on: Palette.Partner.header) >= 4.5)
    }

    @Test("The partner theme is the configuration's: every colour set, no depth layers, Helvetica")
    func partnerTheme() {
        let theme = Palette.Partner.chatTheme
        #expect(theme.accentIsBrand)
        #expect(theme.backgroundIsBrand)
        #expect(theme.accent == Palette.Partner.green)
        #expect(theme.focus == Palette.Partner.green)
        #expect(!theme.backgroundDepthLayer)
        #expect(theme.fontFamily == "Helvetica")
        // The `light-dark()` pairs: dark ink in light, white in dark (the header bar).
        var light = EnvironmentValues(); light.colorScheme = .light
        var dark = EnvironmentValues(); dark.colorScheme = .dark
        #expect(contrast(theme.primary, on: .white) >= 4.5)
        #expect(theme.primary.resolve(in: dark).red > 0.99)
        #expect(theme.primary.resolve(in: light).red < 0.2)
        #expect(theme.background.resolve(in: light).red > 0.99)
    }

    @Test("White on the brand colour (launcher, primary buttons) clears AA")
    func whiteOnBrand() {
        #expect(contrast(.white, on: Palette.brand) >= 4.5)
    }

    @Test("Muted text clears AA on white")
    func mutedOnWhite() {
        #expect(contrast(Palette.muted, on: .white) >= 4.5)
        // And the method is not vacuous: a faint grey must fail it.
        #expect(contrast(Color.primary.opacity(0.3), on: .white) < 4.5)
    }

    @Test("The positive semantic colour clears AA on white with headroom")
    func positiveOnWhite() {
        // The light value used to be 4.28:1 (an AA fail); it now clears 4.5:1 with ≥5.5 headroom.
        #expect(contrast(Palette.positive, on: .white) >= 5.5)
    }
}
