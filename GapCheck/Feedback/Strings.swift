/// Every user-facing sentence. Report only what is seen: never "safe", "go", "cross now", "clear to cross", "all clear".
enum Strings {
    static func sentence(_ side: Side, _ state: DirectionState) -> String {
        let name = side == .left ? "Left" : "Right" // side first, so the direction is heard before the news
        switch state {
        case .clear: return "\(name): no cars"
        case .approaching(.seconds(let seconds)): return "\(name): car, \(seconds) \(seconds == 1 ? "second" : "seconds")"
        case .approaching(.far): return "\(name): car, far"
        case .approaching(.unmeasured): return "\(name): car"
        case .unknown(.stale): return "\(name): camera stopped"
        case .unknown(.notLevel): return "Hold the phone level"
        case .unknown(.tooDark): return "\(name): too dark"
        case .unknown(.tooBright): return "\(name): too bright"
        case .unknown(.covered): return "\(name): camera covered"
        case .unknown(.viewBlocked): return "\(name): blocked"
        }
    }

    /// The big words on a side's banner on screen.
    static func label(_ state: DirectionState) -> String {
        switch state {
        case .clear: return "No cars"
        case .approaching(.seconds(let seconds)): return "Car · \(seconds) s"
        case .approaching(.far): return "Car · far"
        case .approaching(.unmeasured): return "Car"
        case .unknown(.stale): return "Camera stopped"
        case .unknown(.notLevel): return "Hold level"
        case .unknown(.tooDark): return "Too dark"
        case .unknown(.tooBright): return "Too bright"
        case .unknown(.covered): return "Camera covered"
        case .unknown(.viewBlocked): return "Blocked"
        }
    }

    /// Both directions in one sentence, left first: what the screen reads to VoiceOver and what a tap speaks.
    static func status(_ states: [Side: DirectionState]) -> String {
        var sentences: [String] = []
        for side in [Side.left, .right] {
            if let s = states[side].map({ sentence(side, $0) }), !sentences.contains(s) { sentences.append(s) }
        }
        return sentences.joined(separator: ". ")
    }
}
