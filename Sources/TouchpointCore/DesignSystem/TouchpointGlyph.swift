import SwiftUI

/// The Touchpoint mark: a wavy S-ribbon with four dots around it (`ui/Icons.tsx:610-620`).
///
/// Drawn from the web SDK's own path data rather than approximated by an SF Symbol — the launch
/// button is the product's one piece of identity, and a sparkle is not it. Transcribed as vector
/// commands instead of a bundled asset so the package still ships as source with no resources, and
/// so it scales to any size and takes the current foreground colour.
public struct TouchpointGlyph: Shape, Sendable {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        // The source viewBox is 24×24; scale uniformly and centre, so a non-square frame does not
        // stretch the mark.
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let origin = CGPoint(x: rect.midX - side / 2, y: rect.midY - side / 2)

        var path = Path()
        for command in Self.commands {
            command.apply(to: &path, scale: scale, origin: origin)
        }
        return path
    }

    /// One vector command in viewBox coordinates. Only the forms the source path uses: a move, a
    /// cubic curve, and a close.
    enum Command: Sendable {
        case move(CGPoint)
        case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
        case close

        func apply(to path: inout Path, scale: CGFloat, origin: CGPoint) {
            func p(_ point: CGPoint) -> CGPoint {
                CGPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
            }
            switch self {
            case .move(let to): path.move(to: p(to))
            case .curve(let to, let c1, let c2): path.addCurve(to: p(to), control1: p(c1), control2: p(c2))
            case .close: path.closeSubpath()
            }
        }
    }

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// The ribbon, then the four dots, in source order.
    static let commands: [Command] = ribbon + dots

    /// `Icons.tsx:612` — the S-ribbon.
    private static let ribbon: [Command] = [
        .move(pt(13.5562, 5.34835)),
        .curve(to: pt(14.0186, 10.4337), control1: pt(12.2796, 6.62498), control2: pt(12.4866, 8.90179)),
        .curve(to: pt(14.6767, 11.5383), control1: pt(14.3377, 10.7529), control2: pt(14.5571, 11.134)),
        .curve(to: pt(14.7277, 12.8268), control1: pt(14.8007, 11.9572), control2: pt(14.8177, 12.4011)),
        .curve(to: pt(14.3887, 13.6672), control1: pt(14.6656, 13.1203), control2: pt(14.5526, 13.4051)),
        .curve(to: pt(14.1778, 13.9581), control1: pt(14.3259, 13.7677), control2: pt(14.2557, 13.865)),
        .curve(to: pt(14.0186, 14.1322), control1: pt(14.1279, 14.018), control2: pt(14.0747, 14.0761)),
        .curve(to: pt(11.4917, 14.8092), control1: pt(13.3341, 14.8166), control2: pt(12.3641, 15.0421)),
        .curve(to: pt(6.85652, 16.9516), control1: pt(9.38654, 14.2543), control2: pt(7.32235, 15.2129)),
        .curve(to: pt(4.45431, 18.3385), control1: pt(6.5761, 17.9979), control2: pt(5.50065, 18.6188)),
        .curve(to: pt(3.06729, 15.9363), control1: pt(3.40798, 18.0581), control2: pt(2.787, 16.9826)),
        .curve(to: pt(5.40615, 14.5335), control1: pt(3.34209, 14.9111), control2: pt(4.38012, 14.2942)),
        .curve(to: pt(5.46962, 14.5493), control1: pt(5.42748, 14.5378), control2: pt(5.44842, 14.5437)),
        .curve(to: pt(9.64244, 11.6062), control1: pt(7.21342, 15.0166), control2: pt(9.08173, 13.699)),
        .curve(to: pt(9.66185, 11.5383), control1: pt(9.64857, 11.5835), control2: pt(9.65521, 11.5608)),
        .curve(to: pt(10.32, 10.4337), control1: pt(9.7815, 11.134), control2: pt(10.0009, 10.7529)),
        .curve(to: pt(10.3533, 10.4), control1: pt(10.339, 10.4142), control2: pt(10.346, 10.407)),
        .curve(to: pt(10.7824, 5.34835), control1: pt(11.8549, 8.86865), control2: pt(12.0496, 6.61566)),
        .curve(to: pt(10.7824, 2.57449), control1: pt(10.0163, 4.58237), control2: pt(10.0163, 3.34047)),
        .curve(to: pt(13.5562, 2.57449), control1: pt(11.5483, 1.8085), control2: pt(12.7903, 1.8085)),
        .curve(to: pt(13.6016, 5.30135), control1: pt(14.3066, 3.32501), control2: pt(14.3218, 4.53237)),
        .curve(to: pt(13.5562, 5.34835), control1: pt(13.5872, 5.3177), control2: pt(13.5716, 5.33289)),
        .close,
    ]

    /// `Icons.tsx:614-617` — the four dots, each a circle expressed as two curves in the source.
    private static let dots: [Command] = circle(cx: 19.327, cy: 8.10675, r: 1.27491)
        + circle(cx: 19.3297, cy: 16.4754, r: 1.99405)
        + circle(cx: 12.1025, cy: 20.6597, r: 1.34032)
        + circle(cx: 4.94339, cy: 8.13944, r: 1.34028)

    /// A circle as four cubic arcs: the source writes each dot as curves, and a `Path` built from
    /// `addEllipse` would not compose with the ribbon's fill rule the same way.
    private static func circle(cx: CGFloat, cy: CGFloat, r: CGFloat) -> [Command] {
        let k = r * 0.5522847498   // the circular-arc control-point constant
        return [
            .move(pt(cx + r, cy)),
            .curve(to: pt(cx, cy + r), control1: pt(cx + r, cy + k), control2: pt(cx + k, cy + r)),
            .curve(to: pt(cx - r, cy), control1: pt(cx - k, cy + r), control2: pt(cx - r, cy + k)),
            .curve(to: pt(cx, cy - r), control1: pt(cx - r, cy - k), control2: pt(cx - k, cy - r)),
            .curve(to: pt(cx + r, cy), control1: pt(cx + k, cy - r), control2: pt(cx + r, cy - k)),
            .close,
        ]
    }
}
