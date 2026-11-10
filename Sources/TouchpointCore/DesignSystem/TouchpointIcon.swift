import SwiftUI

/// The Touchpoint icon set: web's icons (`ui/Icons.tsx`), drawn from their own path data rather
/// than approximated by SF Symbols, which drew a different glyph for most of them and read larger
/// at the same point size (design QA c03, c05 and others). The paths are in
/// `TouchpointIconPaths.swift`.
///
/// **Trade-off:** a drawn shape does not thicken with the Bold Text setting the way a symbol does.
/// Directional icons (Send, ArrowForward, Undo) do not mirror in right-to-left layouts, as web's
/// do not; SF Symbols did.
package enum TouchpointIcon: String, CaseIterable, Sendable {
    case restart, minimize, close, settings, undo, send, arrowForward, arrowRight, logOut
    case download, copy, delete, thumbUp, thumbDown, check, checkDouble, time, error, warning, date
    case play, user, bot, escalate, mic, micOff, volume, volumeOff, reorder, screenShare, attachment
    case smallTalk, fullScreen
    /// Web's `Guide` is the one stroked icon (a rounded rectangle and two rules), so it is built
    /// from shapes rather than parsed.
    case guide
}

/// One `<path>` of an icon: its `d` string and whether it fills even-odd (`fillRule="evenodd"`).
/// The rule is per path — several icons mix both.
package struct TouchpointIconPath: Sendable {
    package let evenOdd: Bool
    package let d: String
}

extension EnvironmentValues {
    /// The side of the box an icon is drawn in. Set by the button styles (16 in a 40pt button, 12
    /// in a compact one) so an icon in their label takes the button's size, as web's icons fill
    /// `100%` of their slot.
    @Entry package var touchpointIconSize: CGFloat = 16
}

