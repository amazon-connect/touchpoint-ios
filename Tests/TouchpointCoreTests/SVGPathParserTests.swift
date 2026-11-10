import SwiftUI
import Testing
@testable import TouchpointCore

/// The icon set is web's path data; these hold the parser to the syntax it uses and every icon to
/// drawing something inside its 24×24 box.
@Suite("Icon paths")
struct SVGPathParserTests {
    @Test("Every icon parses, draws something, and stays inside its 24×24 viewBox")
    func everyIconParses() {
        for icon in TouchpointIcon.allCases where icon != .guide {
            #expect(!icon.pathData.isEmpty, "\(icon) has no paths")
            for part in icon.pathData {
                let path = SVGPathParser.parse(part.d)
                #expect(path != nil, "\(icon) failed to parse")
                let box = path?.boundingRect ?? .null
                #expect(!box.isEmpty, "\(icon) drew nothing")
                #expect(box.minX >= -0.01 && box.minY >= -0.01 && box.maxX <= 24.01 && box.maxY <= 24.01,
                        "\(icon) spills outside its viewBox: \(box)")
            }
        }
    }

    @Test("Absolute and relative commands land on the same points")
    func relativeMatchesAbsolute() throws {
        let absolute = try #require(SVGPathParser.parse("M2 2L10 2H12V8C12 9 11 10 10 10Z"))
        let relative = try #require(SVGPathParser.parse("m2 2l8 0h2v6c0 1-1 2-2 2z"))
        #expect(absolute.boundingRect == relative.boundingRect)
        #expect(absolute.boundingRect == CGRect(x: 2, y: 2, width: 10, height: 8))
    }

    @Test("Numbers run together the way minified SVG writes them, and pairs after M are lines")
    func compactNumbers() throws {
        // `1.5-2.5.5` is three numbers; the second pair after `M` is an implicit line.
        let path = try #require(SVGPathParser.parse("M1.5-2.5.5 4 6,8"))
        #expect(path.boundingRect == CGRect(x: 0.5, y: -2.5, width: 5.5, height: 10.5))
    }

    @Test("Unsupported or malformed input fails rather than drawing something wrong")
    func failsClosed() {
        #expect(SVGPathParser.parse("M0 0A5 5 0 0 1 10 10") == nil)   // arcs are not supported
        #expect(SVGPathParser.parse("M0 0Q5 5 10 10") == nil)          // nor quadratics
        #expect(SVGPathParser.parse("M0") == nil)                      // half a point
        #expect(SVGPathParser.parse("10 10") == nil)                   // a number with no command
        #expect(SVGPathParser.parse("M0 0Z 4 4") == nil)               // a repeat after close
    }

    @Test("Fill rules are per path, as web's Icons.tsx sets them")
    func fillRules() {
        #expect(TouchpointIcon.settings.pathData.map(\.evenOdd) == [true, true])
        #expect(TouchpointIcon.bot.pathData.map(\.evenOdd) == [false, false, true])
        #expect(TouchpointIcon.copy.pathData.map(\.evenOdd) == [true, false])
        #expect(TouchpointIcon.mic.pathData.map(\.evenOdd) == [false, true])
        #expect(TouchpointIcon.screenShare.pathData.map(\.evenOdd) == [false, true])
        #expect(TouchpointIcon.close.pathData.map(\.evenOdd) == [false])
    }

    #if canImport(AppKit) || canImport(UIKit)
    @Test("Even-odd leaves a hole that non-zero fills: two squares wound the same way")
    @MainActor
    func evenOddIsApplied() throws {
        // Both squares clockwise, so non-zero fills the inner one and only even-odd clears it.
        let path = try #require(SVGPathParser.parse("M2 2H22V22H2Z M8 8H16V16H8Z"))
        func centreAlpha(evenOdd: Bool) throws -> UInt8 {
            let renderer = ImageRenderer(content: IconPathShape(path: path).fill(style: FillStyle(eoFill: evenOdd))
                .foregroundStyle(.black).frame(width: 48, height: 48))
            renderer.scale = 1
            let cg = try #require(renderer.cgImage)
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            let ctx = try #require(CGContext(data: &bytes, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                             bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            return bytes[((cg.height / 2) * cg.width + cg.width / 2) * 4 + 3]
        }
        #expect(try centreAlpha(evenOdd: true) < 20)
        #expect(try centreAlpha(evenOdd: false) > 200)
    }

    @Test("An even-odd icon keeps its hole: the settings gear's centre is clear")
    @MainActor
    func evenOddHole() throws {
        let renderer = ImageRenderer(content: TouchpointIconView(.settings, size: 48).foregroundStyle(.black))
        renderer.scale = 1
        let cg = try #require(renderer.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = try #require(CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[(y * w + x) * 4 + 3] }
        #expect(alpha(w / 2, h / 2) < 20, "the gear's hole was filled")
        let inked = (0..<(w * h)).filter { bytes[$0 * 4 + 3] > 128 }.count
        #expect(inked > w * h / 10, "the gear drew almost nothing")
    }
    #endif
}

/// Web's `TextButton`: 56 tall at the default size, and it still grows with the text (design QA c08).
@Suite("Text button")
@MainActor
struct TextButtonStyleTests {
    private func height(_ size: DynamicTypeSize) -> CGFloat {
        let view = Button {} label: { Text(verbatim: "Restart conversation") }
            .buttonStyle(TouchpointTextButtonStyle(.subtle, icon: .restart))
            .frame(width: 360)
            .environment(\.dynamicTypeSize, size)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        return CGFloat(renderer.cgImage?.height ?? 0)
    }

    @Test("56 tall at the default text size, taller at an accessibility size")
    func height() {
        let regular = height(.large)
        #expect(regular >= 56 && regular < 60, "regular \(regular)")
        #expect(height(.accessibility3) > regular * 1.5)
    }
}
