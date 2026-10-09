# TASKS

## Before the event
- [x] Check CalHacks rules on pre-event code (skipped by decision)
- [ ] Record crossing clips, phone level and edge-on, day and night, some on the front camera
- [ ] Talk to 2 or 3 blind travelers or an O&M instructor
- [ ] Confirm phones are iPhone XS/XR or newer

## Phase 0: setup (Claude does all of it; stops only for the human steps)
- [x] Check Xcode, command line tools, Homebrew, Python. List anything that needs my password or Apple ID, with exact steps
- [x] Install XcodeGen and ultralytics if missing
- [x] Download iOS simulator runtime
- [x] git init; .gitignore for GapCheck.xcodeproj, Local.xcconfig, Footage/, *.pt, DerivedData, .DS_Store
- [x] project.yml: app target GapCheck (SwiftUI, camera usage description), test target GapCheckTests, Local.xcconfig included
- [x] Export YOLO to CoreML and add it to the app target
- [x] Empty app builds; tests run on a simulator; Commands in CLAUDE.md filled in; first commit
- [x] STOP: ask me to sign in to Xcode and pick my team once. Then read DEVELOPMENT_TEAM from the generated project into Local.xcconfig, set a unique bundle ID, regenerate
- [ ] STOP: ask me to run it on my iPhone; confirm it launches

## Phase 1: one direction (hours 0 to 8)
- [x] FrameSource with LiveCameraSource (back camera) and VideoFileSource (live: not verified on device)
- [x] Whole-frame detection through Vision
- [x] Debug overlay with feed and boxes (not verified on device)

## Phase 2: trustworthy, then both directions (hours 8 to 18)
- [x] Center tile request, merged boxes
- [x] Tracker and time to arrival
- [x] Decide rules and Config.swift
- [ ] Unit tests per rule; one clip test (rule tests done; clip test written, skips until GapCheckTests/clip.mov exists)
- [x] Second camera via AVCaptureMultiCamSession; `frontCameraFacesLeft` (default true) (not verified on device)

## Gate (hour 18)
- [ ] Both directions work live and on replay. Stretch work only after this.

## Phase 3: feedback (hours 18 to 26)
- [x] Strings.swift (banned-words test deferred by decision, 2026-10-08)
- [x] Haptics, tone, speech (not verified on device)
- [x] State-change test
- [x] Feedback redesign: one job per signal (2026-10-09) (not verified on device)
- [x] Speech: same-side news waits instead of cutting in; waiting sentences are refreshed or dropped when their turn comes; tone silent until a frame reports tilt (2026-10-09) (not verified on device)

## Debug overlay
- [x] Segmentation outlines (YOLO11n-seg, screen only, own queue, skips frames when busy) tinted red ≤ 8 s, yellow facing us, green driving away (2026-10-09) (not verified on device: speed and heat with two cameras)
- [x] Red sticks to a car until it leaves the picture or stands still with no red car ahead in its line; cars coming behind a red car are red too; direction (green) judged over 4 s (2026-10-09)

## Phase 4: test and tune (hours 26 to 32)
- [ ] Run all footage: warning seconds per car, misses, false alarms, parked cars (report ready: FootageTests/testFootageReport; each clip needs `<clip>.passes.txt`: one pass time in seconds per line)
- [ ] On device: front-camera range, 5-minute heat run, VoiceOver with Screen Curtain

## Phase 5: demo (hours 32 to 36)
- [ ] Feature freeze, demo video, slides, rehearse Q&A

## Stretch
- [ ] Walk-signal mode with turning-car warning

## Blockers
- Need `GapCheckTests/clip.mov`: a few seconds, phone level, one car approaching (for ClipTests).