/// An icon at the size the environment gives it, in the current foreground style. Decorative: the
/// control that carries it owns the accessibility label.
package struct TouchpointIconView: View {
    @Environment(\.touchpointIconSize) private var environmentSize
    private let icon: TouchpointIcon
    private let size: CGFloat?

    /// - Parameter size: overrides the environment's size, for an icon outside a button style.
    package init(_ icon: TouchpointIcon, size: CGFloat? = nil) {
        self.icon = icon
        self.size = size
    }

    package var body: some View {
        let side = size ?? environmentSize
        Group {
            if icon == .guide {
                GuideIconShape()
                    .stroke(style: StrokeStyle(lineWidth: side * 1.75 / 24, lineCap: .round, lineJoin: .round))
            } else {
                ZStack {
                    ForEach(Array(TouchpointIconCache.paths(icon).enumerated()), id: \.offset) { _, part in
                        IconPathShape(path: part.path).fill(style: FillStyle(eoFill: part.evenOdd))
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

/// Parsed once per icon, on first use. A path that fails to parse draws nothing rather than
/// trapping (the no-crash lint); `SVGPathParserTests` holds every icon to parsing.
package enum TouchpointIconCache {
    package struct Part: Sendable {
        package let evenOdd: Bool
        package let path: Path
    }

    private static let parsed: [TouchpointIcon: [Part]] = Dictionary(uniqueKeysWithValues: TouchpointIcon.allCases.map { icon in
        (icon, icon.pathData.map { data in
            guard let path = SVGPathParser.parse(data.d) else {
                #if DEBUG
                print("Touchpoint: icon \(icon) has a path that does not parse; it draws nothing")
                #endif
                return Part(evenOdd: data.evenOdd, path: Path())
            }
            return Part(evenOdd: data.evenOdd, path: path)
        })
    })

    package static func paths(_ icon: TouchpointIcon) -> [Part] { parsed[icon] ?? [] }
}

/// A path in viewBox units, scaled uniformly from 24×24 into the frame and centred.
struct IconPathShape: Shape {
    let path: Path

    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let scale = side / 24
        let transform = CGAffineTransform(translationX: rect.midX - side / 2, y: rect.midY - side / 2)
            .scaledBy(x: scale, y: scale)
        return path.applying(transform)
    }
}

/// Web's `Guide`: `<rect x=3 y=5 width=18 height=14 rx=2/>`, `M3 10h18`, `M6 15h4`, stroked.
struct GuideIconShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 14), cornerSize: CGSize(width: 2, height: 2),
                            style: .circular)
        path.move(to: CGPoint(x: 3, y: 10)); path.addLine(to: CGPoint(x: 21, y: 10))
        path.move(to: CGPoint(x: 6, y: 15)); path.addLine(to: CGPoint(x: 10, y: 15))
        return IconPathShape(path: path).path(in: rect)
    }
}

/// The SVG path syntax web's icons use: `M L H V C Z` and their relative forms, with implicit
/// repeats (a coordinate pair after `M` is a line). Smooth and quadratic curves and arcs are not
/// used by any icon here and fail the parse, so a new icon that needs them is caught by the tests
/// instead of drawing wrongly.
package enum SVGPathParser {
    package static func parse(_ d: String) -> Path? {
        var scanner = Scanner(d)
        var path = Path()
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var command: Character?
        while let next = scanner.nextCommandOrNumber() {
            let c: Character
            switch next {
            case .command(let letter):
                c = letter
            case .number:
                // An implicit repeat of the previous command; after a move it is a line.
                guard let previous = command, previous != "Z", previous != "z" else { return nil }
                scanner.rewind()
                c = previous == "M" ? "L" : previous == "m" ? "l" : previous
            }
            let relative = c.isLowercase
            let origin = relative ? current : .zero
            switch c.uppercased() {
            case "M":
                guard let p = scanner.point() else { return nil }
                current = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                subpathStart = current
                path.move(to: current)
            case "L":
                guard let p = scanner.point() else { return nil }
                current = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                path.addLine(to: current)
            case "H":
                guard let x = scanner.number() else { return nil }
                current = CGPoint(x: (relative ? current.x : 0) + x, y: current.y)
                path.addLine(to: current)
            case "V":
                guard let y = scanner.number() else { return nil }
                current = CGPoint(x: current.x, y: (relative ? current.y : 0) + y)
                path.addLine(to: current)
            case "C":
                guard let c1 = scanner.point(), let c2 = scanner.point(), let p = scanner.point() else { return nil }
                let to = CGPoint(x: origin.x + p.x, y: origin.y + p.y)
                path.addCurve(to: to,
                              control1: CGPoint(x: origin.x + c1.x, y: origin.y + c1.y),
                              control2: CGPoint(x: origin.x + c2.x, y: origin.y + c2.y))
                current = to
            case "Z":
                path.closeSubpath()
                current = subpathStart
            default:
                return nil
            }
            command = c
        }
        return scanner.isAtEnd ? path : nil
    }

    /// Splits a `d` string into command letters and numbers (`-` and `.` start a new number, as in
    /// `1.5-2.5.5`).
    struct Scanner {
        enum Token { case command(Character), number(CGFloat) }
        private let chars: [Character]
        private var index = 0
        private var lastStart = 0

        init(_ string: String) { chars = Array(string) }

        var isAtEnd: Bool {
            var i = index
            while i < chars.count, chars[i].isWhitespace || chars[i] == "," { i += 1 }
            return i == chars.count
        }

        mutating func rewind() { index = lastStart }

        mutating func nextCommandOrNumber() -> Token? {
            skipSeparators()
            guard index < chars.count else { return nil }
            lastStart = index
            let c = chars[index]
            if c.isLetter {
                index += 1
                return .command(c)
            }
            return number().map { .number($0) }
        }

        mutating func point() -> CGPoint? {
            guard let x = number(), let y = number() else { return nil }
            return CGPoint(x: x, y: y)
        }

        mutating func number() -> CGFloat? {
            skipSeparators()
            let start = index
            if index < chars.count, chars[index] == "-" || chars[index] == "+" { index += 1 }
            var sawDot = false, sawDigit = false
            while index < chars.count {
                let c = chars[index]
                if c.isASCII, c.isNumber { sawDigit = true; index += 1 }
                else if c == ".", !sawDot { sawDot = true; index += 1 }
                else { break }
            }
            guard sawDigit, let value = Double(String(chars[start..<index])) else {
                index = start
                return nil
            }
            return CGFloat(value)
        }

        private mutating func skipSeparators() {
            while index < chars.count, chars[index].isWhitespace || chars[index] == "," { index += 1 }
        }
    }
}
