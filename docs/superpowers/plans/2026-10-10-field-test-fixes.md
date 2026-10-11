# Field Test Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Judge cars only when the app's assumptions hold, which means the phone is still, aimed along the road and the right way round. Stop the false alarms that hid real warnings in the 2026-10-10 field test.

**Architecture:**
- Extend `Decider`'s ordered rules with new Unknown reasons (`facingUser`, `misaimed`, `moving`, `turnedAround`) and a new rule order.
- Add a `StillGate` beside `LevelGate`, and a crop classifier (CFV ConvNeXt) that only labels the debug screen for now.
- Pick the best installed voice.
- Merge first: face check and misaimed check come from `origin/feature-fixing`.

**Tech Stack:** Swift / SwiftUI, Vision + CoreML, CoreMotion, AVFoundation, XCTest. Model export: Python 3.12 `.venv` with coremltools 9.0, torch 2.7, timm.

**Spec:** `docs/superpowers/specs/2026-10-10-field-test-fixes-design.md`

## Global Constraints

**Safety invariants (root `CLAUDE.md`):**
1. Never say "safe", "go", "cross now" or similar.
2. Every failure ends in Unknown, never Clear.
3. Bias toward false alarms.
4. Each invariant has a unit test.

**Code conventions:**
- Every tunable constant goes in `GapCheck/Pipeline/Config.swift` with a one-line comment, units in names.
- All user-facing text goes in `GapCheck/Feedback/Strings.swift`. `BannedWordsTests.testNoSentenceOrLabelSaysGo` lists every `UnknownReason`, so add each new case there.
- Apple frameworks plus CoreML models only. Only `FrameSource` is a protocol.
- Timing uses frame timestamps, except the live watchdog.

**Workflow:**
- New files go on disk, then `xcodegen generate`. Never edit `GapCheck.xcodeproj`.
- Test command: `xcodebuild -scheme GapCheck -destination 'platform=iOS Simulator,name=iPhone 17' -collect-test-diagnostics never test`. For one test add `-only-testing:GapCheckTests/<Class>/<test>`.
- **Done per task:** builds, all tests pass. `TASKS.md` gets its item ticked (on-device behavior labelled "not verified on device"). `GapCheck/Pipeline/CLAUDE.md` or `GapCheck/Feedback/CLAUDE.md` is updated where a rule changed.
- Work on branch `field-test-fixes`, created from `main` before Task 1. One commit per task, ending `Co-Authored-By: Claude <noreply@anthropic.com>`. Do not push.

## Review Focus

1. **Out-of-order samples:** both cameras feed one `StillGate`, so frame times arrive interleaved and slightly out of order. The result must be the same as in order, with no crash. Test: Task 3 `testOutOfOrderSamplesFromTwoCameras`.
2. **No compass:** an uncalibrated or missing magnetometer gives a nil heading. That must never read "misaimed" from the compass. Test: Task 2 `testNoHeadingNeverMisaimedByCompass`.
3. **Replay:** footage played through `VideoFileSource` must never say "Hold still" or "Turn the phone around". Tests: Task 3 `testReplayFramesAreStill`, Task 6 `testReplayNeverTurnedAround`.
4. **Edge boxes:** a car box touching or crossing the picture edge must give a clamped crop. A region of interest outside the image makes Vision throw, which would turn the frame stale. Test: Task 8 `testCropIsClampedToThePicture`.
5. **Hand rotation:** a parked car sliding sideways because the hand turns must not count as turned-around evidence. Test: Task 6 `testDriftOfANonApproachingCarDoesNotCount`.

---

### Task 1: Face check — "Turn the screen away from you" (merge)

**Files:**
- Modify: `GapCheck/Pipeline/Decide.swift` (new `UnknownReason.facingUser`, `FrameObservation.faceBoxes`, rule after cars and before view blocked)
- Modify: `GapCheck/Pipeline/Detect.swift` (`Detector(detectsFaces:)`)
- Modify: `GapCheck/Pipeline/Pipeline.swift`
- Modify: `GapCheck/AppModel.swift` (`run(_:on:detectsFaces:)`; the front camera passes `true`)
- Modify: `GapCheck/Pipeline/Config.swift`, `GapCheck/Feedback/Strings.swift`
- Modify: `TASKS.md`, `GapCheck/Pipeline/CLAUDE.md`
- Test: `GapCheckTests/DecideTests.swift`, `GapCheckTests/FeedbackTests.swift`

**Interfaces:**
- Produces:
  - `UnknownReason.facingUser`
  - `FrameObservation.faceBoxes: [CGRect] = []`
  - `Detector(detectsFaces: Bool = false)`. Faces come back from `detect(_:)` as `Detection(label: Config.faceLabel)`.
  - `Config.faceLabel = "face"`
  - `Config.faceMinAreaFraction = 0.05`
  - The `DecideTests.obs` helper gains `faces: [CGRect] = []`.
