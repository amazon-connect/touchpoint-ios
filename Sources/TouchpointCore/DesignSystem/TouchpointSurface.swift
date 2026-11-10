import CoreGraphics
import os
import SwiftUI

/// The panel every Touchpoint surface sits on. Two treatments, chosen by `theme.surface`:
///
/// **Flat** (default; design-05…12, the bank journey): a solid card in `theme.background` with a
/// drop shadow onto the host. What a docked assistant looks like laid over an app's own screens.
///
/// **Glass** (design-01…04, the vendor template; web: `Layout.tsx` + `BackgroundDecoration.tsx`):
/// a translucent fill over a blurred backdrop, with depth layers that give the surface dimension
/// even over a blank screen while staying translucent enough to read as an overlay above the host:
///
/// 1. **Fill** — `theme.background` over a system material (the material is the backdrop blur).
/// 2. **Wash** — a cool glow bleeding in from the right edge at 48% height, an ellipse 62.5% of the
///    width across and the full height tall. Dropped when the host set its own background, which
///    would otherwise shift the brand's hue.
/// 3. **Sheen** — a 158° white gradient from the top-left, blended soft-light so it lifts the
///    midtones without washing the fill out.
/// 4. **Shade** — settles the bottom edge, so the sheen reads as directional light.
/// 5. **Grain** — a film of procedural noise that keeps the large gradients from banding.
///
/// Layers 3–5 are the decorative depth, gated on `theme.backgroundDepthLayer` exactly as web gates
/// them (`BackgroundDecoration.tsx:41`); the fill, blur and wash are always drawn. A host that wraps
/// the SDK view in a surface of its own should turn the depth off on **its** copy, or the sheen,
/// shade and grain are painted twice.
///
/// Every layer is static, so Reduce Motion does not apply. `bordered` adds the 1pt tier-10 hairline
/// the web draws on floating panels, the composer, the rail and the launch button; the surface is
/// clipped to `shape` either way.
public struct TouchpointSurface<S: InsettableShape>: View {
    @Environment(\.touchpointTheme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.displayScale) private var displayScale
    private let shape: S
    private let bordered: Bool

    public init(in shape: S, bordered: Bool = false) {
        self.shape = shape
        self.bordered = bordered
    }

    public var body: some View {
        switch theme.surface {
        case .flat: flat
        case .glass: glass
        }
    }

