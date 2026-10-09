# Pipeline (safety-critical)

Source -> Detect -> Track -> Decide, one pipeline per camera on its own serial queue. The two share no state.

## Key idea

Time to arrival = box height / change in height per second. Height, because hand shake moves boxes without resizing them, and viewing angle changes width but not height.

## Stages

**Source:** frames with timestamps. Live: drop late frames, cap at `Config.processFps` (start 10), request 1920x1080. Replay: assume level; orientation from the video track.

**Detect:** pass orientation to Vision (don't rotate pixels). Two VNCoreMLRequests: whole frame, and a 640x640 center tile via `regionOfInterest`, where far cars appear. Classes: car, truck, bus, motorcycle, bicycle. Merge overlapping boxes.

**Track:** match by IoU, else nearest center within `Config.matchRadius`. Keep height history over `Config.historySeconds` (start 1.5 s); fit a line for time to arrival.

**Decide**, first rule that fires wins:
1. No frame within `Config.staleFrameTimeout` (start 300 ms): Unknown `stale`. Runs on a timer.
2. Phone not level (live only): Unknown `notLevel`.
3. Too dark, too bright, or covered (low Laplacian variance): Unknown with that reason.
4. Any track arriving within `Config.approachWindowSeconds` (start 20 s), or too new to measure: Approaching, with the smallest time or "far".
5. Stationary vehicle covering over `Config.blockedFraction` of the center tile: Unknown `viewBlocked`.
6. Clear once rules 1 to 5 haven't fired for `Config.clearHoldSeconds` (start 1.5 s). Until then, keep the previous state.

## Decisions (approved 2026-10-08)

- **Hold:** gravity picks portrait, upside-down or either landscape every frame; Vision gets that camera's EXIF orientation; tracks reset when it changes. Level = pitch ≤ 8°, roll ≤ 10° (the tile spans about ±11° vertically, so more pitch loses the horizon). Idle timer off; UI locked portrait.
- **Detect:** whole-frame request uses `.scaleFit` (the default `.centerCrop` drops about 44% of a 16:9 frame). Tile boxes are mapped back to full-frame coordinates. Overlap with IoU ≥ 0.5 keeps the tile box, unless it touches the tile edge. Confidence ≥ 0.25.
- **Track:** IoU ≥ 0.3, else nearest center within 1.0 box heights; a track is dropped after 0.5 s unmatched. Time to arrival = mean height / slope − (now − mean time), which is unbiased when the growth is accelerating.
- **Rule 4:** approaching if too new, or if the lower bound (slope + 2 × slope standard error) gives under 20 s. The spoken number is the point estimate, or "far". Accepted cost: distant parked cars read "far".
- **Rule 5:** "stationary" = any track that isn't approaching; `blockedFraction` 0.3.
- **Rule 3 start values:** mean luma < 0.08 or > 0.95; Laplacian variance < 10 (calibrate on Footage).
- **Rule 1:** on replay, a frame-timestamp gap > 300 ms is stale. A frame whose detection throws never updates Decide, so failures go stale.

## Tests

- Synthetic timestamped boxes for Track and Decide: one test per rule, plus initial Unknown.
- One short committed clip through Detect.
- On Footage/: seconds of warning per car; under 10 is a miss.

## Ask first

Changing any threshold, window, tile position, model, or rule order.
