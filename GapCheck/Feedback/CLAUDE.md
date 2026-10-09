# Feedback

The user can't see the screen; this folder is the product for them. One job per signal, one signal at a time, so their ears stay free for traffic. (Redesigned 2026-10-09 after on-device testing showed sensory overload.)

## What each signal means

| Signal | Its only job | When |
|---|---|---|
| **Tone** | "The phone isn't level" | While not level; pitch rises toward level (200–500 Hz). Silent otherwise. Never used for cars. |
| **Ready tap** (one crisp tap) | "Level, ready" | Once, when the phone becomes level |
| **Speech** | What each direction is | Once per change, one sentence, e.g. "No cars seen left. Car right, about 6 seconds" |
| **Vibration with speech** | What kind of news | 3 sharp taps = car coming · 2 medium taps = problem · 1 soft hum = no cars |
| **Screen (VoiceOver)** | Hear the status again | The whole screen is one item reading the current status sentence; touching it repeats it. With VoiceOver off, tapping anywhere speaks it. |

## Rules

- **Not level is never spoken and has no vibration**; the tone says it. The state after leveling out is always announced, even if it is the same as before the tilt.
- **Never two voices:** with VoiceOver on, speech is a high-priority VoiceOver announcement; otherwise AVSpeechSynthesizer. Audio session `.playback` + `.mixWithOthers`.
- **Tone and speech don't overlap:** the tone plays only while not level, and while not level nothing is spoken, with one exception: "camera stopped" is always spoken.
- A change means a change of kind, a change of Unknown reason (other than not level), far/unmeasured → timed, or timed → close (at or under `Config.closeWarningSeconds`, 5 s). Timed → far is silent. After a close warning, a time within 3 s of it is the same car (silent); a bigger jump or "far" is the next car and is spoken. So each car gets its first time and one close warning.
- A too-new track is "Car left" with no distance; "far" is only for measured cars beyond 20 s.
- Output is coalesced for 0.2 s; both directions changing together = one sentence; identical sentences are spoken once. New speech interrupts old.
- Approaching and Unknown always override Clear: a side going clear restates the other side's car or problem, and the vibration follows the most urgent state spoken (car > problem > no cars).
- All user-facing text in `Strings.swift`, e.g. "No cars seen left", "Car right, about 4 seconds", "Left camera covered". Never "safe", "go", "cross now", "clear to cross" or "all clear". (The banned-words test is deferred by decision on 2026-10-08.)
- The tone must work on the speaker and on bone-conduction headphones. Check on device that speech never talks over VoiceOver.
- Test: each state change gives the right vibration and text; no change gives nothing; not level gives only the tone.