- Source: `git show origin/feature-fixing:GapCheck/Pipeline/Detect.swift` (`faceRequest`) and `…/Decide.swift` (the `facingUser` rule). Take only the face parts, not `Mover`, people or bikes.

- [ ] **Step 0: Branch and TASKS section**
  - Run `git checkout -b field-test-fixes`.
  - Add a section `## Field test fixes (2026-10-10)` to `TASKS.md`, with one unticked item per task in this plan.

- [ ] **Step 1: Write the failing test.** Add it to `DecideTests`; the `obs` helper gains `faces:`.

```swift
func testFaceFillingTheFrontCameraIsFacingUser() {
    let d = seen()
    XCTAssertEqual(d.update(obs(1.5, faces: [CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.3)]), tracks: []),
                   .unknown(.facingUser))
    XCTAssertNil(d.roadSeenSeconds)
}
```

Add `.facingUser` to the `reasons` list in `BannedWordsTests.testNoSentenceOrLabelSaysGo`.

- [ ] **Step 2: Run it.** Expected: compile failure (`facingUser` undefined).

- [ ] **Step 3: Implement.**
  - **Rule:** the summed `faceBoxes` area is at least `Config.faceMinAreaFraction` → set `roadSeenSeconds = nil` and return `.unknown(.facingUser)`.
  - **Strings:** `sentence` returns "Turn the screen away from you" (no side prefix); `label` returns "Screen faces you".
  - **Detector:** `VNDetectFaceRectanglesRequest` performed in the same handler, front camera only.
  - **Pipeline:** passes `found.filter { $0.label == Config.faceLabel }.map(\.box)`. Faces never reach the tracker, which takes vehicle labels only.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`: add the facing-user rule. `TASKS.md`: tick the item ("not verified on device").
  - Commit: `feat: front camera seeing a face says "Turn the screen away from you" (from feature-fixing)`.

### Task 2: Misaimed — crossing traffic and compass lock (merge)

**Files:**
- Modify: `GapCheck/Capture/Level.swift` (`cameraHeadingDegrees`, `angleDifferenceDegrees`)
- Modify: `GapCheck/Capture/FrameSource.swift`, `GapCheck/Capture/LiveCameraSource.swift`
- Modify: `GapCheck/Pipeline/Track.swift` (`isCrossingView`)
- Modify: `GapCheck/Pipeline/Decide.swift`, `GapCheck/Pipeline/Pipeline.swift`, `GapCheck/Pipeline/Config.swift`
- Modify: `GapCheck/Feedback/Announce.swift` (`toneSettings`), `GapCheck/Feedback/Strings.swift`
- Modify: `GapCheck/AppModel.swift`
- Modify: `TASKS.md`, both folder `CLAUDE.md`s
- Test: `LevelTests.swift`, `TrackTests.swift`, `DecideTests.swift`, `FeedbackTests.swift`

**Interfaces:**
- Produces:
  - `Frame.headingDegrees: Double? = nil`
  - `FrameObservation.headingDegrees: Double? = nil`
  - `Decider.headingErrorDegrees: Double?` (private(set))
  - `PipelineUpdate.headingErrorDegrees: Double? = nil`
  - `UnknownReason.misaimed`
  - `Track.isCrossingView: Bool`
  - `toneSettings(isLevel:tiltErrorDegrees:headingErrorDegrees: Double? = nil) -> ToneSettings`
  - `cameraHeadingDegrees(gravity:field:) -> Double?`
  - `angleDifferenceDegrees(_:_:) -> Double`
  - The `DecideTests.obs` helper gains `heading: Double? = nil`.
- Config values, verbatim from `feature-fixing`:
  - `misaimSidewaysBoxWidthsPerSecond = 1.0`
  - `misaimMinSeconds = 0.5`
  - `misaimMaxGrowthFraction = 0.2`
  - `misaimMinHeightFraction = 0.05`
  - `misaimMaxHeightFraction = 0.3`
  - `misaimMemorySeconds = 10.0`
  - `headingToleranceDegrees = 25.0`
  - `headingMinHorizontalFraction = 0.5`
- Source: `origin/feature-fixing`: `Level.swift`, `LiveCameraSource.swift` (heading only when `magneticField.accuracy != .uncalibrated`), `Decide.swift` (`noteAim`, `misaimed` rule), `Announce.swift` (`toneSettings`), `AppModel.swift` (`.xMagneticNorthZVertical` when available).
- Leave out:
  - The `mover != .person` guard in `isCrossingView`; `main` tracks only vehicles.
  - The `isCarComing` parameter of `toneSettings`; it comes in Task 5.

- [ ] **Step 1: Write the failing tests.** Copy from `origin/feature-fixing`:
  - `LevelTests.testCameraHeadingFromGravityAndField`
  - `LevelTests.testAngleDifferenceWraps`
  - `TrackTests.testCrossingView` (drop its `person` lines)
  - `DecideTests.testHeadingDriftIsMisaimed`
  - `DecideTests.testCrossingTrafficIsMisaimed`
  - `FeedbackTests.testToneGuidesHeading`: the first three assertions of `testToneGuidesHeadingAndYieldsToCars`.

  Add:

```swift
func testNoHeadingNeverMisaimedByCompass() {
    let d = Decider()
    _ = d.update(obs(0, heading: 90), tracks: [movingTrack])
    XCTAssertNotEqual(d.update(obs(0.1, heading: nil), tracks: []), .unknown(.misaimed))
    XCTAssertNil(d.headingErrorDegrees)
}
```

Add `.misaimed` to `BannedWordsTests`.

- [ ] **Step 2: Run.** Expected: compile failures.

- [ ] **Step 3: Implement.**
  - **Rule order** after this task: … cars → facingUser → misaimed → view blocked → no road seen.
  - **`noteAim`** runs before the rules. Crossing evidence counts only from level frames, and it clears `roadSeenSeconds`.
  - **Strings:** `sentence` returns "Turn the phone back toward the road"; `label` returns "Turn to road".
  - **AppModel** passes `headingErrorDegrees` to `toneSettings` only while some side reads `.unknown(.misaimed)`.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`: add the misaimed rule and the heading lock. `Feedback/CLAUDE.md`: the tone also guides the heading while misaimed. `TASKS.md`: tick (compass "not verified on device").
  - Commit: `feat: misaimed — crossing traffic or compass off the street heading (from feature-fixing)`.

