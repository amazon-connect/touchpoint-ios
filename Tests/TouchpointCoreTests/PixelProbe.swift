import CoreGraphics
import SwiftUI

/// Pixel measurements for design-system tests. Properties are asserted, never golden bytes: a PNG
/// churns on every OS bump, while "the right edge is tinted" or "disabled ink is lighter" are the
/// facts the design actually states.
@MainActor
enum PixelProbe {
    struct Pixels {
        let bytes: [UInt8]
        let width: Int
        let height: Int

        /// Straight (un-premultiplied) RGBA in 0…1 at a point.
        func rgba(x: Int, y: Int) -> (r: Double, g: Double, b: Double, a: Double) {
            let i = (y * width + x) * 4
            let a = Double(bytes[i + 3]) / 255
            guard a > 0 else { return (0, 0, 0, 0) }
            return (Double(bytes[i]) / 255 / a, Double(bytes[i + 1]) / 255 / a, Double(bytes[i + 2]) / 255 / a, a)
        }

        /// Mean luminance of pixels with alpha above the threshold, inside a horizontal band of the
        /// image (`xRange` as fractions of width). Transparent pixels are excluded so a measurement of
        /// ink is not diluted by the background it sits on. With `overWhite`, each pixel is first
        /// composited over white — what the eye sees of a translucent ink on a light page.
        func meanLuminance(xRange: ClosedRange<Double> = 0...1, yRange: ClosedRange<Double> = 0...1,
                           minAlpha: Double = 0.05, overWhite: Bool = false) -> Double {
            var total = 0.0, count = 0.0
            let x0 = Int(Double(width) * xRange.lowerBound), x1 = Int(Double(width) * xRange.upperBound)
            let y0 = Int(Double(height) * yRange.lowerBound), y1 = Int(Double(height) * yRange.upperBound)
            for y in y0..<max(y0 + 1, y1) {
                for x in x0..<max(x0 + 1, x1) {
                    var p = rgba(x: x, y: y)
                    guard p.a > minAlpha else { continue }
                    if overWhite { p = (p.r * p.a + 1 - p.a, p.g * p.a + 1 - p.a, p.b * p.a + 1 - p.a, 1) }
                    total += min(1, 0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b)
                    count += 1
                }
            }
            return count > 0 ? total / count : 0
        }

        /// Fraction of pixels whose alpha is below the threshold.
        func transparentFraction(maxAlpha: Double = 0.05) -> Double {
            var n = 0.0
            for y in 0..<height { for x in 0..<width where rgba(x: x, y: y).a < maxAlpha { n += 1 } }
            return n / Double(width * height)
        }

        /// Horizontal centre of mass of drawn pixels, 0 = left edge.
        func inkCentroidX(minAlpha: Double = 0.05) -> Double {
            var weighted = 0.0, mass = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let a = rgba(x: x, y: y).a
                    guard a > minAlpha else { continue }
                    weighted += Double(x) * a
                    mass += a
                }
            }
            return mass > 0 ? weighted / mass / Double(width) : 0.5
        }

        /// Bounding box of drawn pixels, in points of the rendered view (divides by `scale`).
        func inkBounds(scale: Double, minAlpha: Double = 0.05) -> CGRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width where rgba(x: x, y: y).a > minAlpha {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return CGRect(x: Double(minX) / scale, y: Double(minY) / scale,
                          width: Double(maxX - minX + 1) / scale, height: Double(maxY - minY + 1) / scale)
        }

        /// Mean red minus mean of green and blue over drawn pixels: positive means red-dominant.
        func redDominance(minAlpha: Double = 0.5) -> Double {
            var r = 0.0, gb = 0.0, n = 0.0
            for y in 0..<height {
                for x in 0..<width {
                    let p = rgba(x: x, y: y)
                    guard p.a > minAlpha else { continue }
                    r += p.r; gb += (p.g + p.b) / 2; n += 1
                }
            }
            return n > 0 ? (r - gb) / n : 0
        }
    }

    static func pixels(_ cg: CGImage) -> Pixels? {
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &bytes, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Pixels(bytes: bytes, width: width, height: height)
    }

    /// Renders a view with the given scheme, 2× scale. With a `width` the view is framed (and
    /// `height` if given); without one it is laid out at its own ideal size.
    static func render<V: View>(_ view: V, width: CGFloat?, height: CGFloat? = nil,
                                colorScheme: ColorScheme = .light) -> Pixels? {
        let framed = Group {
            if let width, let height { view.frame(width: width, height: height) }
            else if let width { view.frame(width: width) }
            else { view }
        }
        .environment(\.colorScheme, colorScheme)
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        return pixels(cg)
    }

    /// WCAG relative luminance of an opaque sRGB colour.
    static func relativeLuminance(r: Double, g: Double, b: Double) -> Double {
        func channel(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrast(_ l1: Double, _ l2: Double) -> Double {
        (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    /// Composites a resolved colour over an opaque backdrop (straight alpha).
    static func composite(_ c: Color.Resolved, over backdrop: (r: Double, g: Double, b: Double)) -> (r: Double, g: Double, b: Double) {
        let a = Double(c.opacity)
        return (Double(c.red) * a + backdrop.r * (1 - a),
                Double(c.green) * a + backdrop.g * (1 - a),
                Double(c.blue) * a + backdrop.b * (1 - a))
    }
}
