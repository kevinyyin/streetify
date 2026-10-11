# Field test fixes — design

Date: 2026-10-10. Source: the triage of the first on-device field test (Claude doc "Streetify field test triage").

## What the owner decided (2026-10-10)

- **Curb only.** The app judges cars only while the user stands still. Holding a cane and a phone while walking is too hard to also aim.
- Fix in the triage doc's order, merging what is needed from `origin/feature-fixing`.
- **Sideways hold:** phone in landscape, held by the end without the cameras, camera end toward the street, screen facing left (so the front camera still watches left).
- Cars driving away: use a model **already trained** to tell a car's front from its rear. No hand-made guess.
- Replace **both** sounds: the spoken voice and the tilt tone. They sound synthetic.
- Ignoring cars that drive away is approved (invariant 3).

## Decide, new rule order

First rule that fires wins. **Bold** = new or moved.

1. Stale (unchanged).
2. **Moving** (live only): the phone is not still → Unknown `moving`, unless a car was Approaching within `Config.carMemorySeconds` (renamed from `tiltCarMemorySeconds`, still 1 s). Then the last Approaching state is kept.
3. Image quality: covered, too dark, too bright (unchanged).
4. **Cars, at any tilt:** tracks that are not driving away (part 2), and are too new or arrive within 20 s → Approaching. Tilt no longer hides a car.
5. **Not level** → Unknown `notLevel`. Moved below cars: tilt now only stops "no cars", never a warning.
6. **Facing user** (merged): the front camera sees a face covering ≥ 5% of the picture → Unknown `facingUser`.
7. **Misaimed** (merged): the compass is more than 25° off the locked street heading, or a car crossed the view in the last 10 s → Unknown `misaimed`.
8. **Turned around** (new, part 5) → Unknown `turnedAround`.
9. View blocked (unchanged).
10. No road seen (unchanged). Road evidence now counts only while level **and still**.
11. Clear after the hold (unchanged).

## Part 1 — Walking gate ("Hold still")

- **Signal:** `CMDeviceMotion.userAcceleration` (gravity removed), already updated 30 times a second. `StillGate`, shared by both cameras like `LevelGate`, takes one sample per processed frame. It reports moving while the RMS over `Config.stillWindowSeconds` (1.0 s) is above `Config.movingAccelerationG` (start 0.06 g, calibrate on device).
- **Release:** still again only after `Config.historySeconds` (1.5 s) with no moving sample, so the arrival-time fit never contains walking frames. Tracks keep running through the walk; they are not reset.
- `Frame.isStill` and `FrameObservation.isStill`; replay frames are still.
- **What the user gets:** "Hold still" (one sentence for the whole phone, said once), label "Hold still", the problem vibration. Unlike not level, it is spoken.
- **Calibration knob:** the debug screen shows the current RMS in g, so the threshold can be tuned on the phone.
- Not CMMotionActivityManager: Apple states no latency, and developers report delays of several seconds.

## Part 2 — Ignore cars driving away

- Rule 4 skips tracks whose `travel` is `.away` (shrinking for sure over the 4 s window).
- Cars too new to measure still count (the first 1.5 s): a car pulling out next to the user looks the same as one that just passed.
- Part 7 adds the trained front/rear model on top of this.

## Part 3 — Cars while tilted

