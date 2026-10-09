# Calmer Feedback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One job per signal, one signal at a time: the tone only for aiming, speech only for direction states (plus one close warning per car), and the screen as a single VoiceOver status item.

**Architecture:** No new components. The change lives in the pure decision functions (`isLevel`, `announce`/`announcedBaseline`, `toneSettings`, `Strings.status`), which are already unit-tested, plus thin wiring in `LiveCameraSource`, `Tone`, `AppModel` and `ContentView`.

**Tech Stack:** Swift, SwiftUI accessibility, XCTest, XcodeGen.

**Spec:** `GapCheck/Feedback/CLAUDE.md` (signal table and rules, 2026-10-09), `GapCheck/Pipeline/CLAUDE.md` (level buffer).

## Global Constraints

- Tone = "not level" only, 200–500 Hz rising toward level; silent when level; never used for cars; no pan.
- Not level: no speech, no vibration. The state after leveling out is always announced.
- "Camera stopped" is always spoken, even while not level.
- Close warning at or under `Config.closeWarningSeconds = 5`, once per car. Timed → far, close → timed and close → far are silent.
- Level buffer: not level past 8° pitch / 10° roll; level again only within `levelReturnPitchToleranceDegrees = 6` / `levelReturnRollToleranceDegrees = 8`.
- Never "safe", "go", "cross now", "clear to cross", "all clear". Every UI element that VoiceOver can reach has a label. Units in names; every tunable in `Config.swift` with a one-line comment.
- `TEST <Class>` = `xcodebuild -scheme GapCheck -destination 'platform=iOS Simulator,name=iPhone 17' -collect-test-diagnostics never test -only-testing:GapCheckTests/<Class>`.

## Review Focus

1. The two cameras go not level a few ms apart → still no speech at all (each side is silent on its own).
2. A car appears while the phone is tilted → after leveling it is announced (baseline recorded not level, so the new state differs).
3. A camera stops while tilted → "Left camera stopped" is spoken over the tone (the one allowed overlap).
4. With VoiceOver on, double-tapping the status item speaks it once, through VoiceOver (no second voice).
5. An estimate wobbling 4 → 6 → 4 s → one close warning, not three.

---

### Task 1: Level buffer

**Files:** Modify `GapCheck/Capture/Level.swift`, `GapCheck/Capture/LiveCameraSource.swift`, `GapCheck/Pipeline/Config.swift`. Test: `GapCheckTests/LevelTests.swift`.

**Produces:** `func isLevel(_ a: Attitude, wasLevel: Bool) -> Bool`. Uses the 8°/10° limits while `wasLevel`, and the 6°/8° return limits otherwise.

- [ ] Write the test `testLevelBufferStopsFlipping`. Starting from `wasLevel: true`, feed pitches 7°, 9°, 7°, 5°, each as `attitude(gravityX: 0, gravityY: -cos p, gravityZ: sin p)` and passing each result into the next call. Expect `[true, false, false, true]`.
- [ ] `TEST LevelTests` → FAIL (`isLevel(_:wasLevel:)` is missing).
- [ ] Implement it. `LiveCameraSource` keeps `private var wasLevel = false` (touched only on its queue) and sets `Frame.isLevel` from `isLevel(a, wasLevel:)`. Missing motion is still not level.
- [ ] → PASS. Commit.

### Task 2: Announcements: not level is silent; close warning once

**Files:** Modify `GapCheck/Feedback/Announce.swift`, `GapCheck/Pipeline/Config.swift`. Test: `GapCheckTests/FeedbackTests.swift`.

- `Spoken` gains `close`: `.approaching(.seconds(s))` maps to `.close` when `s <= Config.closeWarningSeconds`, else `.timed`.
- `isChange(from:to:)` is false for equal values, and for timed→far, close→timed and close→far.
- `announcedBaseline` is unchanged: it records every change, including into not level.
- `announce` drops sides whose new state is `.unknown(.notLevel)` from the spoken list (and from the restated sides). If nothing is left, it returns nil.

