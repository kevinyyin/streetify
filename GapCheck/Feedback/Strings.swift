/// Every user-facing sentence. Report only what is seen: never "safe", "go", "cross now", "clear to cross", "all clear".
enum Strings {
    static func sentence(_ side: Side, _ state: DirectionState) -> String {
        let name = side == .left ? "left" : "right"
        let camera = side == .left ? "Left camera" : "Right camera"
        switch state {
        case .clear: return "No cars seen \(name)"
        case .approaching(let seconds?): return "Car \(name), about \(seconds) \(seconds == 1 ? "second" : "seconds")"
        case .approaching(nil): return "Car \(name), far"
        case .unknown(.stale): return "\(camera) stopped"
        case .unknown(.notLevel): return "Hold the phone level"
        case .unknown(.tooDark): return "\(camera) too dark"
        case .unknown(.tooBright): return "\(camera) too bright"
        case .unknown(.covered): return "\(camera) covered"
        case .unknown(.viewBlocked): return side == .left ? "Left view blocked" : "Right view blocked"
        }
    }
}
