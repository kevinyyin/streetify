import Foundation

enum HapticKind: Equatable {
    case approaching, clear, unknown, ready
}

struct FeedbackEvent: Equatable {
    let haptic: HapticKind
    let text: String
}

/// What speech cares about. There is no live countdown: a car's time is spoken when first measured and once more
/// when it gets close (`Config.closeWarningSeconds`).
private enum Spoken: Equatable {
    case clear, far, unmeasured, timed, close, unknown(UnknownReason)

    init(_ state: DirectionState) {
        switch state {
        case .clear: self = .clear
        case .approaching(.far): self = .far
        case .approaching(.unmeasured): self = .unmeasured
        case .approaching(.seconds(let s)): self = Double(s) <= Config.closeWarningSeconds ? .close : .timed
        case .unknown(let reason): self = .unknown(reason)
        }
    }
}

/// Moving away from the car (close → timed, timed → far, close → far) is silent, so an estimate wobbling around
/// a boundary doesn't repeat itself.
private func isChange(from previous: DirectionState?, to current: DirectionState) -> Bool {
    let from = previous.map(Spoken.init), to = Spoken(current)
    let silent: [(Spoken, Spoken)] = [(.timed, .far), (.close, .timed), (.close, .far)]
    return from != to && !silent.contains { $0.0 == from && $0.1 == to }
}

/// What `previous` becomes once `announce` has run: sides whose change was spoken take their new state;
/// the rest keep what was last spoken, so an unspoken timed → far → timed stays silent.
func announcedBaseline(previous: [Side: DirectionState], current: [Side: DirectionState]) -> [Side: DirectionState] {
    var baseline = previous
    for (side, state) in current where isChange(from: previous[side], to: state) { baseline[side] = state }
    return baseline
}

/// One haptic and one sentence for whatever changed, or nil when nothing did.
func announce(previous: [Side: DirectionState], current: [Side: DirectionState]) -> FeedbackEvent? {
    // Not level is the tone's job: never spoken (the baseline still records it, so leveling out is announced).
    let changed = [Side.left, .right].compactMap { side -> (Side, DirectionState)? in
        guard let now = current[side], now != .unknown(.notLevel), isChange(from: previous[side], to: now) else { return nil }
        return (side, now)
    }
    guard !changed.isEmpty else { return nil }
    var spoken = changed
    // Approaching and Unknown override Clear: "No cars seen left" must not replace a warning about the right.
    if changed.contains(where: { $0.1 == .clear }) {
        spoken += [Side.left, .right].compactMap { side in
            guard !changed.contains(where: { $0.0 == side }), let now = current[side], now != .clear, now != .unknown(.notLevel)
            else { return nil }
            return (side, now)
        }
    }
    var sentences: [String] = []
    for (side, state) in spoken {
        let s = Strings.sentence(side, state)
        if !sentences.contains(s) { sentences.append(s) }
    }
    let states = spoken.map(\.1)
    let haptic: HapticKind = states.contains(where: { if case .approaching = $0 { true } else { false } }) ? .approaching
        : states.contains(where: { if case .unknown = $0 { true } else { false } }) ? .unknown
        : .clear
    return FeedbackEvent(haptic: haptic, text: sentences.joined(separator: ". "))
}

/// After startup, a side still in its initial stale state was never announced (it started that way).
/// Forgetting it makes the next announcement say so, instead of leaving that side silent forever.
func baselineAfterStartup(_ lastAnnounced: [Side: DirectionState]) -> [Side: DirectionState] {
    lastAnnounced.filter { $0.value != .unknown(.stale) }
}

struct ToneSettings: Equatable {
    let isOn: Bool
    let frequencyHz: Double
    /// -1 left ... 1 right.
    let pan: Float
}

/// Aiming until level (pitch rises toward level), then a tone toward the nearest car (pitch rises as it nears), else silent.
func toneSettings(states: [Side: DirectionState], isLevel: Bool, tiltErrorDegrees: Double) -> ToneSettings {
    if !isLevel {
        let closeness = 1 - min(tiltErrorDegrees, Config.aimMaxErrorDegrees) / Config.aimMaxErrorDegrees
        return ToneSettings(isOn: true, frequencyHz: Config.aimMinHz + (Config.aimMaxHz - Config.aimMinHz) * closeness, pan: 0)
    }
    let cars = states.compactMap { side, state -> (side: Side, seconds: Double)? in
        guard case .approaching(let arrival) = state else { return nil }
        switch arrival {
        case .seconds(let s): return (side, min(Double(s), Config.approachWindowSeconds))
        case .far: return (side, Config.approachWindowSeconds)
        case .unmeasured: return (side, Config.approachWindowSeconds / 2) // distance unknown: mid pitch, not the "far" pitch
        }
    }
    guard let nearest = cars.min(by: { $0.seconds < $1.seconds }) else { return ToneSettings(isOn: false, frequencyHz: 0, pan: 0) }
    let closeness = 1 - nearest.seconds / Config.approachWindowSeconds
    return ToneSettings(isOn: true, frequencyHz: Config.approachMinHz + (Config.approachMaxHz - Config.approachMinHz) * closeness,
                        pan: nearest.side == .left ? -1 : 1)
}