### Task 3: Walking gate — "Hold still"

**Files:**
- Modify: `GapCheck/Capture/Level.swift` (add `StillGate` beside `LevelGate`)
- Modify: `GapCheck/Capture/FrameSource.swift`, `GapCheck/Capture/LiveCameraSource.swift`
- Modify: `GapCheck/Pipeline/Decide.swift`, `GapCheck/Pipeline/Pipeline.swift`, `GapCheck/Pipeline/Config.swift`
- Modify: `GapCheck/Feedback/Strings.swift`, `GapCheck/AppModel.swift`, `GapCheck/DebugOverlay/ContentView.swift` (level line)
- Modify: `TASKS.md`, both folder `CLAUDE.md`s
- Test: `LevelTests.swift` (new `StillGateTests` class), `DecideTests.swift`

**Interfaces:**
- Consumes: `noteAim` (Task 2).
- Produces:
  - `final class StillGate { func update(accelerationG: Double, atSeconds t: Double) -> (isStill: Bool, rmsG: Double) }`
  - `Frame.isStill: Bool = true`
  - `Frame.motionG: Double = 0`
  - `FrameObservation.isStill: Bool = true`
  - `UnknownReason.moving`
  - `AppModel.motionG: Double` (published, for the readout)
- Config:
  - `stillWindowSeconds = 1.0` ("RMS window for telling walking from standing")
  - `movingAccelerationG = 0.06` ("Hand-held RMS above this is walking. Calibrate on device")
  - Rename `tiltCarMemorySeconds` → `carMemorySeconds` (value 1.0 unchanged).

- [ ] **Step 1: Write the failing tests.**

```swift
final class StillGateTests: XCTestCase {
    /// 20 samples/s (two cameras at 10 fps), `g(t)` = userAcceleration magnitude in g.
    private func feed(_ gate: StillGate, from: Double, to: Double, g: (Double) -> Double) -> Bool {
        var still = true
        for t in stride(from: from, through: to, by: 0.05) { still = gate.update(accelerationG: g(t), atSeconds: t).isStill }
        return still
    }
    func testSwayIsMoving() { XCTAssertFalse(feed(StillGate(), from: 0, to: 1, g: { 0.2 * abs(sin(2 * .pi * 2 * $0)) })) }
    func testTremorIsStill() { XCTAssertTrue(feed(StillGate(), from: 0, to: 3, g: { _ in 0.01 })) }
    func testStillOnlyAfterHistorySeconds() {
        let gate = StillGate()
        _ = feed(gate, from: 0, to: 1, g: { _ in 0.2 })
        XCTAssertFalse(feed(gate, from: 1.05, to: 2.4, g: { _ in 0.01 }))
        XCTAssertTrue(feed(gate, from: 2.45, to: 3.6, g: { _ in 0.01 }))
    }
    func testOutOfOrderSamplesFromTwoCameras() {
        let gate = StillGate()
        for i in 0..<40 { _ = gate.update(accelerationG: 0.2, atSeconds: Double(i) * 0.05 + (i % 2 == 0 ? 0.02 : 0)) }
        XCTAssertFalse(gate.update(accelerationG: 0.2, atSeconds: 1.99).isStill)
    }
}
```

