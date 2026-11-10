import CoreGraphics
import CoreVideo
import Foundation

// MARK: - Screen-share redaction
//
// ReplayKit's in-app capture sends this app's whole window to the agent. These types give a host a
// masking hook and an iOS `FLAG_SECURE` equivalent: host-marked views are blacked out of every
// captured frame, and a host-marked "secure" view blanks the whole frame while it is on screen.
//
// Everything here is platform-neutral (CoreVideo + CoreGraphics only — no UIKit, no Chime) so the
// mask maths runs under `swift test` on macOS. The main-actor view bookkeeping lives in
// `ScreenShareRedactionRegistry.swift` (UIKit) and the Chime-facing `VideoSource` wrapper in
// `RedactingVideoSource.swift` (Chime); both feed / read the snapshot below.

/// A rectangle, in integer pixel coordinates, of a captured frame. Origin top-left, matching both
/// `CVPixelBuffer` memory order and UIKit/SwiftUI screen coordinates.
struct PixelRect: Equatable, Sendable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int

    static let zero = PixelRect(x: 0, y: 0, width: 0, height: 0)
    var isEmpty: Bool { width <= 0 || height <= 0 }
}

/// What to blank out of the next captured frame. Computed on the main actor from host-marked views
/// (see the registry), snapshotted here, and read on Chime's capture queue.
///
/// `rects` are in screen points (top-left origin), the same space UIKit's `convert(_:to: window)`
/// and SwiftUI's `.global` frame report; they are scaled to the frame's pixels against `screenSize`.
struct ScreenShareRedaction: Equatable, Sendable {
    /// Blank the whole frame — the iOS `FLAG_SECURE` equivalent.
    var secure: Bool
    /// Rectangles to black out, in screen points.
    var rects: [CGRect]
    /// The screen/window size in points the `rects` were measured against.
    var screenSize: CGSize

    static let none = ScreenShareRedaction(secure: false, rects: [], screenSize: .zero)

    /// Nothing marked: the wrapper forwards the frame untouched, so output is identical to today.
    var isEmpty: Bool { !secure && rects.isEmpty }
}

/// Thread-safe holder for the latest redaction snapshot. The registry (main actor) writes; the
/// capture queue reads. A single shared instance couples the public marking API to whichever call
/// happens to be sharing — screen marking is process-wide, as ReplayKit's capture is.
final class RedactionSnapshotStore: @unchecked Sendable {
    static let shared = RedactionSnapshotStore()

    private let lock = NSLock()
    private var value = ScreenShareRedaction.none

    var current: ScreenShareRedaction { lock.withLock { value } }
    func update(_ redaction: ScreenShareRedaction) { lock.withLock { value = redaction } }
    func clear() { update(.none) }
}

/// A weak box so a view the host releases is forgotten — no retain cycle, no leaked frame rect.
/// Platform-neutral on purpose: the "drops deallocated views" behaviour is then unit-testable on
/// macOS, where `UIView` does not exist.
final class WeakViewBox {
    weak var object: AnyObject?
    init(_ object: AnyObject) { self.object = object }
    var isAlive: Bool { object != nil }
}

