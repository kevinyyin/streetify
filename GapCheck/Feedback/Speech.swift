import AVFoundation
import UIKit

/// Speaks a sentence, cutting off the previous one. With VoiceOver on, VoiceOver speaks it, so the two never overlap.
/// Not verified on device.
final class Speech {
    private let synthesizer = AVSpeechSynthesizer()

    func say(_ text: String) {
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