`DecideTests` (the `obs` helper gains `still: Bool = true`):

```swift
func testMovingIsUnknown() { XCTAssertEqual(seen().update(obs(0, still: false), tracks: []), .unknown(.moving)) }
func testMovingKeepsACarJustSeen() {
    let d = Decider()
    let car = d.update(obs(1.5), tracks: [approachingTrack])
    XCTAssertEqual(d.update(obs(1.6, still: false), tracks: []), car)
    XCTAssertEqual(d.update(obs(2.6, still: false), tracks: []), .unknown(.moving))
}
func testMovingBeatsNotLevel() { XCTAssertEqual(Decider().update(obs(0, level: false, still: false), tracks: []), .unknown(.moving)) }
func testReplayFramesAreStill() { XCTAssertTrue(makeFrame(makeLumaBuffer(width: 8, height: 8) { _, _ in 128 }).isStill) }
```

Add `.moving` to `BannedWordsTests`.

- [ ] **Step 2: Run.** Expected: compile failures.

- [ ] **Step 3: Implement.**
  - **`StillGate`**, guarded by an `OSAllocatedUnfairLock` like `LevelGate`:
    - Keeps `(t, g²)` samples newer than `latest − Config.stillWindowSeconds`, where `latest` is the largest `t` seen. That makes out-of-order input harmless.
    - `rmsG` = the square root of the mean.
    - When `rmsG > Config.movingAccelerationG`, set `lastMovingSeconds = max(lastMovingSeconds, t)`.
    - `isStill` = `latest − lastMovingSeconds ≥ Config.historySeconds` (starts still).
  - **`LiveCameraSource`:**
    - Takes the shared `StillGate` (one instance in `AppModel`, like `level`).
    - Feeds the magnitude of `deviceMotion.userAcceleration` each frame.
    - With no motion data, `isStill = true`, because "not level" already makes the side Unknown.
  - **Decide:**
    - New rule 2, right after stale: `!o.isStill` → keep the last Approaching state if one was seen within `Config.carMemorySeconds`, else `.unknown(.moving)`.
    - Road evidence and crossing evidence in `noteAim` require `o.isLevel && o.isStill`.
  - **Strings:** `sentence` returns "Hold still" (no side prefix); `label` returns "Hold still".
  - **ContentView:** the level line shows `"Motion \(String(format: "%.2f", model.motionG)) g"`, the calibration readout.
  - The not-level rule keeps using the car memory, under its new name, until Task 5.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`: rule 2 "moving (curb only, owner 2026-10-10)". `Feedback/CLAUDE.md`: "Hold still" is spoken, with the problem vibration. `TASKS.md`: tick (threshold "not verified on device").
  - Commit: `feat: curb only — the phone moving says "Hold still" and judges no cars`.

### Task 4: Ignore cars driving away

**Files:**
- Modify: `GapCheck/Pipeline/Decide.swift`
- Modify: `TASKS.md`, `GapCheck/Pipeline/CLAUDE.md`
- Test: `GapCheckTests/DecideTests.swift`

**Interfaces:**
- Produces: `func countsAsComing(_ track: Track) -> Bool` in `Decide.swift`, which is `track.travel != .away`. Task 8 extends it.

- [ ] **Step 1: Write the failing test.**

```swift
/// Growing over the last 1.5 s (noise) but shrinking for sure over the 4 s window: a car that already passed.
func testCarDrivingAwayIsIgnored() {
    var leaving = trackWithDirection(heightAt: { 0.2 * (1 - 0.1 * $0) })
    leaving.heights = approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.12)
    XCTAssertEqual(leaving.travel, .away)
    if case .approaching = seen().update(obs(4), tracks: [leaving]) { XCTFail("a leaving car is not coming") }
}
```

`testNewTrackIsApproachingUnmeasured` already pins that too-new tracks still count.

- [ ] **Step 2: Run.** Expected: FAIL (the state is `.approaching`).

- [ ] **Step 3: Implement.** Rule 4 maps estimates only over `tracks.filter(countsAsComing)`. Leaving tracks still count for view blocked, as stationary-or-leaving ones do today.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`, rule 4: "tracks driving away (`.away`) don't count; approved by the owner 2026-10-10 (invariant 3)". `TASKS.md`: tick.
  - Commit: `feat: cars driving away no longer count as approaching`.

### Task 5: Cars while tilted

**Files:**
- Modify: `GapCheck/Pipeline/Decide.swift`, `GapCheck/Feedback/Announce.swift`, `GapCheck/AppModel.swift`
- Modify: `TASKS.md`, both folder `CLAUDE.md`s
- Test: `GapCheckTests/DecideTests.swift`, `GapCheckTests/FeedbackTests.swift`

**Interfaces:**
- Produces: `toneSettings(isLevel:tiltErrorDegrees:headingErrorDegrees:isCarComing: Bool = false)`.

