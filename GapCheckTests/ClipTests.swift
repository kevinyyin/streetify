import AVFoundation
import XCTest
@testable import GapCheck

/// Runs the committed clip (a few seconds, a car approaching) through Detect. Skips until the clip exists.
final class ClipTests: XCTestCase {
    private func clipURL() throws -> URL {
        guard let url = Bundle(for: ClipTests.self).url(forResource: "clip", withExtension: "mov") else {
            throw XCTSkip("GapCheckTests/clip.mov not supplied yet")
        }
        return url
    }

    /// Plays the whole file through `onFrame` as fast as possible.
    private func play(_ url: URL, _ onFrame: @escaping (Frame) -> Void) {
        let source = VideoFileSource(url: url, realTime: false)
        source.onFrame = onFrame
        let finished = expectation(description: "clip finished")
        source.onFinished = { finished.fulfill() }
        source.start()
        wait(for: [finished], timeout: 300)
    }

    /// A flat gray video, written on the fly: replay must run at Config.processFps and Decide must say covered.
    func testBlankVideoReplaysAtProcessFpsAndReadsCovered() throws {
        let source = VideoFileSource(url: try writeFlatVideo(seconds: 1, fps: 30), realTime: false)
        let pipeline = Pipeline(side: .left, source: source, detector: try Detector())
        let lock = NSLock()
        var updates: [PipelineUpdate] = []
        pipeline.onUpdate = { update in lock.withLock { updates.append(update) } }
        let finished = expectation(description: "replay finished")
        source.onFinished = { finished.fulfill() }
        pipeline.start()
        wait(for: [finished], timeout: 60)
        let got = lock.withLock { updates }
        XCTAssertTrue((9...11).contains(got.count), "\(got.count) frames")
        XCTAssertEqual(got.last?.state, .unknown(.covered))
    }

    private func writeFlatVideo(seconds: Double, fps: Int32) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let buffer = makeLumaBuffer(width: 640, height: 360) { _, _ in 128 }
        for i in 0..<Int(seconds * Double(fps)) {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.01) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: fps))
        }
        input.markAsFinished()
        let written = expectation(description: "video written")
        writer.finishWriting { written.fulfill() }
        wait(for: [written], timeout: 30)
        return url
    }

    func testClipDetectsACar() throws {
        let url = try clipURL()
        let source = VideoFileSource(url: url, realTime: false)
        let pipeline = Pipeline(side: .right, source: source, detector: try Detector())
        let lock = NSLock()
        var sawTrack = false
        pipeline.onUpdate = { update in lock.withLock { sawTrack = sawTrack || !update.tracks.isEmpty } }
        let finished = expectation(description: "clip finished")
        source.onFinished = { finished.fulfill() }
        pipeline.start()
        wait(for: [finished], timeout: 300)
        XCTAssertTrue(lock.withLock { sawTrack })
    }

    /// Pins Vision's regionOfInterest coordinate space: a car seen by both requests must land in the same place.
    func testTileBoxesAgreeWithWholeFrame() throws {
        let detector = try Detector()
        let lock = NSLock()
        var bestIoUs: [Double] = []
        play(try clipURL()) { frame in
            guard let found = try? detector.detectSeparately(frame) else { return }
            for t in found.tile {
                if let best = found.whole.map({ iou($0.box, t.box) }).max(), best > 0 { lock.withLock { bestIoUs.append(best) } }
            }
        }
        let ious = lock.withLock { bestIoUs.sorted() }
        XCTAssertFalse(ious.isEmpty, "no car seen by both the whole frame and the tile")
        XCTAssertGreaterThanOrEqual(ious.isEmpty ? 0 : ious[ious.count / 2], 0.5)
    }
}
