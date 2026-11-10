import CoreGraphics
import CoreVideo
import Foundation
import Testing
@testable import TouchpointVoice

// MARK: - Screen-share masking maths
//
// The mask helper is platform-neutral so these run under `swift test` on macOS, where neither Chime
// nor UIKit compile. They cover the two halves of the hook: scaling a points rect to a frame's
// pixels, and blacking that rect out of a real CVPixelBuffer in each format ReplayKit delivers,
// plus the fail-closed paths (secure mark, unknown format) and the registry's weak-reference drop.

@Suite("Screen share: mask maths")
struct ScreenShareMaskTests {

    @Test("A1: a points rect scales to the frame's pixels")
    func scaling() {
        // 100×200 pt screen, 200×400 px frame → 2× on both axes.
        let rect = ScreenShareMask.pixelRect(for: CGRect(x: 10, y: 20, width: 30, height: 40),
                                             screenSize: CGSize(width: 100, height: 200),
                                             pixelWidth: 200, pixelHeight: 400, padding: 0)
        #expect(rect == PixelRect(x: 20, y: 40, width: 60, height: 80))
    }

    @Test("A2: an out-of-bounds rect clamps to the frame; a fully off-screen one is empty")
    func clamping() {
        let clamped = ScreenShareMask.pixelRect(for: CGRect(x: -50, y: -50, width: 400, height: 400),
                                                screenSize: CGSize(width: 100, height: 100),
                                                pixelWidth: 100, pixelHeight: 100, padding: 0)
        #expect(clamped == PixelRect(x: 0, y: 0, width: 100, height: 100))

        let offScreen = ScreenShareMask.pixelRect(for: CGRect(x: 200, y: 200, width: 10, height: 10),
                                                  screenSize: CGSize(width: 100, height: 100),
                                                  pixelWidth: 100, pixelHeight: 100, padding: 0)
        #expect(offScreen.isEmpty)
    }

    @Test("A3: a 420f frame is blacked inside the rect (Y=0, CbCr=128) and untouched outside")
    func fill420f() {
        let buffer = makePixelBuffer(width: 64, height: 64, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        fillEveryByte(buffer, with: 200)
        ScreenShareMask.apply(ScreenShareRedaction(secure: false,
                                                   rects: [CGRect(x: 16, y: 16, width: 16, height: 16)],
                                                   screenSize: CGSize(width: 64, height: 64)),
                              to: buffer)
        #expect(lumaByte(buffer, x: 24, y: 24) == 0)     // inside
        #expect(chromaByte(buffer, x: 12, y: 12) == 128) // inside (chroma is half-res: luma 24 → 12)
        #expect(lumaByte(buffer, x: 2, y: 2) == 200)     // outside
        #expect(lumaByte(buffer, x: 60, y: 60) == 200)   // outside
    }

    @Test("A4: a video-range 420v frame uses Y=16 for black")
    func fill420v() {
        let buffer = makePixelBuffer(width: 32, height: 32, format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
        fillEveryByte(buffer, with: 200)
        ScreenShareMask.apply(ScreenShareRedaction(secure: false,
                                                   rects: [CGRect(x: 8, y: 8, width: 8, height: 8)],
                                                   screenSize: CGSize(width: 32, height: 32)),
                              to: buffer)
        #expect(lumaByte(buffer, x: 11, y: 11) == 16)
    }

    @Test("A5: a BGRA frame is blacked opaque inside the rect and untouched outside")
    func fillBGRA() {
        let buffer = makePixelBuffer(width: 64, height: 64, format: kCVPixelFormatType_32BGRA)
        fillEveryByte(buffer, with: 200)
        ScreenShareMask.apply(ScreenShareRedaction(secure: false,
                                                   rects: [CGRect(x: 16, y: 16, width: 16, height: 16)],
                                                   screenSize: CGSize(width: 64, height: 64)),
                              to: buffer)
        #expect(bgraPixel(buffer, x: 24, y: 24) == [0, 0, 0, 255])
        #expect(bgraPixel(buffer, x: 2, y: 2) == [200, 200, 200, 200])
    }

    @Test("A6: a secure mark blanks the whole frame")
    func secureBlanksWhole() {
        let buffer = makePixelBuffer(width: 32, height: 32, format: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        fillEveryByte(buffer, with: 200)
        ScreenShareMask.apply(ScreenShareRedaction(secure: true, rects: [], screenSize: .zero), to: buffer)
        #expect(lumaByte(buffer, x: 0, y: 0) == 0)
        #expect(lumaByte(buffer, x: 31, y: 31) == 0)
        #expect(chromaByte(buffer, x: 0, y: 0) == 128)
    }

    @Test("A7: an unknown pixel format fails closed — the whole frame is destroyed")
    func unknownFormatFailsClosed() {
        // 32ARGB is a valid buffer the mask does not special-case → fail closed (zero everything).
        let buffer = makePixelBuffer(width: 16, height: 16, format: kCVPixelFormatType_32ARGB)
        fillEveryByte(buffer, with: 200)
        ScreenShareMask.apply(ScreenShareRedaction(secure: false,
                                                   rects: [CGRect(x: 2, y: 2, width: 4, height: 4)],
                                                   screenSize: CGSize(width: 16, height: 16)),
                              to: buffer)
        #expect(everyByteIsZero(buffer))
    }

    @Test("A8: no marks leave the frame untouched")
    func emptyIsNoop() {
        let buffer = makePixelBuffer(width: 16, height: 16, format: kCVPixelFormatType_32BGRA)
        fillEveryByte(buffer, with: 123)
        ScreenShareMask.apply(.none, to: buffer)
        #expect(bgraPixel(buffer, x: 8, y: 8) == [123, 123, 123, 123])
    }

    @Test("A9: the registry's weak box drops a released view")
    func weakBoxDropsReleasedView() {
        var object: NSObject? = NSObject()
        let box = WeakViewBox(object!)
        #expect(box.isAlive)
        let boxes = [box]
        object = nil
        #expect(!box.isAlive)
        #expect(boxes.filter { $0.isAlive }.isEmpty)   // compaction forgets it
    }
}

// MARK: - CVPixelBuffer test helpers (force-unwrap is fine: Tests/ is excluded from lint.sh)

private func makePixelBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
    let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, format, attrs, &buffer)
    precondition(status == kCVReturnSuccess, "could not create test buffer")
    return buffer!
}

private func fillEveryByte(_ buffer: CVPixelBuffer, with value: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    if CVPixelBufferIsPlanar(buffer) {
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!
            memset(base, Int32(value), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
    } else {
        let base = CVPixelBufferGetBaseAddress(buffer)!
        memset(base, Int32(value), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
    }
}

private func lumaByte(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
    return base[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) + x]
}

private func chromaByte(_ buffer: CVPixelBuffer, x: Int, y: Int) -> UInt8 {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
    return base[y * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) + x * 2]   // Cb of the pair
}

private func bgraPixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = y * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    return [base[offset], base[offset + 1], base[offset + 2], base[offset + 3]]
}

private func everyByteIsZero(_ buffer: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    func planeIsZero(_ base: UnsafeRawPointer, _ length: Int) -> Bool {
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        for index in 0..<length where bytes[index] != 0 { return false }
        return true
    }
    if CVPixelBufferIsPlanar(buffer) {
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return false }
            if !planeIsZero(base, CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane)) {
                return false
            }
        }
        return true
    }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
    return planeIsZero(base, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
}