- [ ] **Step 1: Write the failing tests.**
  - Replace `testNotLevelBeatsApproaching` with:

```swift
func testCarBeatsNotLevel() {
    guard case .approaching(.seconds) = Decider().update(obs(1.5, level: false), tracks: [approachingTrack]) else {
        return XCTFail("a car is reported while tilted")
    }
}
```

  - Delete `testTiltKeepsACarJustSeen`; Task 3's `testMovingKeepsACarJustSeen` now holds the memory.
  - Add `FeedbackTests.testToneYieldsToCars`: `XCTAssertFalse(toneSettings(isLevel: false, tiltErrorDegrees: 30, isCarComing: true).isOn)`.

- [ ] **Step 2: Run.** Expected: FAIL / compile failure.

- [ ] **Step 3: Implement.**
  - **Rule order:** stale → moving → quality → cars → not level (plain `.unknown(.notLevel)`, with no car memory) → facingUser → misaimed → view blocked → no road seen → clear.
  - **AppModel:** `updateTone` passes `isCarComing` = any pane's state is `.approaching`.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`: new rule order; replace the 2026-10-09 "tilt keeps the car as last said".
  - `Feedback/CLAUDE.md`: "while not level nothing is spoken but car news and 'camera stopped'; the tone stops while a car is reported".
  - `TASKS.md`: tick.
  - Commit: `feat: a tilted phone still reports cars; the tone yields to them`.

### Task 6: "Turn the phone around"

**Files:**
- Modify: `GapCheck/Capture/LiveCameraSource.swift` (front connection mirroring)
- Modify: `GapCheck/Pipeline/Track.swift`, `GapCheck/Pipeline/Decide.swift`, `GapCheck/Pipeline/Pipeline.swift`, `GapCheck/Pipeline/Config.swift`
- Modify: `GapCheck/AppModel.swift`, `GapCheck/Feedback/Strings.swift`
- Modify: `TASKS.md`, `GapCheck/Pipeline/CLAUDE.md`
- Test: `GapCheckTests/DecideTests.swift`, `GapCheckTests/TestHelpers.swift`

**Interfaces:**
- Produces:
  - `UnknownReason.turnedAround`
  - `Decider(checksTurnAround: Bool = false)`
  - `Pipeline(side:source:detector:checksTurnAround: Bool = false)`
  - `Track.driftFraction: Double?`: `last.box.midX − first.box.midX` over `directionBoxes` once they span `Config.historySeconds`, else nil.
  - `trackWithDirection(heightAt:xAt: (Double) -> Double = { _ in 0.5 }, id:)`: `xAt` is the box center.
- Config:
  - `turnedAroundMinDriftFraction = 0.02` ("An approaching car's center must move at least this much of the picture width to count")
  - `turnedAroundMinCars = 2` ("This many approaching cars in a row drifting away from the street's side means the phone is turned around")

- [ ] **Step 1: Write the failing tests.** In `DecideTests`; `growing` = `{ 0.05 * (1 + 0.2 * $0) }`.

```swift
private func comingCar(id: Int, drift: Double) -> Track {
    trackWithDirection(heightAt: { 0.05 * (1 + 0.2 * $0) }, xAt: { 0.5 + drift * $0 / 4 }, id: id)
}
func testTwoCarsDriftingTheWrongWayIsTurnedAround() {
    let d = Decider(checksTurnAround: true); d.roadSeenSeconds = 0
    _ = d.update(obs(4), tracks: [comingCar(id: 1, drift: 0.1)])
    XCTAssertEqual(feed(d, from: 4.1, through: 6, tracks: [comingCar(id: 2, drift: 0.1)]), .unknown(.turnedAround))
}
func testOneRightCarClearsTurnedAround() {
    let d = Decider(checksTurnAround: true); d.roadSeenSeconds = 0
    _ = d.update(obs(4), tracks: [comingCar(id: 1, drift: 0.1), comingCar(id: 2, drift: 0.1)])
    _ = d.update(obs(4.1), tracks: [comingCar(id: 3, drift: -0.1)])
    XCTAssertNotEqual(feed(d, from: 4.2, through: 6), .unknown(.turnedAround))
}
func testReplayNeverTurnedAround() {
    let d = seen()
    XCTAssertNotEqual(feed(d, from: 4, through: 6, tracks: [comingCar(id: 1, drift: 0.1), comingCar(id: 2, drift: 0.1)]),
                      .unknown(.turnedAround))
}
func testDriftOfANonApproachingCarDoesNotCount() {
    let d = Decider(checksTurnAround: true); d.roadSeenSeconds = 0
    let parked = { (id: Int) in trackWithDirection(heightAt: { _ in 0.1 }, xAt: { 0.5 + 0.1 * $0 / 4 }, id: id) }
    XCTAssertNotEqual(feed(d, from: 4, through: 6, tracks: [parked(1), parked(2)]), .unknown(.turnedAround))
}
```

