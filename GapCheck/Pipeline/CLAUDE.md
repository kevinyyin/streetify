# Pipeline (safety-critical)

Source -> Detect -> Track -> Decide, one pipeline per camera on its own serial queue. The two share no state.

## Key idea

Time to arrival = box height / change in height per second. Height, because hand shake moves boxes without resizing them, and viewing angle changes width but not height.

## Stages

**Source:** frames with timestamps. Live: drop late frames, cap at `Config.processFps` (start 10), request 1920x1080. Replay: assume level; orientation from the video track.

**Detect:** pass orientation to Vision (don't rotate pixels). Two VNCoreMLRequests: whole frame, and a 640x640 center tile via `regionOfInterest`, where far cars appear. Classes: car, truck, bus, motorcycle, bicycle. Merge overlapping boxes.

**Track:** match by IoU, else nearest center within `Config.matchRadius`. Keep height history over `Config.historySeconds` (start 1.5 s); fit a line for time to arrival.

**Decide**, first rule that fires wins (order changed 2026-10-10 after the first field test; spec `docs/superpowers/specs/2026-10-10-field-test-fixes-design.md`):
1. No frame within `Config.staleFrameTimeout` (start 300 ms): Unknown `stale`. Runs on a timer.
2. Phone moving (live only; curb only, owner 2026-10-10): Unknown `moving` ("Hold still"), unless a car was Approaching within `Config.carMemorySeconds` (then the last Approaching state is kept). `StillGate` (one for both cameras) takes the userAcceleration magnitude each frame: RMS over `Config.stillWindowSeconds` (1 s) above `Config.movingAccelerationG` (0.06 g, calibrate on device; the debug screen shows it) is moving, and it reads still again only after `Config.historySeconds` with no moving sample, so the arrival-time fit holds no walking frames. No motion data reads as still (not level already covers it).
3. Flat (low Laplacian variance) and not overexposed: `covered`; else too dark or too bright: Unknown with that reason.
4. Any track arriving within `Config.approachWindowSeconds` (start 20 s), or too new to measure: Approaching, with the smallest time or "far", **at any tilt**. Tracks driving away (`.away`: shrinking for sure over the direction window) don't count (`countsAsComing`; approved by the owner 2026-10-10, invariant 3); too-new tracks still do.
5. Phone not level (live only): Unknown `notLevel`. Below cars since 2026-10-10: tilt loses the horizon, so it stops "no cars", never a warning (replaces 2026-10-09's "tilt keeps the car as last said").
6. Front camera only: faces covering at least `Config.faceMinAreaFraction` (0.05) of the picture: Unknown `facingUser` ("Turn the screen away from you"); the road evidence is dropped (from `feature-fixing`).
7. Misaimed (from `feature-fixing`): the compass is more than `Config.headingToleranceDegrees` (25°) off the street heading, or a car crossed the view (slid at least 1 box width per second without growing, 5–30% of the picture tall) within `Config.misaimMemorySeconds` (10 s): Unknown `misaimed` ("Turn the phone back toward the road"). The heading locks whenever a vehicle travels along the camera axis; an uncalibrated compass gives no heading and no compass check. Crossing traffic drops the road evidence.
7b. Turned around (live only, 2026-10-10): the last `Config.turnedAroundMinCars` (2) approaching cars each drifted away from the street's side of the picture by at least `Config.turnedAroundMinDriftFraction` (0.02 of its width): Unknown `turnedAround` ("Turn the phone around"); the next car drifting the right way clears it. Geometry: with the screen facing left, the street (in front of the user) lies in the left half of both pictures. The back camera looks right, so the street is on its left; the front camera looks left, so the street is on its right, and its `…Mirrored` EXIF orientation puts it on the left. The front connection's mirroring is set off explicitly, so that holds. Each approaching car counts once, judged from still, level frames only; replay never checks. Not verified on device: the front feed should read text backwards.
8. Stationary or leaving vehicles (and people) covering over `Config.blockedFraction` of the center tile: Unknown `viewBlocked`.
9. No moving vehicle (growing or shrinking over `Config.directionWindowSeconds`) seen in `Config.roadEvidenceSeconds`: Unknown `noRoadSeen`. Clear means "road seen and empty", not "nothing detected".
10. Clear once rules 1 to 9 haven't fired for `Config.clearHoldSeconds` (start 1.5 s). Until then, keep the previous state.

Road evidence, the heading lock and crossing traffic count only from still, level frames (turning or walking slides and grows boxes too).

AppModel adds camera faults outside Decide: `noPermission`, `unsupported`, `interrupted`, `overheated` (session notifications, system pressure). A silent side reads its fault, else `stale`. A fault clears only when a frame taken after it arrives (frames in flight when it was set don't count; not verified on device). The session restarts only after a media-services reset; other runtime errors leave it stopped. When the watchdog fires it tells the Decider, which re-arms the clear hold on frame time. The watchdog is off while the app is paused.

## Decisions (approved 2026-10-08)

- **Hold:** gravity picks portrait, upside-down or either landscape every frame; Vision gets that camera's EXIF orientation; tracks reset when it changes. The hold since 2026-10-10 is sideways (landscape), cameras toward the street, screen facing left: it widens the view along the road from about 42° to about 69°, and the tile spans about ±12° vertically (±11° upright). Level = pitch ≤ 8°, roll ≤ 10° (more pitch loses the horizon from the tile). Buffer (approved 2026-10-09): once not level, it counts as level again only within 6° pitch and 8° roll, so a wobble near the limit doesn't flip the state. Idle timer off; the UI turns with the phone (feeds side by side when sideways).
- **Detect:** whole-frame request uses `.scaleFit` (the default `.centerCrop` drops about 44% of a 16:9 frame). Tile boxes are mapped back to full-frame coordinates. Overlap with IoU ≥ 0.5 keeps the tile box, unless it touches the tile edge. Confidence ≥ 0.25.
- **Track:** IoU ≥ 0.3, else nearest center within 1.0 box sizes per axis (hypot(dx/width, dy/height); owner to confirm, the plan said box heights); a track is dropped after 0.5 s unmatched. Time to arrival = mean height / slope − (now − mean time), which is unbiased when the growth is accelerating.
- **Rule 4:** approaching if too new, or if the lower bound (slope + 2 × slope standard error) gives under 20 s. The spoken number is the point estimate, or "far". Accepted cost: distant parked cars read "far".
- **Rule 8 (view blocked):** "stationary" = any track that isn't approaching; `blockedFraction` 0.3. People ("person" boxes) also count toward the covered area but are never tracked as cars (approved 2026-10-09). Whole/tile boxes merge only within the same label.
- **Rule 4 arrival:** a timed estimate under 20 s wins; otherwise "unmeasured" if any approaching track is too new, else "far" (approved 2026-10-09).
- **Rule 3 start values:** mean luma < 0.08 or > 0.95; Laplacian variance < 10 (calibrate on Footage).
- **Rule 1:** the live watchdog runs on main from each side's last update (host clock), so a hung pipeline or an ended replay still goes stale. On frame timestamps, a gap > 300 ms is stale. A frame whose detection throws never updates Decide, so failures go stale.

## Tests

- Synthetic timestamped boxes for Track and Decide: one test per rule, plus initial Unknown.
- One short committed clip through Detect.
- On Footage/: seconds of warning per car; under 10 is a miss.

## Ask first

Changing any threshold, window, tile position, model, or rule order.
