import AVFoundation
import UIKit

/// One sentence at a time. Only more urgent news cuts in (a car beats a problem beats "no cars"); everything else
/// waits, newest per side. A waiting sentence is rebuilt from its side's state when its turn comes, so a car that
/// has already passed is never announced late: the user hears what is true now, or nothing if that was just said.
struct SpeechQueue {
    private var speaking: (utterance: Utterance, startedSeconds: Double)?
    private var pending: [Utterance] = [] // at most one per side, oldest first
    private var lastSaid: [Side: String] = [:]

    /// Adds sentences; returns the one to start now (cutting off the current one), or nil to keep waiting.
    /// `current` is each side's state now; sides missing from it are spoken as queued.
    mutating func add(_ utterances: [Utterance], atSeconds now: Double, current: [Side: DirectionState] = [:]) -> Utterance? {
        if let s = speaking, now - s.startedSeconds > Config.maxUtteranceSeconds { speaking = nil } // never told it finished
        for u in utterances {
            pending.removeAll { u.side == nil || $0.side == nil || $0.side == u.side }
            pending.append(u)
        }
        if let s = speaking {
            guard let next = nextPending(), next.priority > s.utterance.priority || next.side == nil else { return nil }
            pending.removeAll { $0 == next }
            guard let started = start(next, atSeconds: now, current: current) else { return nil }
            if let side = s.utterance.side, side != started.side {
                lastSaid[side] = nil // cut off, so not heard
                if started.side != nil, !pending.contains(where: { $0.side == side }) {
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

    private func nextPending() -> Utterance? {
        guard let top = pending.map(\.priority).max() else { return nil }
        return pending.first { $0.priority == top }
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
        return u
    }
}

/// Plays the queue. With VoiceOver on, VoiceOver speaks, so there is never a second voice. Not verified on device.
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue = SpeechQueue()
    /// Each side's state now, so a sentence that waited is said as it is now (or dropped).
    var currentStates: () -> [Side: DirectionState] = { [:] }

    override init() {
        super.init()
        synthesizer.delegate = self
        NotificationCenter.default.addObserver(forName: UIAccessibility.announcementDidFinishNotification,
                                               object: nil, queue: .main) { [weak self] note in
            self?.finished(note.userInfo?[UIAccessibility.announcementStringValueUserInfoKey] as? String)
        }
    }

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

    /// Cuts off whatever is playing.
    private func speak(_ text: String) {
        if UIAccessibility.isVoiceOverRunning {
            let announcement = NSAttributedString(string: text, attributes: [
                .accessibilitySpeechAnnouncementPriority: UIAccessibilityPriority.high,
            ])
            UIAccessibility.post(notification: .announcement, argument: announcement)
        } else {
            synthesizer.stopSpeaking(at: .immediate)
            synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }
}