`trackWithDirection` tracks have flat recent heights, so they never read as approaching: proof of a road, not a warning. The rule can therefore fire while they are in view. Add `.turnedAround` to `BannedWordsTests`.

- [ ] **Step 2: Run.** Expected: compile failures.

- [ ] **Step 3: Implement.**
  - **Decider evidence:**
    - Keeps a `Set<Int>` of track ids already judged, pruned to the current tracks, plus `recentDriftsRight: [Bool]` (the last `turnedAroundMinCars`).
    - On each level, still frame: every track with `travel == .toward`, not yet judged, and `abs(driftFraction) ≥ Config.turnedAroundMinDriftFraction` appends `driftFraction < 0`. Right = toward smaller x: the street is in the left half of both pictures, per the spec's Part 5.
  - **Rule** after misaimed: `checksTurnAround && recentDriftsRight.count == Config.turnedAroundMinCars && !recentDriftsRight.contains(true)` → `.unknown(.turnedAround)`.
  - **AppModel.run** passes `checksTurnAround: source is LiveCameraSource`.
  - **LiveCameraSource**, front camera only, before `addConnection`: `connection.automaticallyAdjustsVideoMirroring = false`, then `if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }`.
  - **Strings:** `sentence` returns "Turn the phone around" (no side prefix); `label` returns "Phone backwards".

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Pipeline/CLAUDE.md`: the rule, the street-on-the-left geometry, and the explicit front mirroring. `TASKS.md`: tick ("not verified on device: front feed should read text backwards").
  - Commit: `feat: approaching cars drifting the wrong way say "Turn the phone around"`.

### Task 7: Sideways hold

**Files:**
- Modify: `GapCheck/Feedback/Strings.swift`, `project.yml`, `GapCheck/DebugOverlay/ContentView.swift`
- Modify: `CLAUDE.md`, both folder `CLAUDE.md`s, `TASKS.md`

**Interfaces:** none new.

- [ ] **Step 1: Implement.** No new logic, so no new test; `BannedWordsTests` already reads `holdInstructions`.
  - `Strings.holdInstructions` = "Hold the phone sideways by the end without the cameras. Point the cameras at the street, camera bump facing right."
  - `project.yml`: `INFOPLIST_KEY_UISupportedInterfaceOrientations: "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"`.
  - `ContentView`: `section(.left)` and `section(.right)` sit in `AnyLayout(isWide ? HStackLayout(spacing: 10) : VStackLayout(spacing: 10))`, where `isWide` is the container being wider than tall (`GeometryReader`), with the level line above.
  - Docs:
    - Root `CLAUDE.md`: "The user holds the iPhone sideways, level, cameras toward the street, screen facing left".
    - `Pipeline/CLAUDE.md` Hold: landscape widens the view to about 69°; the tile spans about ±12° vertically.
    - `Feedback/CLAUDE.md`: the new hold sentence.
  - Run `xcodegen generate`.

- [ ] **Step 2: Run all tests.** Expected: PASS. Build for the simulator and launch it once in landscape; both feeds should sit side by side.

- [ ] **Step 3: Commit.** Tick `TASKS.md` ("not verified on device"). Commit: `feat: sideways hold — cameras toward the street, fingers off the lenses`.

### Task 8: Front/rear model, stage 1 (debug screen only)

**Files:**
- Create: `tools/export_car_orientation.py`, `GapCheck/Pipeline/CarOrientation.mlpackage` (generated), `GapCheck/Pipeline/Orientation.swift`
- Modify: `.gitignore` (`*.pth`)
- Modify: `GapCheck/Pipeline/Track.swift`, `GapCheck/Pipeline/Pipeline.swift`, `GapCheck/Pipeline/Decide.swift`, `GapCheck/Pipeline/Config.swift`
- Modify: `GapCheck/AppModel.swift`, `GapCheck/DebugOverlay/ContentView.swift`
- Modify: `CLAUDE.md` (Commands), `GapCheck/Pipeline/CLAUDE.md`, `TASKS.md`
- Test: `GapCheckTests/TrackTests.swift`, `GapCheckTests/DecideTests.swift`, `GapCheckTests/DetectTests.swift`

**Interfaces:**
- Consumes: `countsAsComing` (Task 4).
- Produces:
  - `final class CarOrientationClassifier { init() throws; func rearProbability(_ frame: Frame, box: CGRect) throws -> Double }`
  - `Pipeline(side:source:detector:orientation: CarOrientationClassifier? = nil, checksTurnAround: Bool = false)`
  - `func clampedCrop(_ box: CGRect) -> CGRect?`
  - `Track.rearFrames: Int = 0`
  - `Track.isSeenFromBehind: Bool` (`rearFrames >= Config.directionModelRearFrames`)
  - `Tracker.noteRear(_ probabilities: [Int: Double]) -> [Track]`
  - `countsAsComing(_ track: Track, suppressesRear: Bool = Config.directionModelSuppressesRearCars) -> Bool`
- Config:
  - `directionModelMinHeightPixels = 112.0` ("Smaller crops are far outside the model's training data")
  - `directionModelMaxCropsPerFrame = 2`
  - `directionModelRearProbability = 0.8`
  - `directionModelRearFrames = 3`
  - `directionModelSuppressesRearCars = false` ("Stage 1: the verdict only shows on screen. Flip after the curb field test confirms it")

- [ ] **Step 1: Download and export.**
  - Add `*.pth` to `.gitignore`.
  - Run `curl -L -o tools/convnext-multi-weak.pth https://huggingface.co/fort-cyber/Car-orientation-image/resolve/main/convnext-multi-weak.pth`, and check the file is exactly 201141385 bytes.
  - Run `.venv/bin/pip install "timm==1.0.*"`.
  - `tools/export_car_orientation.py`:
    - **Model:** rebuild `ConvNextSmallMultiModel` from `fort-cyber/car-orientation/models/multitask_models.py` (Apache-2.0; credit it in a comment): `timm.create_model('convnext_small', pretrained=False)`, `head.fc = Linear(768, 1024)`, `class_prediction = Linear(1024, 8)`, `angle_prediction = Linear(1032, 1)`.
    - **Weights:** `load_state_dict(torch.load(path, map_location="cpu", weights_only=True), strict=True)`.
    - **Export:** wrap it to return `softmax(class_logits)` and trace at 1×3×224×224. Then `ct.convert` with:
      - `ImageType(name="image", shape=(1, 3, 224, 224), scale=1/255, color_layout=ct.colorlayout.RGB)`
      - `ClassifierConfig(["front", "front-left", "left", "back-left", "back", "back-right", "right", "front-right"])`
      - `minimum_deployment_target=ct.target.iOS17`
    - **Quantize:** `ct.optimize.coreml.linear_quantize_weights` (8-bit, `linear_symmetric`), then save to `GapCheck/Pipeline/CarOrientation.mlpackage`.
    - **Parity check:** run `.venv/lib/python3.12/site-packages/ultralytics/assets/bus.jpg` (resized to 224×224, RGB) through both torch and CoreML. Assert the same top class and a largest per-class probability difference ≤ 0.05; print the top class.
  - Expected: the script prints `parity ok`, its top class, and a package size around 50 MB.

