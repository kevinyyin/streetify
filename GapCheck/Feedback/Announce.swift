import Foundation

enum HapticKind: Equatable {
    case approaching, clear, unknown, ready
}

/// Which news may cut in on which: a car beats a problem beats "no cars".
enum SpeechPriority: Int, Comparable {
    case noCars, problem, car
    static func < (a: SpeechPriority, b: SpeechPriority) -> Bool { a.rawValue < b.rawValue }
}

/// One sentence about one side (nil = both sides, e.g. the status the user asked for).
struct Utterance: Equatable {
    let side: Side?
    let text: String
    let priority: SpeechPriority
}

/// How urgent a state is; also picks the banner color on screen (red, amber, gray).
func priority(of state: DirectionState) -> SpeechPriority {
    switch state {
    case .approaching: return .car
    case .unknown: return .problem
    case .clear: return .noCars
    }
}

func utterance(_ side: Side, _ state: DirectionState) -> Utterance {
    Utterance(side: side, text: Strings.sentence(side, state), priority: priority(of: state))
}

struct FeedbackEvent: Equatable {
    let haptic: HapticKind
    /// Cars first, then problems, then "no cars"; the speech queue plays them one at a time.
    let utterances: [Utterance]
    var text: String { utterances.map(\.text).joined(separator: ". ") }
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

/// Timed → far is silent (a far car hovering at the window edge). After a close warning, a time within
/// `Config.newCarJumpSeconds` of it is the same car wobbling (silent); a bigger jump, or "far", is the next car.
private func isChange(from previous: DirectionState?, to current: DirectionState) -> Bool {
    let from = previous.map(Spoken.init), to = Spoken(current)
    guard from != to else { return false }
    if from == .timed && to == .far { return false }
    // ponytail: "big jump = new car" heuristic; carry track ids in the state if two cars close together blur.
    if from == .close, to == .timed, case .approaching(.seconds(let was))? = previous,
       case .approaching(.seconds(let now)) = current, Double(now - was) <= Config.newCarJumpSeconds { return false }
    return true
}

/// What `previous` becomes once `announce` has run: sides whose change was spoken take their new state;
/// the rest keep what was last spoken, so an unspoken timed → far → timed stays silent.
func announcedBaseline(previous: [Side: DirectionState], current: [Side: DirectionState]) -> [Side: DirectionState] {
    var baseline = previous
    for (side, state) in current where isChange(from: previous[side], to: state) { baseline[side] = state }
    return baseline
}

/// One sentence per side that changed (cars first) and one vibration for the whole situation, or nil.
func announce(previous: [Side: DirectionState], current: [Side: DirectionState]) -> FeedbackEvent? {
    // Not level is the tone's job: never spoken (the baseline still records it, so leveling out is announced).
    let changed = [Side.left, .right].compactMap { side -> Utterance? in
        guard let now = current[side], now != .unknown(.notLevel), isChange(from: previous[side], to: now) else { return nil }
        return utterance(side, now)
    }
    guard !changed.isEmpty else { return nil }
    let states = current.values
    // The "no cars" hum only when no side has a car or a problem.
    let haptic: HapticKind = states.contains(where: { if case .approaching = $0 { true } else { false } }) ? .approaching
        : states.contains(where: { if case .unknown = $0 { $0 != .unknown(.notLevel) } else { false } }) ? .unknown
        : .clear
    let ordered = [SpeechPriority.car, .problem, .noCars].flatMap { p in changed.filter { $0.priority == p } }
    return FeedbackEvent(haptic: haptic, utterances: ordered)
}

/// After startup, a side still in its initial stale state was never announced (it started that way).
/// Forgetting it makes the next announcement say so, instead of leaving that side silent forever.
func baselineAfterStartup(_ lastAnnounced: [Side: DirectionState]) -> [Side: DirectionState] {
    lastAnnounced.filter { $0.value != .unknown(.stale) }
}

struct ToneSettings: Equatable {
    let isOn: Bool
    let frequencyHz: Double
}

/// The tone means only "the phone isn't level": on while tilted, pitch rising toward level; silent when level.
func toneSettings(isLevel: Bool, tiltErrorDegrees: Double) -> ToneSettings {
    guard !isLevel else { return ToneSettings(isOn: false, frequencyHz: 0) }
    let closeness = 1 - min(tiltErrorDegrees, Config.aimMaxErrorDegrees) / Config.aimMaxErrorDegrees
    return ToneSettings(isOn: true, frequencyHz: Config.aimMinHz + (Config.aimMaxHz - Config.aimMinHz) * closeness)
}
