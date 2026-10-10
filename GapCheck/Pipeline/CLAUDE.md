# Pipeline (safety-critical)

Source -> Detect -> Track -> Decide, one pipeline per camera on its own serial queue. The two share no state.

## Key idea

Time to arrival = box height / change in height per second. Height, because hand shake moves boxes without resizing them, and viewing angle changes width but not height.

## Stages

**Source:** frames with timestamps. Live: drop late frames, cap at `Config.processFps` (start 10), request 1920x1080. Replay: assume level; orientation from the video track.

**Detect:** pass orientation to Vision (don't rotate pixels). Two VNCoreMLRequests: whole frame, and a 640x640 center tile via `regionOfInterest`, where far cars appear. Classes: car, truck, bus, motorcycle, bicycle, person. Front camera also runs Vision face rectangles. Merge overlapping boxes.

**Track:** match by IoU, else nearest center within `Config.matchRadius`. Keep height history over `Config.historySeconds` (start 1.5 s); fit a line for time to arrival.

**Decide**, first rule that fires wins (order approved 2026-10-09):
1. No frame within `Config.staleFrameTimeout` (start 300 ms): Unknown `stale`. Runs on a timer.
2. Phone not level (live only): Unknown `notLevel`, unless a car was Approaching within `Config.tiltCarMemorySeconds` (then Approaching, unmeasured).
3. Dark and flat, or flat: `covered`; else too dark, too bright; else 2+ tile cells flat and darker than half the frame's mean: `covered` (partly covered lens).
4. Any vehicle track arriving within `Config.approachWindowSeconds` (start 20 s), or too new to measure; any person track measured arriving: Approaching, with the smallest time (and what it is), "far" or unmeasured.
5. Front camera faces cover ≥ `Config.faceMinAreaFraction`: Unknown `facingUser`.
6. Compass more than `Config.headingToleranceDegrees` off the locked street heading, or crossing traffic within `Config.misaimMemorySeconds`: Unknown `misaimed`.
7. Non-approaching tracks (vehicles and people) covering over `Config.blockedFraction` of the center tile: Unknown `viewBlocked`.
8. No moving vehicle (travel toward or away) seen in `Config.roadEvidenceSeconds`: Unknown `noRoadSeen`. Clear means "road seen and empty", not "nothing detected".
9. Clear once rules 1 to 8 haven't fired for `Config.clearHoldSeconds` (start 1.5 s). Until then, keep the previous state.

AppModel adds camera faults outside Decide: `noPermission`, `unsupported`, `interrupted`, `overheated` (session notifications, system pressure). A silent side reads its fault, else `stale`.

## Decisions (approved 2026-10-08)

- **Hold:** gravity picks portrait, upside-down or either landscape every frame; Vision gets that camera's EXIF orientation; tracks reset when it changes. Level = pitch ≤ 8°, roll ≤ 10° (the tile spans about ±11° vertically, so more pitch loses the horizon). Buffer (approved 2026-10-09): once not level, it counts as level again only within 6° pitch and 8° roll, so a wobble near the limit doesn't flip the state. Idle timer off; UI locked portrait.
- **Detect:** whole-frame request uses `.scaleFit` (the default `.centerCrop` drops about 44% of a 16:9 frame). Tile boxes are mapped back to full-frame coordinates. Overlap with IoU ≥ 0.5 keeps the tile box, unless it touches the tile edge. Confidence ≥ 0.25.
- **Track:** IoU ≥ 0.3, else nearest center within 1.0 box sizes per axis (hypot(dx/width, dy/height); owner to confirm, the plan said box heights); a track is dropped after 0.5 s unmatched. Time to arrival = mean height / slope − (now − mean time), which is unbiased when the growth is accelerating.
- **Rule 4:** approaching if too new, or if the lower bound (slope + 2 × slope standard error) gives under 20 s. The spoken number is the point estimate, or "far". Accepted cost: distant parked cars read "far".
- **Rule 7:** "stationary" = any track that isn't approaching, people included; `blockedFraction` 0.3. Whole/tile boxes merge only within the same label.
- **Rule 4 arrival:** a timed estimate under 20 s wins; otherwise "unmeasured" if any approaching track is too new, else "far" (approved 2026-10-09).
- **Rule 3 start values:** mean luma < 0.08 or > 0.95; Laplacian variance < 10 (calibrate on Footage).
- **Aim (approved 2026-10-09):** road evidence = a level frame with a vehicle track whose `travel` is toward or away; it also locks the compass heading (back camera axis from gravity × magnetic field). Crossing = a vehicle 0.05 to 0.3 of the picture tall sliding ≥ 1 box width/s with ≤ 20% height change over ≥ 0.5 s; it clears the road evidence. A face or crossing clears road evidence too, so Clear waits for the next car. All of these "calibrate on Footage"; not verified on device.
- **People (approved 2026-10-09):** tracked like vehicles, matched only to their own kind; Approaching only once measured. Speech says "bike" for bicycle and motorcycle, "person" for people.
- **Rule 1:** the live watchdog runs on main from each side's last update (host clock), so a hung pipeline or an ended replay still goes stale. On frame timestamps, a gap > 300 ms is stale. A frame whose detection throws never updates Decide, so failures go stale. When the watchdog fires it tells the Decider, which re-arms the clear hold on frame time.

## Tests

- Synthetic timestamped boxes for Track and Decide: one test per rule, plus initial Unknown.
- One short committed clip through Detect.
- On Footage/: seconds of warning per car; under 10 is a miss.

## Ask first

Changing any threshold, window, tile position, model, or rule order.
