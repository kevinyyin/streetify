import AVFoundation
import UIKit

/// One sentence at a time. Only more urgent news cuts in (a car beats a problem beats "no cars"); everything else
/// waits, newest per side. A waiting sentence is rebuilt from its side's state when its turn comes, so a car that
/// has already passed is never announced late: the user hears what is true now, or nothing if that was just said.
struct SpeechQueue {
    private var speaking: (utterance: Utterance, startedSeconds: Double)?
    /// A sentence started and not reported finished (nor given up on); the tone waits while this is true.
    var isSpeaking: Bool { speaking != nil }
    private var pending: [Utterance] = [] // at most one per side, oldest first
    private var lastSaid: [Side: String] = [:]

    /// Adds sentences; returns the one to start now (cutting off the current one), or nil to keep waiting.
    /// `current` is each side's state now; sides missing from it are spoken as queued.
    mutating func add(_ utterances: [Utterance], atSeconds now: Double, current: [Side: DirectionState] = [:]) -> Utterance? {
        if let s = speaking, now - s.startedSeconds > Config.maxUtteranceSeconds { speaking = nil } // never told it finished
        for u in utterances {
            pending.removeAll { u.replacesQueue || $0.replacesQueue || $0.side == u.side }
            pending.append(u)
        }
        if let s = speaking {
            guard let next = nextPending(), next.priority > s.utterance.priority || next.side == nil else { return nil }
            pending.removeAll { $0 == next }
            guard let started = start(next, atSeconds: now, current: current) else { return nil }
            if let side = s.utterance.side, side != started.side {
                lastSaid[side] = nil // cut off, so not heard
                if !started.replacesQueue, !pending.contains(where: { $0.side == side }) {
                    pending.append(s.utterance) // said again after the more urgent news, as it is by then
                }
            }
            return started
        }
        return startNext(atSeconds: now, current: current)
    }

    /// The sentence `text` finished; returns the next one to start, if any. A late "finished" for a sentence that
    /// was cut off is ignored.
    mutating func finished(text: String, atSeconds now: Double, current: [Side: DirectionState] = [:]) -> Utterance? {
        guard speaking?.utterance.text == text else { return nil }
        speaking = nil
        return startNext(atSeconds: now, current: current)
    }

    /// The most urgent waiting sentence; on a tie, what the user asked for (no side) goes first.
    private func nextPending() -> Utterance? {
        guard let top = pending.map(\.priority).max() else { return nil }
        return pending.first { $0.priority == top && $0.side == nil } ?? pending.first { $0.priority == top }
    }

    /// Starts the most urgent waiting sentence that is still news, dropping the ones that no longer are.
    private mutating func startNext(atSeconds now: Double, current: [Side: DirectionState]) -> Utterance? {
        while let next = nextPending() {
            pending.removeAll { $0 == next }
            if let started = start(next, atSeconds: now, current: current) { return started }
        }
        return nil
    }

    /// Rebuilds a side's sentence from its state now; nil (nothing started) if that is not news any more.
    private mutating func start(_ queued: Utterance, atSeconds now: Double, current: [Side: DirectionState]) -> Utterance? {
        var u = queued
        if let side = u.side, let state = current[side] {
            guard state != .unknown(.notLevel) else { return nil } // not level is the tone's job
            u = utterance(side, state)
            // A sentence that changed while waiting is dropped if it became what that side last said. One sent as it
            // is (like the state after leveling out, which is always announced) is said even if it repeats.
            guard u.text == queued.text || lastSaid[side] != u.text else { return nil }
        }
        if let side = u.side { lastSaid[side] = u.text } else { lastSaid = [:] }
        speaking = (u, now)
        // Phone-wide news ("Phone too hot") is the same sentence for both sides: said once. Compared after the
        // rebuild, so a side that has moved on still gets its own sentence.
        pending.removeAll { $0.text == u.text }
        return u
    }
}

/// What picking a voice needs from an installed one.
struct VoiceInfo {
    let identifier: String
    let language: String
    let quality: AVSpeechSynthesisVoiceQuality
    let isNovelty: Bool
    let isPersonal: Bool
}

/// The best installed voice for `language`: premium, then enhanced, then the basic default; never a novelty voice or
/// the user's Personal Voice. Nil when none is installed for the language (the system then picks).
func bestVoice(_ voices: [VoiceInfo], language: String) -> VoiceInfo? {
    voices.filter { $0.language == language && !$0.isNovelty && !$0.isPersonal }.max { $0.quality.rawValue < $1.quality.rawValue }
}

/// Plays the queue. With VoiceOver on, VoiceOver speaks, so there is never a second voice. Not verified on device.
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue = SpeechQueue()
    /// The best installed voice (the basic one sounds synthetic); apps can't download better ones, only the user can.
    private var voice: AVSpeechSynthesisVoice?
    /// Only the basic voice is installed for the language: the first launch tells the user where to get a better one.
    private(set) var hasOnlyBasicVoice = true
    /// Each side's state now, so a sentence that waited is said as it is now (or dropped).
    var currentStates: () -> [Side: DirectionState] = { [:] }

    override init() {
        super.init()
        synthesizer.delegate = self
        pickVoice()
        NotificationCenter.default.addObserver(forName: AVSpeechSynthesizer.availableVoicesDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.pickVoice() }
        NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification,
                                               object: nil, queue: .main) { [weak self] note in
            self?.finished(note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String)
        }
    }

    /// A sentence is playing; the tone pauses for it.
    var isSpeaking: Bool { queue.isSpeaking }

    /// Queues sentences; call on main.
    func say(_ utterances: [Utterance]) {
        if let next = queue.add(utterances, atSeconds: CACurrentMediaTime(), current: currentStates()) { speak(next.text) }
    }

    /// Lets the 4 s safety net move on if a "finished" never arrives; call regularly on main.
    func poll() { say([]) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        DispatchQueue.main.async { self.finished(text) }
    }

    private func finished(_ text: String?) {
        guard let text, let next = queue.finished(text: text, atSeconds: CACurrentMediaTime(), current: currentStates()) else { return }
        speak(next.text)
    }

    private func pickVoice() {
        let installed = AVSpeechSynthesisVoice.speechVoices().map {
            VoiceInfo(identifier: $0.identifier, language: $0.language, quality: $0.quality,
                      isNovelty: $0.voiceTraits.contains(.isNoveltyVoice), isPersonal: $0.voiceTraits.contains(.isPersonalVoice))
        }
        let best = bestVoice(installed, language: AVSpeechSynthesisVoice.currentLanguageCode())
        voice = best.flatMap { AVSpeechSynthesisVoice(identifier: $0.identifier) }
        hasOnlyBasicVoice = (best?.quality ?? .default) == .default
    }

    /// Cuts off whatever is playing.
    private func speak(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            let announcement = NSAttributedString(string: text, attributes: [
                .accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high,
            ])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        } else {
            synthesizer.stopSpeaking(at: .immediate)
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice // nil: the system's default
            utterance.prefersAssistiveTechnologySettings = true // the user's own speech settings win when they have them
            synthesizer.speak(utterance)
        }
    }
}
