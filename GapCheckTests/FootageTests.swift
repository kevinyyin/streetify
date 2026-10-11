import XCTest
@testable import GapCheck

/// Phase 4: runs every Footage/<clip>.mov|mp4 that has a <clip>.passes.txt (one pass time in seconds per line)
/// and prints seconds of warning per car (under 10 is a MISS) and false-alarm seconds. Skips without footage.
final class FootageTests: XCTestCase {
    func testScoreWarningAndFalseAlarm() {
        let timeline = stride(from: 0.0, through: 30.0, by: 0.1).map { t -> (t: Double, state: DirectionState) in
            (t, t < 5 || t >= 18 ? .clear : .approaching(.seconds(4)))
        }
        let score = scoreFootage(timeline, passSeconds: [17])
        XCTAssertEqual(score.warningSeconds.count, 1)
        XCTAssertEqual(score.warningSeconds[0], 17 - 4.9, accuracy: 0.01)
        XCTAssertEqual(score.falseAlarmSeconds, 0.9, accuracy: 0.05)
    }

    /// Before the first moving car the state is "no road seen", not Clear; the warning still starts with the car.
    func testWarningStartsAfterNoRoadSeen() {
        let timeline = stride(from: 0.0, through: 30.0, by: 0.1).map { t -> (t: Double, state: DirectionState) in
            (t, t < 21 ? .unknown(.noRoadSeen) : t < 26 ? .approaching(.seconds(4)) : .clear)
        }
        XCTAssertEqual(scoreFootage(timeline, passSeconds: [25]).warningSeconds[0], 25 - 20.9, accuracy: 0.01)
    }

    func testFootageReport() throws {
        let footage = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Footage")
        let clips = ((try? FileManager.default.contentsOfDirectory(at: footage, includingPropertiesForKeys: nil)) ?? [])
            .filter { ["mov", "mp4"].contains($0.pathExtension.lowercased()) && FileManager.default.fileExists(atPath: passesURL($0).path) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !clips.isEmpty else { throw XCTSkip("no Footage/<clip>.mov with a <clip>.passes.txt beside it") }
        for clip in clips {
            let passes = try String(contentsOf: passesURL(clip), encoding: .utf8)
                .split(whereSeparator: \.isNewline).compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let score = scoreFootage(try replay(clip), passSeconds: passes)
            for (i, w) in score.warningSeconds.enumerated() {
                print("FOOTAGE \(clip.lastPathComponent) car \(i + 1): \(String(format: "%.1f", w)) s warning\(w < 10 ? "  MISS" : "")")
            }
            print("FOOTAGE \(clip.lastPathComponent) false alarm: \(String(format: "%.1f", score.falseAlarmSeconds)) s")
        }
    }

    private func passesURL(_ clip: URL) -> URL {
        clip.deletingPathExtension().appendingPathExtension("passes.txt")
    }

    private func replay(_ clip: URL) throws -> [(t: Double, state: DirectionState)] {
        let source = VideoFileSource(url: clip, realTime: false)
        let pipeline = Pipeline(side: .right, source: source, detector: try Detector())
        let lock = NSLock()
        var timeline: [(t: Double, state: DirectionState)] = []
        pipeline.onUpdate = { update in
            guard let t = update.frame?.timestampSeconds else { return }
            lock.withLock { timeline.append((t, update.state)) }
        }
        let finished = expectation(description: "\(clip.lastPathComponent) finished")
        source.onFinished = { finished.fulfill() }
        pipeline.start()
        wait(for: [finished], timeout: 3600)
        return lock.withLock { timeline }
    }
}

struct FootageScore {
    /// Per pass: seconds from the last Clear or "no road seen" before it (or the clip start) to the pass.
    let warningSeconds: [Double]
    /// Time spent Approaching with no pass in the following approach window.
    let falseAlarmSeconds: Double
}

func scoreFootage(_ timeline: [(t: Double, state: DirectionState)], passSeconds: [Double]) -> FootageScore {
    let start = timeline.first?.t ?? 0
    let warnings = passSeconds.map { pass in
        // Both say "nothing here": Clear, and Unknown "no road seen" until the first moving car.
        pass - (timeline.last(where: { $0.t < pass && ($0.state == .clear || $0.state == .unknown(.noRoadSeen)) })?.t ?? start)
    }
    var falseAlarm = 0.0
    for (a, b) in zip(timeline, timeline.dropFirst()) {
        guard case .approaching = a.state else { continue }
        if !passSeconds.contains(where: { $0 >= a.t && $0 <= a.t + Config.approachWindowSeconds }) { falseAlarm += b.t - a.t }
    }
    return FootageScore(warningSeconds: warnings, falseAlarmSeconds: falseAlarm)
}