- [ ] **Step 2: Write the failing tests.**

```swift
func testRearNeedsThreeFramesInARow() {          // TrackTests
    let tracker = Tracker()
    let box = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
    _ = tracker.update([car(box)], atSeconds: 0, orientation: .up)
    _ = tracker.noteRear([1: 0.9]); _ = tracker.noteRear([1: 0.9])
    XCTAssertFalse(tracker.noteRear([1: 0.5])[0].isSeenFromBehind)
    _ = tracker.noteRear([1: 0.9]); _ = tracker.noteRear([1: 0.9])
    XCTAssertTrue(tracker.noteRear([1: 0.85])[0].isSeenFromBehind)
}
func testRearCarCountsUntilEnabled() {           // DecideTests
    var t = makeTrack(approachingHeights(tauAtEndSeconds: 8.5, heightAtEnd: 0.02)); t.rearFrames = 3
    XCTAssertTrue(countsAsComing(t, suppressesRear: false))
    XCTAssertFalse(countsAsComing(t, suppressesRear: true))
}
func testCropIsClampedToThePicture() {           // DetectTests
    XCTAssertEqual(clampedCrop(CGRect(x: 0.75, y: -0.25, width: 0.5, height: 0.5)), CGRect(x: 0.75, y: 0, width: 0.25, height: 0.25))
    XCTAssertNil(clampedCrop(CGRect(x: 1.2, y: 0.5, width: 0.1, height: 0.1)))
}
```

- [ ] **Step 3: Run.** Expected: compile failures.

- [ ] **Step 4: Implement.**
  - **Orientation.swift:** a `VNCoreMLRequest` on `CarOrientation`, with `imageCropAndScaleOption = .scaleFill` (the training resized whole crops) and `regionOfInterest = clampedCrop(box)`. It returns the sum of the `back-left`, `back` and `back-right` confidences.
  - **Pipeline.process,** after `tracker.update`:
    - Pick candidate tracks: too new (`estimate(atSeconds:).isTooNew`) and `box.height × orientedSizePixels(frame).height ≥ Config.directionModelMinHeightPixels`.
    - Take the largest first, at most `directionModelMaxCropsPerFrame`, classify them, then run `tracks = tracker.noteRear(...)`.
    - Log each `(id, probability)` with `Logger(subsystem: "GapCheck", category: "orientation")`.
    - A classifier that failed to load (nil) skips all of this.
  - **Decide:** rule 4 uses the extended `countsAsComing`.
  - **AppModel:** builds one classifier per pipeline next to its detector (`try? CarOrientationClassifier()`).
  - **ContentView `drawTracks`:** append "  rear" to a track's label when `isSeenFromBehind`.
  - **Docs:** `CLAUDE.md` Commands gets `.venv/bin/python tools/export_car_orientation.py`. `Pipeline/CLAUDE.md` gets the two-stage plan and the model facts from the spec's Part 7.
  - Run `xcodegen generate`.

