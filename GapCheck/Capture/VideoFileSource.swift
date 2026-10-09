import AVFoundation
import os

/// Replays a video file as frames at the file's own timestamps. Assumes the phone was level.
final class VideoFileSource: FrameSource {
    var onFrame: ((Frame) -> Void)?
    var onFinished: (() -> Void)?

    private let url: URL
    private let realTime: Bool
    private let queue = DispatchQueue(label: "replay")
    private let cancelled = OSAllocatedUnfairLock(initialState: false)

    /// `realTime` paces frames like a camera; tests pass false to run as fast as possible.
    init(url: URL, realTime: Bool) {
        self.url = url
        self.realTime = realTime
    }

    func start() { queue.async { self.run() } }
    func stop() { cancelled.withLock { $0 = true } }

    private func run() {
        defer { onFinished?() }
        let asset = AVURLAsset(url: url)
        var loaded: (AVAssetTrack, CGAffineTransform)?
        let done = DispatchSemaphore(value: 0)
        Task {
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let transform = try? await track.load(.preferredTransform) {
                loaded = (track, transform)
            }
            done.signal()
        }
        done.wait()
        guard let (track, transform) = loaded, let reader = try? AVAssetReader(asset: asset) else { return }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { return }

        let orientation = videoOrientation(transform)
        let wallStart = CACurrentMediaTime()
        var firstSeconds: Double?
        var lastSeconds = -Double.infinity
        while !cancelled.withLock({ $0 }), let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard isDue(t, after: lastSeconds) else { continue }
            lastSeconds = t
            if realTime {
                let first = firstSeconds ?? t
                firstSeconds = first
                let waitSeconds = (t - first) - (CACurrentMediaTime() - wallStart)
                if waitSeconds > 0 { Thread.sleep(forTimeInterval: waitSeconds) }
            }
            onFrame?(Frame(pixelBuffer: buffer, timestampSeconds: t, orientation: orientation, isLevel: true, tiltErrorDegrees: 0))
        }
    }
}

/// EXIF orientation that displays a video track upright, from its preferredTransform.
func videoOrientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
    switch Int((atan2(t.b, t.a) * 180 / .pi).rounded()) {
    case 90: return .right
    case -90: return .left
    case 180, -180: return .down
    default: return .up
    }
}