- The rule order above: cars before not level.
- **The tone stops while any side reports a car** (taken from `feature-fixing`'s `toneSettings(isCarComing:)`), so speech never plays over it.
- Feedback rule change: "while not level nothing is spoken" becomes "nothing but car news and 'camera stopped'".
- Replaces the 2026-10-09 "tilt keeps the car as last said". The car memory now serves only part 1.

## Part 4 — Merge from `feature-fixing`

Taken as written on that branch, with its tests:

- `facingUser`: `VNDetectFaceRectanglesRequest` on the front camera only. Sentence "Turn the screen away from you", label "Screen faces you".
- `misaimed`:
  - `Track.isCrossingView`.
  - Compass heading of the camera axis (`cameraHeadingDegrees`, motion updates in `.xMagneticNorthZVertical`), locked when a car travels along the axis.
  - Sentence "Turn the phone back toward the road", label "Turn to road".
  - The tone also guides the heading back while misaimed.
- **Change:** crossing traffic counts only from still, level frames. Turning the phone in the hand also slides boxes sideways. `ponytail:` no gyro compensation; add it if this misfires on the phone.
- **Not taken:** people and bike warnings, the heartbeat tick, and the partial-cover check (the sideways hold keeps fingers off the lenses; revisit with footage).

## Part 5 — "Turn the phone around"

- **The cue:** the street is in front of the user, so approaching cars drift toward the street's side of each picture.
- **Make the front camera deterministic:** set the front connection's `isVideoMirrored = false` (with `automaticallyAdjustsVideoMirroring = false`). Vision then gets a mirrored front image from the `…Mirrored` EXIF orientation.
- With the screen facing left, the street then sits in the **left** half of both pictures. Back camera: looking right, the street is on its left. Front camera: looking left, the street is on its right, mirrored to the left. So approaching cars drift toward smaller x in Vision coordinates on both sides.
- **Evidence:** each Decider records, once per track, the sign of a `.toward` track's center drift over its direction window, when the drift is at least `Config.turnedAroundMinDriftFraction` (0.02 of the picture width).
- **Firing:** when the last `Config.turnedAroundMinCars` (2) such tracks both drifted the wrong way → Unknown `turnedAround`. It clears when the next car drifts the right way.
- Each camera judges alone; a flipped phone flips both. Sentence "Turn the phone around" (one for the whole phone), label "Phone backwards".
- Not verified on device: the EXIF table in landscape and the mirroring. Check the debug preview once: the front feed should read text backwards.

## Part 6 — Sideways hold

- **Hold instructions:** "Hold the phone sideways by the end without the cameras. Point the cameras at the street, camera bump facing right." The camera bump gives a cue the user can feel. Gripping the far end keeps fingers off the lenses.
- **Gravity already picks the hold every frame** (`attitude`), so landscape needs no pipeline change. Portrait keeps working.
- **Info.plist:** allow both landscape orientations. The debug screen lays the two feeds side by side when it is wider than tall.
- Landscape widens the road view from about 42° to about 69°. The tile spans about ±12° vertically, so the level limits stay.
- `Pipeline/CLAUDE.md` and `Feedback/CLAUDE.md` are updated to the new hold.

## Part 7 — Trained front/rear model

**Finding:** no downloadable model trained on traffic seen from the curb exists. Models trained on street-level traffic (Roboflow Universe "rear-front-side-dataset", "cicc-orientation" and others) run only as hosted inference behind an account and API key. That breaks "everything runs on-device".

**The one usable model: CFV ConvNeXt** ([paper](https://www.mdpi.com/2079-9292/12/24/4947), [repo](https://github.com/fort-cyber/car-orientation), [weights](https://huggingface.co/fort-cyber/Car-orientation-image)). Facts checked in its code:

- **Architecture:** `ConvNextSmallMultiModel` in `models/multitask_models.py`, timm `convnext_small`, about 50M parameters.
- **Two heads:** 8-class logits and an angle (sigmoid × 360°).
- **Classes** (`datasets/angle_dataset.py`): 0 front, 1 front-left, 2 left, 3 back-left, 4 back, 5 back-right, 6 right, 7 front-right.
- **Input:** 224×224 RGB, the whole crop resized (`scripts/prepare_data.py`), values 0–1, no mean/std (`utils.py`, `ToTensor()` only).
- **License:** Apache-2.0 for the code, weights and data.
- **Weights:** `convnext-multi-weak.pth`, 201,141,385 bytes, on the Hugging Face page (direct download, no account).
- **Training data:** about 23,000 frames of parked cars about 3 m away, filmed walking around them with a phone. Reported 8-class accuracy 93.97% on its own test set. The error grows on other datasets.

**Plan:**

- **Convert** with coremltools in the existing `.venv`: load with `torch.load(weights_only=True)` so the pickle can't run code, export fp16 at about 100 MB, softmax over the 8 classes. This needs `timm` installed into the venv.
- **Run** only on crops of tracks that are still too new (their first 1.5 s), with a box at least `Config.directionModelMinHeightPixels` (start 112 px) tall. Smaller crops are far outside the training data. It runs on the pipeline's queue, after Detect, on at most `Config.directionModelMaxCropsPerFrame` (start 2) crops.
- **Verdict:** a track is "seen from behind" after 3 frames in a row where classes 3, 4 and 5 together reach ≥ 0.8. Front or side never suppresses anything.
- **Two stages, because the model has never been checked on traffic (invariant 3):**
  1. **Ship stage:** the verdict shows on the debug screen ("rear" next to the box) and is logged. Decide ignores it.
  2. **After the curb field test** confirms it on real passing cars, the owner flips `Config.directionModelSuppressesRearCars` to true. Then rule 4 skips tracks seen from behind, as it already skips `.away` ones.

**Asks before this part:**

- Approval to download `convnext-multi-weak.pth` (201 MB) from huggingface.co/fort-cyber/Car-orientation-image.
- Approval to install `timm` into `.venv` (export only).
- A ~100 MB model in the app bundle.

## Part 8 — Voice and tone

### Voice

The app speaks with `AVSpeechUtterance(string:)` and no voice set, which gives the basic default voice.

- **Pick the best installed voice:** from `AVSpeechSynthesisVoice.speechVoices()` for the current language, leaving out voices whose traits include novelty or personal voice, take the highest `quality` (premium > enhanced > default). Pick again on `AVSpeechSynthesizer.availableVoicesDidChangeNotification`.
- **Follow the user's settings:** set `prefersAssistiveTechnologySettings = true`, so the user's VoiceOver voice and rate win whenever VoiceOver runs.
- **Limit:** an app cannot download enhanced or premium voices; only the user can, in Settings. So when the best voice found is `.default`, the first-launch hold instructions end with a one-time tip: "For a clearer voice, download an Enhanced voice in Settings, Accessibility, Spoken Content."
- **Siri voices** are not available to apps (WWDC20 10022).
- **Not done:** pre-recorded clips. No licensed set covers "car", "seconds" and 1–20. If the owner wants a human voice later, record one person saying about 30 clips.

### Tone

Replace the sine with **a recorded wooden tick that repeats faster as the phone nears level**, and **one higher "level" sound** when it gets there, then silence.

**Precedents:**
- Apple Magnifier's People Detection gives "more frequent" feedback closer to the target.
- Soundscape plays a separate cue when on target.
- A 2023 sonification study found beep repetition rate the easiest cue to learn.
- The gaps between ticks leave the ear free for traffic.

**How it works:**
- **Interval:** `Config.tickSlowSeconds` (0.6 s at 45° or more off) down to `Config.tickFastSeconds` (0.12 s near level).
- **Same `AVAudioSourceNode`:** it plays the decoded sample at those intervals instead of computing a sine. It keeps the current audio route (speaker or bone-conduction headphones).
- **Not `AudioServicesPlaySystemSound`:** it ignores audio routing.
- **Unchanged rules:** the tone still means only "not level" (or misaimed, part 4), stops while a car is reported (part 3), and stays silent until a frame has reported the tilt. The level sound plays with the existing ready tap.

**Sounds (CC0, no attribution needed):**
- [claveshi.wav](https://freesound.org/people/MarleneAyni/sounds/90017/) (0.4 s, 71 KB) and [clavelow.wav](https://freesound.org/people/MarleneAyni/sounds/90016/). Real wooden claves, "unprocessed, recorded with AKG C214". Low = tick, high = level.
- Freesound needs a login to download, so **the owner downloads these two files** into `GapCheck/Feedback/Sounds/`.
- **Fallback:** Kenney "Interface Sounds" (CC0, 834 KB zip, direct link, no account), if its files are a format iOS can decode (not verified).

## Testing

- **One unit test per new rule:**
  - moving, and the car memory while moving;
  - cars beat not level;
  - away ignored, too new still counts;
  - turned around fires on two wrong drifts and clears on one right drift;
  - facing user and misaimed (from `feature-fixing`).
- **Other checks:**
  - `StillGate`: a walking-like 0.2 g sway is moving, a 0.01 g tremor is still, release after 1.5 s;
  - tone silent while a car is reported;
  - the tick interval shrinks toward level;
  - the voice picker prefers premium over enhanced over default and skips novelty voices;
  - the rear verdict needs 3 frames in a row at ≥ 0.8;
  - banned-words test covers the new strings.
- **Done** = builds, all tests pass, TASKS.md and both CLAUDE.md files updated. One commit per part.
- **Not verified on device (owner):**
  - the stillness threshold;
  - landscape orientation and mirroring;
  - compass;
  - face check;
  - a second field test standing at a curb.
