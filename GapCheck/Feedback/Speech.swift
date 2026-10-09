import AVFoundation
import UIKit

/// One sentence at a time. More urgent news cuts in (a car beats a problem beats "no cars"), and so does newer news
/// about the side being spoken; anything else waits, newest per side. A sentence a car cut off is said again after.
struct SpeechQueue {
    private var speaking: (utterance: Utterance, startedSeconds: Double)?
    private var pending: [Utterance] = [] // at most one per side, oldest first

    /// Adds sentences; returns the one to start now (cutting off the current one), or nil to keep waiting.
    mutating func add(_ utterances: [Utterance], atSeconds now: Double) -> Utterance? {
        if let s = speaking, now - s.startedSeconds > Config.maxUtteranceSeconds { speaking = nil } // never told it finished
        for u in utterances {
            pending.removeAll { u.side == nil || $0.side == nil || $0.side == u.side }
            pending.append(u)
        }
        guard let next = nextPending() else { return nil }
        if let s = speaking {
            let cutsIn = next.priority > s.utterance.priority || next.side == s.utterance.side || next.side == nil
            guard cutsIn else { return nil }
            if next.side != nil, let side = s.utterance.side, side != next.side, !pending.contains(where: { $0.side == side }) {
                pending.append(s.utterance) // said again after the more urgent news
            }
        }
        return start(next, atSeconds: now)
    }

    /// The sentence `text` finished; returns the next one to start, if any. A late "finished" for a sentence that
    /// was cut off is ignored.
    mutating func finished(text: String, atSeconds now: Double) -> Utterance? {
        guard speaking?.utterance.text == text else { return nil }
        speaking = nil
        return nextPending().map { start($0, atSeconds: now) }
    }

    private func nextPending() -> Utterance? {
        guard let top = pending.map(\.priority).max() else { return nil }
        return pending.first { $0.priority == top }
    }

    private mutating func start(_ u: Utterance, atSeconds now: Double) -> Utterance {
        pending.removeAll { $0 == u }
        speaking = (u, now)
        return u
    }
}

/// Plays the queue. With VoiceOver on, VoiceOver speaks, so there is never a second voice. Not verified on device.
final class Speech: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var queue = SpeechQueue()

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
        if let next = queue.add(utterances, atSeconds: CACurrentMediaTime()) { speak(next.text) }
    }

    /// Lets the 4 s safety net move on if a "finished" never arrives; call regularly on main.
    func poll() { say([]) }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let text = utterance.speechString
        DispatchQueue.main.async { self.finished(text) }
    }

    private func finished(_ text: String?) {
        guard let text, let next = queue.finished(text: text, atSeconds: CACurrentMediaTime()) else { return }
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