    /// The bank-journey card (design-05…12): one solid fill, lifted by a shadow. The shadow sits
    /// outside the clip so it falls on the host, which is what makes the panel read as laid over the
    /// screen rather than painted onto it. Softer and lower in dark, where a black shadow on a dark
    /// host would otherwise vanish or muddy the edge.
    ///
    /// Panels get the full lift. Bordered surfaces are the floating controls — the rail, the launch
    /// button — and a panel's shadow on a 56pt disc reads as a smear, so they get a close, soft one.
    private var flat: some View {
        let control = bordered
        return shape
            .fill(theme.background)
            .shadow(color: .black.opacity(scheme == .dark ? 0.6 : (control ? 0.12 : 0.18)),
                    radius: control ? 8 : 24, y: control ? 2 : -4)
            .shadow(color: .black.opacity(scheme == .dark ? 0.3 : 0.06), radius: control ? 1 : 4, y: control ? 1 : -1)
            .overlay {
                if bordered {
                    let metrics = TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme)
                    shape.strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline)
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    /// The vendor template (design-01…04): the layered translucent panel described above.
    private var glass: some View {
        GeometryReader { geo in
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Rectangle().fill(theme.background)
                if !theme.backgroundIsBrand {
                    // An `EllipticalGradient` fills the ellipse inscribed in its frame, so the frame
                    // *is* the ellipse: radii 0.625 W × H, centred on the right edge at 48% height.
                    // The surface's clip trims what falls outside.
                    let w = geo.size.width, h = geo.size.height
                    EllipticalGradient(colors: [Self.washColor(scheme), Self.washColor(scheme).opacity(0)],
                                       center: .center, startRadiusFraction: 0, endRadiusFraction: 0.5)
                        .frame(width: 2 * 0.625 * w, height: 2 * h)
                        .position(x: w, y: 0.48 * h)
                }
                if theme.backgroundDepthLayer {
                    LinearGradient(
                        colors: [Color.white.opacity(scheme == .dark ? 0.5 : 1), Color.white.opacity(0)],
                        startPoint: Self.sheenStart,
                        endPoint: Self.sheenEnd)
                    .blendMode(.softLight)
                    LinearGradient(
                        colors: [Color.black.opacity(0), Color.black.opacity(scheme == .dark ? 0.5 : 0.05)],
                        startPoint: .top,
                        endPoint: .bottom)
                    if let grain = NoiseTile.shared(pixelsPerPoint: Int(displayScale.rounded())) {
                        // Web **masks a flat black fill** with the noise rather than painting the
                        // noise directly (`index.css:276-281`), and that is load-bearing here, not
                        // just a faithful transcription. An alpha-only `CGImage` handed to `Image`
                        // is treated as a *template* and tinted with the foreground style — white
                        // on a dark panel. Painted that way the film lightened the surface by 11
                        // levels instead of darkening it by 2, and carried nine times the speckle.
                        // A mask cannot pick up a tint, so the fill's colour is the only thing that
                        // decides which way the grain goes.
                        Rectangle()
                            .fill(Color.black.opacity(scheme == .dark ? 0.1 : 0.03))
                            .mask {
                                Image(decorative: grain, scale: displayScale)
                                    .resizable(resizingMode: .tile)
                                    // One sample per *device pixel*, so nothing is resampled: web's
                                    // grain is an SVG mask the browser re-rasterises at the display's
                                    // pixel density. Generating at 1pt and drawing with `.none` gave
                                    // hard 1pt squares — 9 device pixels of one flat value on a 3x
                                    // screen — and smoothing that upscale traded the blocks for
                                    // visible seams where the tiles meet.
                                    .interpolation(.none)
                            }
                    }
                }
            }
        }
        .clipShape(shape)
        .overlay {
            if bordered {
                let metrics = TranscriptMetrics(scale: TranscriptMetrics.scale(for: typeSize), theme: theme)
                shape.strokeBorder(theme.primary(.t10), lineWidth: metrics.hairline)
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    /// Light rgba(80,110,176,.2), dark rgba(174,186,255,.2) — the web's wash colours.
    static func washColor(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 174 / 255, green: 186 / 255, blue: 1).opacity(0.2)
            : Color(red: 80 / 255, green: 110 / 255, blue: 176 / 255).opacity(0.2)
    }

    /// CSS `158.26deg`: 0° points up and angles run clockwise, so the gradient line runs from upper
    /// left to lower right. Fixed points, not corners, so the angle does not follow the aspect ratio.
    static var sheenStart: UnitPoint { SurfaceGeometry.sheenStart }
    static var sheenEnd: UnitPoint { SurfaceGeometry.sheenEnd }
}

enum SurfaceGeometry {
    static let sheenAngle = 158.26 * Double.pi / 180
    static let sheenStart = UnitPoint(x: 0.5 - 0.5 * sin(sheenAngle), y: 0.5 + 0.5 * cos(sheenAngle))
    static let sheenEnd = UnitPoint(x: 0.5 + 0.5 * sin(sheenAngle), y: 0.5 - 0.5 * cos(sheenAngle))
}

public extension TouchpointSurface where S == Rectangle {
    /// A full-bleed surface: the embedded transcript, a sheet's content.
    init() { self.init(in: Rectangle()) }
}

/// A tile of grain, generated rather than shipped so nothing binary is added to the bundle. One
/// 160**pt** alpha-only tile per display scale, built once each, tiled by the surface. Seeded, so
/// renders are reproducible.
///
/// The noise is a **fractal sum**, matching web's
/// `feTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3'` (`index.css:277`): three
/// octaves, each double the frequency and half the amplitude of the last. That matters more than it
/// sounds. This was previously one uniform random byte per pixel, which has no correlation between
/// neighbours at all — maximum contrast at every edge — and on a near-black panel that reads as
/// hard static rather than film grain. A fractal sum puts most of its energy in the coarsest octave,
/// so neighbours stay close and the film is soft, which is what web paints.
///
/// The lattice is measured in **points** and sampled at **device pixels**, which is what a browser
/// does with an SVG mask: the pattern is the same physical size on every screen, and the bitmap
/// needs no resampling to draw.
enum NoiseTile {
    /// The tile's size in points — web's 160px tile.
    static let side = 160
    /// Web's `baseFrequency`, in cycles per point. 0.85 × 160 = 136 lattice cells across the tile,
    /// a whole number, so the lattice wraps at the tile edge — web's `stitchTiles='stitch'`.
    static let baseFrequency = 0.85
    static let octaves = 3
    static let cells = Int((baseFrequency * Double(side)).rounded())

    /// The tile for a display scale, built on first use and kept. Scales are a tiny fixed set (1, 2,
    /// 3), and a 3x tile is 480×480 bytes — a quarter of a megabyte, paid once.
    static func shared(pixelsPerPoint: Int) -> CGImage? {
        let ppp = max(1, pixelsPerPoint)
        return cache.withLock { store in
            if let tile = store[ppp] { return tile }
            let tile = image(seed: 0x7A3C_9D1F, pixelsPerPoint: ppp)
            store[ppp] = tile
            return tile
        }
    }
    private static let cache = OSAllocatedUnfairLock<[Int: CGImage?]>(initialState: [:])

    /// Alpha-only noise: the surface sets the strength per scheme, which is what lets one tile
    /// serve both appearances.
    static func image(seed: UInt32, pixelsPerPoint: Int = 1) -> CGImage? {
        let samples = side * max(1, pixelsPerPoint)
        // `CGImageAlphaInfo.alphaOnly` with no colour space is a documented bitmap format: one byte
        // per pixel, alpha straight from the buffer, no mask inversion to reason about.
        guard let ctx = CGContext(data: nil, width: samples, height: samples, bitsPerComponent: 8,
                                  bytesPerRow: samples, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
              let data = ctx.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * samples)
        var layers: [(cells: Int, amplitude: Double)] = []
        var cellCount = cells
        var amplitude = 1.0
        var total = 0.0
        for _ in 0..<octaves {
            layers.append((cellCount, amplitude))
            total += amplitude
            cellCount *= 2            // the finer octaves land sub-pixel, as feTurbulence's do
            amplitude /= 2
        }
        for y in 0..<samples {
            for x in 0..<samples {
                var sum = 0.0
                for layer in layers {
                    sum += layer.amplitude * value(x: x, y: y, samples: samples, cells: layer.cells, seed: seed)
                }
                bytes[y * ctx.bytesPerRow + x] = UInt8(max(0, min(255, (sum / total * 255).rounded())))
            }
        }
        return ctx.makeImage()
    }

    /// Smoothly interpolated value noise at one octave.
    private static func value(x: Int, y: Int, samples: Int, cells: Int, seed: UInt32) -> Double {
        let fx = Double(x) * Double(cells) / Double(samples)
        let fy = Double(y) * Double(cells) / Double(samples)
        let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
        let tx = smooth(fx - Double(x0)), ty = smooth(fy - Double(y0))
        let v00 = corner(x0, y0, cells: cells, seed: seed)
        let v10 = corner(x0 + 1, y0, cells: cells, seed: seed)
        let v01 = corner(x0, y0 + 1, cells: cells, seed: seed)
        let v11 = corner(x0 + 1, y0 + 1, cells: cells, seed: seed)
        return (v00 * (1 - tx) + v10 * tx) * (1 - ty) + (v01 * (1 - tx) + v11 * tx) * ty
    }

    /// Smoothstep, so octaves have no visible lattice seams.
    private static func smooth(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// The value at a lattice corner, hashed from its **wrapped** coordinates: no grid is stored,
    /// and the tile repeats seamlessly by construction. SplitMix64 finalisation — small, and plenty
    /// for grain.
    private static func corner(_ x: Int, _ y: Int, cells: Int, seed: UInt32) -> Double {
        var h = UInt64(x % cells) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(y % cells) &* 0xBF58_476D_1CE4_E5B9
        h ^= UInt64(seed)
        h ^= h >> 30; h = h &* 0xBF58_476D_1CE4_E5B9
        h ^= h >> 27; h = h &* 0x94D0_49BB_1331_11EB
        h ^= h >> 31
        return Double(h >> 11) / Double(1 << 53)
    }
}
