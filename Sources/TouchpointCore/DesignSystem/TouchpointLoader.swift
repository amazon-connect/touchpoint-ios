import SwiftUI

/// Web's `LoaderAnimation` (`ui/Loader.tsx`): two accent dots that pull apart and back, joined by
/// a goo bridge while close, turning a quarter each cycle, with a glow when they merge. 990 ms of
/// movement and a 300 ms pause. Drawn in web's 100-unit view box, scaled to `size`.
///
/// Under Reduce Motion it draws the resting frame, the two dots merged, and does not animate.
/// It is a status: it carries `label` for VoiceOver and updates frequently.
package struct TouchpointLoader: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let size: CGFloat
    private let label: String
    /// The glow grows with the loader's own size against web's 32pt.
    private var glowScale: CGFloat { size / Self.webSize }
    @State private var start = Date()
    /// Tests stand in for the system setting, which the environment does not let them set.
    var reduceMotionOverride: Bool?

    package init(size: CGFloat, label: String) {
        self.size = size
        self.label = label
    }

    package var body: some View {
        Group {
            if reduceMotionOverride ?? reduceMotion {
                canvas(Self.frame(atMilliseconds: Self.moveDuration))
            } else {
                TimelineView(.animation) { context in
                    canvas(Self.frame(atMilliseconds: context.date.timeIntervalSince(start) * 1000))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func canvas(_ frame: Frame) -> some View {
        // Web glows in the accent when the host set one, else in the focus colour.
        let glow = theme.accentIsBrand ? theme.accent : theme.focus
        let fill = theme.accent
        return Canvas { context, canvasSize in
            // Web's glow is a CSS `drop-shadow` on the svg element, so its 0…5 is points at the
            // drawn size, not view-box units: added before the view-box transform.
            if frame.glow > 0 {
                context.addFilter(.shadow(color: glow, radius: frame.glow * glowScale))
            }
            let scale = canvasSize.width / Self.viewBox
            context.translateBy(x: canvasSize.width / 2, y: canvasSize.height / 2)
            context.rotate(by: .degrees(frame.spin * 90))
            context.scaleBy(x: scale, y: scale)
            context.opacity = frame.opacity
            context.fill(Self.pair(halfDistance: Self.r * frame.distance), with: .color(fill))
        }
    }

    // MARK: Web's geometry and timing (pure, so it is testable)

    static let viewBox: CGFloat = 100
    /// Web's `Loader` box (`w-8 h-8`), against which the glow's points are given.
    static let webSize: CGFloat = 32
    static let r: CGFloat = 30
    static let rc: CGFloat = 17
    static let moveDuration: Double = 990
    static let pauseDuration: Double = 300
    static var totalDuration: Double { moveDuration + pauseDuration }

    struct Frame: Equatable {
        /// The dots' half-distance as a fraction of `r`.
        var distance: CGFloat
        /// Quarter turns.
        var spin: Double
        /// The drop-shadow radius in points at web's 32pt size (a CSS `drop-shadow`).
        var glow: CGFloat
        var opacity: Double
    }

    static func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }

    static func distance(_ t: Double) -> Double {
        if t < 1.0 / 3 { return t * 3 }
        if t < 2.0 / 3 { return 1 }
        return 3 - t * 3
    }

    static func spin(_ t: Double) -> Double {
        if t < 1.0 / 3 { return 0 }
        if t < 2.0 / 3 { return (t - 1.0 / 3) * 3 }
        return 1
    }

    /// The frame `ms` after the animation starts (`LoaderAnimation`'s body).
    static func frame(atMilliseconds ms: Double) -> Frame {
        let elapsed = ms.truncatingRemainder(dividingBy: totalDuration)
        let count = Int((ms / totalDuration).rounded(.down))
        var d = 0.0, turn = 0.0
        if elapsed < moveDuration {
            let adjusted = ms / totalDuration
            let t = ease((adjusted - adjusted.rounded(.down)) * (totalDuration / moveDuration))
            d = distance(t)
            turn = count % 2 == 1 ? spin(t) : 1 + spin(t)
        }
        let glow = d > 0.2 ? 0 : 5 * (0.2 - d) / 0.2
        let threshold = 0.3
        let opacity = d > threshold ? 1 - 0.25 * (d - threshold) / (1 - threshold) : 1
        return Frame(distance: CGFloat(d), spin: turn, glow: CGFloat(glow), opacity: opacity)
    }

    /// Web's `Pair`: two circles `d` either side of the centre, and the goo between them while they
    /// are close enough. Web draws them as separate SVG shapes; here they are unioned, so opposite
    /// windings cannot cancel where they overlap, and the group's opacity composites once.
    static func pair(halfDistance d: CGFloat) -> Path {
        let circles = Path(ellipseIn: CGRect(x: -d - rc, y: -rc, width: rc * 2, height: rc * 2))
            .union(Path(ellipseIn: CGRect(x: d - rc, y: -rc, width: rc * 2, height: rc * 2)))
        let limitRatio = d / rc / 2.8
        guard limitRatio < 0.45 else { return circles }
        var path = Path()
        let angle = CGFloat.pi / 2 * min(limitRatio, 1)
        let s = limitRatio < 1 ? (d - sin(angle)) / cos(angle) * 0.5 : 0
        let edgeX = d - rc * sin(angle), edgeY = rc * cos(angle)
        let controlX = edgeX - s * cos(angle), controlY = edgeY - s * sin(angle)
        path.move(to: CGPoint(x: -edgeX, y: edgeY))
        path.addCurve(to: CGPoint(x: edgeX, y: edgeY), control1: CGPoint(x: -controlX, y: controlY),
                      control2: CGPoint(x: controlX, y: controlY))
        path.addLine(to: CGPoint(x: edgeX, y: -edgeY))
        path.addCurve(to: CGPoint(x: -edgeX, y: -edgeY), control1: CGPoint(x: controlX, y: -controlY),
                      control2: CGPoint(x: -controlX, y: -controlY))
        path.closeSubpath()
        return circles.union(path)
    }
}