- [ ] **Step 5: Run all tests.** Expected: PASS.

- [ ] **Step 6: Commit.**
  - Tick `TASKS.md` ("stage 1, screen only; speed and accuracy not verified on device").
  - Commit the script and the `.mlpackage`, not the `.pth`. Message: `feat: CFV front/rear model labels cars seen from behind on the debug screen (stage 1)`.

### Task 9: Best installed voice

**Files:**
- Modify: `GapCheck/Feedback/Speech.swift`, `GapCheck/Feedback/Strings.swift`, `GapCheck/AppModel.swift`
- Modify: `GapCheck/Feedback/CLAUDE.md`, `TASKS.md`
- Test: `GapCheckTests/FeedbackTests.swift` (new class `VoiceTests`)

**Interfaces:**
- Produces:
  - `struct VoiceInfo { let identifier: String; let language: String; let quality: AVSpeechSynthesisVoiceQuality; let isNovelty: Bool; let isPersonal: Bool }`
  - `func bestVoice(_ voices: [VoiceInfo], language: String) -> VoiceInfo?`
  - `Speech.hasOnlyBasicVoice: Bool`
  - `Strings.voiceTip`

- [ ] **Step 1: Write the failing tests.**

```swift
final class VoiceTests: XCTestCase {
    private func v(_ id: String, _ q: AVSpeechSynthesisVoiceQuality, lang: String = "en-US", novelty: Bool = false, personal: Bool = false) -> VoiceInfo {
        VoiceInfo(identifier: id, language: lang, quality: q, isNovelty: novelty, isPersonal: personal)
    }
    func testPrefersPremiumOverEnhancedOverDefault() {
        XCTAssertEqual(bestVoice([v("a", .default), v("b", .premium), v("c", .enhanced)], language: "en-US")?.identifier, "b")
    }
    func testSkipsNoveltyPersonalAndOtherLanguages() {
        let voices = [v("n", .premium, novelty: true), v("p", .premium, personal: true), v("f", .premium, lang: "fr-FR"), v("d", .default)]
        XCTAssertEqual(bestVoice(voices, language: "en-US")?.identifier, "d")
        XCTAssertNil(bestVoice([v("f", .premium, lang: "fr-FR")], language: "en-US"))
    }
}
```

Add `Strings.voiceTip` to the texts in `BannedWordsTests`.

- [ ] **Step 2: Run.** Expected: compile failures.

- [ ] **Step 3: Implement.**
  - **Speech** builds `VoiceInfo` from `AVSpeechSynthesisVoice.speechVoices()`, using `voiceTraits` `.isNoveltyVoice` / `.isPersonalVoice`. It picks `bestVoice(…, language: AVSpeechSynthesisVoice.currentLanguageCode())` at init and again on `AVSpeechSynthesizer.availableVoicesDidChangeNotification`.
  - **Each utterance** gets `voice` (nil = system default) and `prefersAssistiveTechnologySettings = true`.
  - `hasOnlyBasicVoice` = no best voice, or its quality is `.default`.
  - `Strings.voiceTip` = "For a clearer voice, download an Enhanced voice in Settings, Accessibility, Spoken Content."
  - **AppModel:** the first-launch hold instructions append `voiceTip` when `speech.hasOnlyBasicVoice`. The long press stays as is.

- [ ] **Step 4: Run all tests.** Expected: PASS.

- [ ] **Step 5: Docs and commit.**
  - `Feedback/CLAUDE.md`: voice selection and the one-time tip. `TASKS.md`: tick ("not verified on device"); add an unticked "Tone: recorded claves tick, waiting on the owner's sound files".
  - Commit: `feat: speak with the best installed voice; one-time tip when only the basic voice is installed`.

### Task 10: Wrap-up

- [ ] **Step 1:** Run all tests. Expected: all pass, 3 skipped (footage).
- [ ] **Step 2:** Check that `TASKS.md`'s Field test section is ticked except the tone, and that both folder `CLAUDE.md` rule lists match `Decide.swift`'s order.
- [ ] **Step 3:** Run a whole-branch review with superpowers:requesting-code-review against `main`. Fix merge-blocking findings, one commit each.
- [ ] **Step 4:** Hand off with superpowers:finishing-a-development-branch. The owner decides on the merge to `main`.
