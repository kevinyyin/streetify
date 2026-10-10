import CoreHaptics

/// The five distinct patterns. Silent on hardware without haptics.
final class Haptics {
    private let engine: CHHapticEngine?

    init() {
        engine = CHHapticEngine.capabilitiesForHardware().supportsHaptics ? try? CHHapticEngine() : nil
        engine?.isAutoShutdownEnabled = true
    }

    func play(_ kind: HapticKind) {
        guard let engine, let pattern = try? CHHapticPattern(events: events(kind), parameters: []) else { return }
        try? engine.start()
        try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }

    private func events(_ kind: HapticKind) -> [CHHapticEvent] {
        func tap(at t: Double, intensity: Float, sharpness: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ], relativeTime: t)
        }
        switch kind {
        case .approaching: // three sharp taps
            return [0, 0.12, 0.24].map { tap(at: $0, intensity: 1, sharpness: 1) }
        case .unknown: // two medium taps
            return [0, 0.2].map { tap(at: $0, intensity: 0.7, sharpness: 0.5) }
        case .clear: // one soft hum
            return [CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.4),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1),
            ], relativeTime: 0, duration: 0.4)]
        case .ready: // one crisp tap
            return [tap(at: 0, intensity: 0.8, sharpness: 0.9)]
        case .heartbeat: // one faint, dull tap
            return [tap(at: 0, intensity: 0.35, sharpness: 0.2)]
        }
    }
}
