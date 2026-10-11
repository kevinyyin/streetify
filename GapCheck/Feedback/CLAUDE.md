# Feedback

The user can't see the screen; this folder is the product for them. One job per signal, one signal at a time, so their ears stay free for traffic. (Redesigned 2026-10-09 after on-device testing showed sensory overload.)

## What each signal means

| Signal | Its only job | When |
|---|---|---|
| **Tone** | "The phone isn't pointed right" | While not level, or while a side is misaimed and the compass is off the street heading; pitch rises toward aimed (200–500 Hz). Silent otherwise. Never used for cars. |
| **Ready tap** (one crisp tap) | "Level, ready" | Once, when the phone becomes level |
| **Speech** | What each direction is | One short sentence per side that changed, side first: "Right: car, 6 seconds", "Left: blocked", "Left: no cars" |
| **Vibration with speech** | The whole situation | 3 sharp taps = a car is coming · 2 medium taps = a problem · 1 soft hum = no cars on either side |
| **Screen (VoiceOver)** | Hear the status again | The whole screen is one item reading the current status sentence; touching it repeats it. With VoiceOver off, tapping anywhere speaks it. |

## Rules

- **"Hold still"** (the phone is moving; curb only, 2026-10-10) is spoken once for the whole phone, with the problem vibration.
- **Not level is never spoken and has no vibration**; the tone says it. The state after leveling out is always announced, even if it is the same as before the tilt.
- **Never two voices:** with VoiceOver on, speech is a high-priority VoiceOver announcement; otherwise AVSpeechSynthesizer. Audio session `.playback` + `.mixWithOthers`.
- **Tone and speech don't overlap:** the tone plays only while not level (or misaimed off the heading), and then nothing is spoken but car news and "camera stopped". A tilted phone still reports cars (2026-10-10), and **the tone stops while any side reports a car**, so the car's sentence is heard.
- A change means a change of kind, a change of Unknown reason (other than not level), far/unmeasured → timed, or timed → close (at or under `Config.closeWarningSeconds`, 5 s). Timed → far is silent. After a close warning, a time within 3 s of it is the same car (silent); a bigger jump or "far" is the next car and is spoken. So each car gets its first time and one close warning.
- A too-new track is "Car left" with no distance; "far" is only for measured cars beyond 20 s.
- **One sentence at a time, cars first** (approved 2026-10-09; changed 2026-10-09 to stop the chatter, then fixed so close warnings still cut in): priority is close car (at or under `Config.closeWarningSeconds`) > car > problem > no cars. A sentence only cuts in when it is more urgent, so a close warning cuts in even on the same side; other newer news about the side being spoken waits. While waiting, only the newest sentence per side is kept, and when its turn comes it is rebuilt from that side's state *now*, so a car that already passed is never announced late. A sentence a car cut off is said again afterwards (also as it is by then). If a sentence is never reported finished, the next plays after 4 s. The status the user asks for (tap / VoiceOver) replaces everything, since it restates both sides. The hold instructions (long press) cut in too but replace nothing: news they cut off or hold up is said after them.
- Output is coalesced for 0.2 s; only sides that changed are spoken (no restating the other side). Phone-wide sentences ("Phone too hot") are said once even when both sides report them (the speech queue drops a waiting sentence identical to the one starting).
- **Pause** (2026-10-09): going to the background speaks "Streetify paused" with the problem vibration, and until coming back nothing else is said and the tone is off; coming back resets both sides to Unknown and announces them afresh. A first launch speaks how to hold the phone ("Hold the phone sideways by the end without the cameras. Point the cameras at the street, camera bump facing right."; the camera bump is the cue a blind user can feel, and gripping the far end keeps fingers off the lenses); a long press (or the VoiceOver action) repeats it. Volume 0 gives one problem vibration and shows "Volume off". The tone stays silent until a camera frame has reported the tilt (the simulator has no motion sensor; replay frames count as level). Not verified on device.
- Approaching and Unknown always override Clear: the vibration follows the whole situation, so the "no cars" hum only plays when neither side has a car or a problem.
- All user-facing text in `Strings.swift`, side first: "Left: no cars", "Right: car, 4 seconds", "Right: car, close" (under 1 s), "Right: car, far", "Right: car", "Left: blocked", "Left: camera covered", "Left: too dark", "Left: too bright", "Left: camera stopped", "Left: camera in use", "Right: no road seen"; phone-wide: "Camera access is off. Turn it on in Settings", "This iPhone can't use both cameras", "Phone too hot". Never "safe", "go", "cross now", "clear to cross" or "all clear" (`BannedWordsTests`).
- The tone must work on the speaker and on bone-conduction headphones. Check on device that speech never talks over VoiceOver.
- Test: each state change gives the right vibration and text; no change gives nothing; not level gives only the tone.
