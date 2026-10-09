# Feedback

The user can't see the screen; this folder is the product for them.

- All user-facing text in `Strings.swift`, e.g. "No cars seen left", "Car right, about 4 seconds", "Left camera covered", "Hold the phone level". Never "safe", "go", "cross now", "clear to cross" or "all clear". (The banned-words test is deferred by decision on 2026-10-08.)
- A change means a change of kind, a change of Unknown reason, or far ↔ timed. The countdown is carried by tone pitch only. Output is coalesced for 0.2 s; identical sentences are spoken once. The haptic follows the most urgent state: Approaching > Unknown > Clear.
- Tone bands: aiming 200–500 Hz (rising toward level), approaching 600–1200 Hz (rising as the car nears).
- With VoiceOver on, speech is a high-priority VoiceOver announcement; otherwise AVSpeechSynthesizer. Audio session `.playback` + `.mixWithOthers`.
- Output only on a state change. Both directions changing together = one sentence. New speech interrupts old.
- Approaching and Unknown always override Clear.
- **Haptics:** distinct patterns for Approaching, Clear, Unknown and ready.
- **Tone:** aiming mode until level (then the ready haptic), approaching mode after (panned to the car's side, pitch rises as it nears). Must work on the speaker and bone-conduction headphones.
- **Speech:** check on device that it doesn't talk over VoiceOver.
- Test: each state change gives the right haptic, pan and text; no change gives nothing.