/// Pure masking maths: scale a points rect to a frame's pixels, and fill rectangles with opaque
/// black. No state, no platform UI — unit-tested directly.
enum ScreenShareMask {
    /// The pixel formats ReplayKit is known to deliver and that we can black out precisely. Anything
    /// else is treated as unknown and fails closed (the whole frame is destroyed).
    static func isKnown(_ format: OSType) -> Bool {
        format == kCVPixelFormatType_32BGRA
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    /// Scale a points rectangle into a frame of `pixelWidth`×`pixelHeight`, clamped to the frame.
    ///
    /// `padding` grows the rect by a few pixels and the result is snapped to even bounds: it masks
    /// slightly more than the view to swallow a stale rect for one frame while a view is in motion,
    /// and even bounds keep the 4:2:0 chroma plane aligned so no half-covered edge survives.
    static func pixelRect(for rect: CGRect,
                          screenSize: CGSize,
                          pixelWidth: Int,
                          pixelHeight: Int,
                          padding: Int = 2) -> PixelRect {
        guard screenSize.width > 0, screenSize.height > 0, pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let scaleX = Double(pixelWidth) / Double(screenSize.width)
        let scaleY = Double(pixelHeight) / Double(screenSize.height)

        var minX = Int((Double(rect.minX) * scaleX).rounded(.down)) - padding
        var minY = Int((Double(rect.minY) * scaleY).rounded(.down)) - padding
        var maxX = Int((Double(rect.maxX) * scaleX).rounded(.up)) + padding
        var maxY = Int((Double(rect.maxY) * scaleY).rounded(.up)) + padding

        minX = max(0, minX); minY = max(0, minY)
        maxX = min(pixelWidth, maxX); maxY = min(pixelHeight, maxY)
        // Snap to even: start down, end up.
        minX -= minX % 2; minY -= minY % 2
        if maxX % 2 != 0 { maxX = min(pixelWidth, maxX + 1) }
        if maxY % 2 != 0 { maxY = min(pixelHeight, maxY + 1) }

        guard maxX > minX, maxY > minY else { return .zero }
        return PixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Apply a redaction to a captured pixel buffer **in place**. Masking in place rather than into
    /// a copy is deliberate (see `RedactingVideoSource`): it leaves no un-redacted copy in memory.
    ///
    /// Fails closed — an unknown pixel format, an unset `screenSize`, or a `secure` mark all blank
    /// the whole frame rather than risk leaking content.
    static func apply(_ redaction: ScreenShareRedaction, to pixelBuffer: CVPixelBuffer) {
        guard !redaction.isEmpty else { return }
        let pixelWidth = CVPixelBufferGetWidth(pixelBuffer)
        let pixelHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let known = isKnown(format)

        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let blankWhole = redaction.secure
            || !known
            || redaction.screenSize.width <= 0
            || redaction.screenSize.height <= 0

        if blankWhole {
            if known {
                fill(pixelBuffer, format: format, rects: [PixelRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight)])
            } else {
                zeroAll(pixelBuffer)
            }
            return
        }

        let rects = redaction.rects
            .map { pixelRect(for: $0, screenSize: redaction.screenSize, pixelWidth: pixelWidth, pixelHeight: pixelHeight) }
            .filter { !$0.isEmpty }
        guard !rects.isEmpty else { return }
        fill(pixelBuffer, format: format, rects: rects)
    }

    // MARK: - Per-format fills (buffer already locked)

    private static func fill(_ pixelBuffer: CVPixelBuffer, format: OSType, rects: [PixelRect]) {
        switch format {
        case kCVPixelFormatType_32BGRA:
            fillBGRA(pixelBuffer, rects: rects)
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            fillBiplanar(pixelBuffer, rects: rects, luma: 0)    // full range: black is Y = 0
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            fillBiplanar(pixelBuffer, rects: rects, luma: 16)   // video range: black is Y = 16
        default:
            zeroAll(pixelBuffer)
        }
    }

    private static func fillBGRA(_ pixelBuffer: CVPixelBuffer, rects: [PixelRect]) {
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for raw in rects {
            let rect = clamp(raw, width: width, height: height)
            guard !rect.isEmpty else { continue }
            for row in rect.y..<(rect.y + rect.height) {
                var offset = row * stride + rect.x * 4
                for _ in 0..<rect.width {
                    ptr[offset] = 0        // B
                    ptr[offset + 1] = 0    // G
                    ptr[offset + 2] = 0    // R
                    ptr[offset + 3] = 255  // A (opaque)
                    offset += 4
                }
            }
        }
    }

    private static func fillBiplanar(_ pixelBuffer: CVPixelBuffer, rects: [PixelRect], luma: UInt8) {
        // Plane 0 — luma (Y): one byte per pixel, set to the format's black level.
        if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
            let ptr = yBase.assumingMemoryBound(to: UInt8.self)
            for raw in rects {
                let rect = clamp(raw, width: width, height: height)
                guard !rect.isEmpty else { continue }
                for row in rect.y..<(rect.y + rect.height) {
                    memset(ptr + row * stride + rect.x, Int32(luma), rect.width)
                }
            }
        }
        // Plane 1 — chroma (CbCr): half resolution, two interleaved bytes per sample, both 128
        // (neutral). A 128 fill over the matching region turns the luma-black area fully black.
        if let cBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
            let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
            let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
            let ptr = cBase.assumingMemoryBound(to: UInt8.self)
            for raw in rects {
                let chroma = clamp(PixelRect(x: raw.x / 2,
                                             y: raw.y / 2,
                                             width: (raw.width + 1) / 2,
                                             height: (raw.height + 1) / 2),
                                   width: width, height: height)
                guard !chroma.isEmpty else { continue }
                for row in chroma.y..<(chroma.y + chroma.height) {
                    memset(ptr + row * stride + chroma.x * 2, 128, chroma.width * 2)
                }
            }
        }
    }

    /// Fail-closed fallback: destroy every byte of every plane. Not necessarily visual black for an
    /// unknown format, but it removes the content, which is the security requirement.
    private static func zeroAll(_ pixelBuffer: CVPixelBuffer) {
        if CVPixelBufferIsPlanar(pixelBuffer) {
            for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
                guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { continue }
                memset(base, 0, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane) * CVPixelBufferGetHeightOfPlane(pixelBuffer, plane))
            }
        } else if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(pixelBuffer) * CVPixelBufferGetHeight(pixelBuffer))
        }
    }

    private static func clamp(_ rect: PixelRect, width: Int, height: Int) -> PixelRect {
        let x = max(0, min(rect.x, width))
        let y = max(0, min(rect.y, height))
        let endX = max(0, min(rect.x + rect.width, width))
        let endY = max(0, min(rect.y + rect.height, height))
        return PixelRect(x: x, y: y, width: max(0, endX - x), height: max(0, endY - y))
    }
}