- [ ] Write the tests:
  - `testNotLevelIsSilentButLevelingOutIsAnnounced`: clear→both not level gives nil. Then, from that baseline, both clear gives `FeedbackEvent(haptic: .clear, text: "No cars seen left. No cars seen right")`.
  - `testCloseWarningSpokenOnce`: left 12 s→4 s gives `FeedbackEvent(haptic: .approaching, text: "Car left, about 4 seconds")`. Then, carrying the baseline forward, 4→6 gives nil and 6→4 gives nil.
  - `testCameraStoppedIsSpokenWhileTilted`: both not level → left `.unknown(.stale)` gives text "Left camera stopped".
- [ ] Update the existing tests that the spec changes, and ledger each:
  - `testNoChangeGivesNothing` uses 9→8 s; 6→5 is now a close warning.
  - Remove `testSameSentenceBothSidesSpokenOnce`; not level is no longer spoken.
- [ ] `TEST FeedbackTests` → FAIL. Implement. → PASS. Commit.

### Task 3: Tone is aiming only

**Files:** Modify `GapCheck/Feedback/Announce.swift`, `GapCheck/Feedback/Tone.swift`, `GapCheck/AppModel.swift`, `GapCheck/Pipeline/Config.swift` (remove `approachMinHz`/`approachMaxHz`). Test: `GapCheckTests/FeedbackTests.swift`.

**Produces:** `struct ToneSettings: Equatable { let isOn: Bool; let frequencyHz: Double }` and `func toneSettings(isLevel: Bool, tiltErrorDegrees: Double) -> ToneSettings`.

- [ ] Write the test `testToneOffWhenLevel`: `toneSettings(isLevel: true, tiltErrorDegrees: 0).isOn == false`.
- [ ] Adapt `testAimingToneRisesTowardLevel` to the new signature.
- [ ] Remove `testTonePansToNearestCar`, `testToneSilentWhenClear` and `testUnmeasuredCarGetsMidPitch` (the car tone is gone); ledger it.
- [ ] Adapt `testToneRestartsWhenEngineStops` to the two-field `ToneSettings`.
- [ ] FAIL → implement: `Tone.apply` drops `pan`, and `AppModel.updateTone` passes only level and tilt. → PASS. Commit.

### Task 4: The screen as one status item

**Files:** Modify `GapCheck/Feedback/Strings.swift`, `GapCheck/DebugOverlay/ContentView.swift`, `GapCheck/AppModel.swift`. Test: `GapCheckTests/FeedbackTests.swift`.

**Produces:**
- `Strings.status(_ states: [Side: DirectionState]) -> String`: left then right sentence, de-duplicated, joined with ". ".
- `AppModel.speakStatus()`: speaks `Strings.status` of the current pane states through `Speech`.

- [ ] Write the test `testStatusSentence`:
  - `[.left: .clear, .right: .approaching(.seconds(6))]` → "No cars seen left. Car right, about 6 seconds"
  - both not level → "Hold the phone level"
- [ ] FAIL → implement the `ContentView` changes:
  - Both panes (camera images, boxes, state lines) form one group with `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(Strings.status(...))`, `.accessibilityHint("Double-tap to hear it again")` and `.onTapGesture { model.speakStatus() }`.
  - The replay buttons move to one row below the group and keep their labels.
- [ ] → PASS. Device build passes. Commit.

### Task 5: Records

- [ ] TASKS.md Phase 3 gets the item "Feedback redesign: one job per signal (2026-10-09)". Full suite passes. Commit and push.
- [ ] **STOP (you):** on the phone, redo tests 3–7 and the VoiceOver test. Expect one signal at a time. Not verified on device until you do.

## Execution

**Native (recommended):** I implement in this session, then one fresh reviewer checks the diff. There are four small tasks in shared files, all behind existing tests.
