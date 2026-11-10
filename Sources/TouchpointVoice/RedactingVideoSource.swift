#if canImport(AmazonChimeSDK)
import AmazonChimeSDK
import CoreVideo
import Foundation

/// A Chime `VideoSource` that sits between `InAppScreenCaptureSource` and Chime's content share, so
/// the frames the agent receives can be masked.
///
/// It is itself a `VideoSink` of the in-app capture source: each captured frame is masked in place
/// — host-marked views blacked out, or the whole frame blanked when a "secure" view is visible or
/// the format is unrecognised — then forwarded to Chime's own sinks. With nothing marked the frame
/// is forwarded untouched, so the stream is identical to today.
///
/// **Deviation from the design note's "copy/mask":** the frame is masked *in place*. This source is
/// the sole sink of the in-app capture, so there is no other reader to preserve, and mutating the
/// single buffer guarantees no un-redacted copy of a frame ever exists in memory — a stronger
/// guarantee than masking a copy and leaving the original around to be collected later.
final class RedactingVideoSource: NSObject, VideoSource, VideoSink {
    var videoContentHint: VideoContentHint

    private let store: RedactionSnapshotStore
    private let lock = NSLock()
    private var sinks: [ObjectIdentifier: VideoSink] = [:]

    init(contentHint: VideoContentHint, store: RedactionSnapshotStore) {
        self.videoContentHint = contentHint
        self.store = store
    }

    func addVideoSink(sink: VideoSink) {
        lock.withLock { sinks[ObjectIdentifier(sink)] = sink }
    }

    func removeVideoSink(sink: VideoSink) {
        _ = lock.withLock { sinks.removeValue(forKey: ObjectIdentifier(sink)) }
    }

    func onVideoFrameReceived(frame: VideoFrame) {
        let redaction = store.current
        if !redaction.isEmpty {
            guard let pixelBuffer = (frame.buffer as? VideoFramePixelBuffer)?.pixelBuffer else {
                // Fail closed: a frame we cannot address as a pixel buffer cannot be masked, so it
                // is dropped rather than sent through un-redacted.
                return
            }
            ScreenShareMask.apply(redaction, to: pixelBuffer)
        }
        let targets = lock.withLock { Array(sinks.values) }
        for sink in targets { sink.onVideoFrameReceived(frame: frame) }
    }
}
#endif
