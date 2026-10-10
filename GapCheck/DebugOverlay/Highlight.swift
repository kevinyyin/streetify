import SwiftUI

/// How the screen tints a car. Display only; the warnings come from Decide.
enum TrackHighlight: Equatable {
    /// Close, or in or behind a close line of cars (see `redTrackIds`).
    case danger
    /// Coming toward us but not soon, stopped, too new to measure, or too far to tell.
    case facing
    /// Getting smaller over the direction window: driving away.
    case away

    var color: Color {
        switch self {
        case .danger: .red
        case .facing: .yellow
        case .away: .white // not green: green reads as "go"
        }
    }
}

func highlight(_ track: Track, isRed: Bool) -> TrackHighlight {
    isRed ? .danger : track.isDrivingAway ? .away : .facing
}

/// Which cars are red this frame, given which were red last frame. Closest (tallest) first:
/// - a car surely coming toward us and arriving within `Config.dangerHighlightSeconds` turns red;
/// - a red car stays red until it leaves the picture (its track ends), or comes to a standstill (or surely drives away)
///   with no red car in front of it in its line;
/// - a car surely coming toward us behind a red car in its line is red too, so a line of cars reads as one danger.
/// Directions come from the 4 s window, so one jittery frame can't turn a parked car red.
func redTrackIds(_ tracks: [Track], atSeconds t: Double, wasRed: Set<Int>) -> Set<Int> {
    var red: [Track] = []
    for track in tracks.sorted(by: { $0.box.height > $1.box.height }) {
        let travel = track.travel
        let isClose = travel == .toward && (track.estimate(atSeconds: t).pointSeconds.map { $0 <= Config.dangerHighlightSeconds } ?? false)
        let redInFront = red.contains { isInLine(behind: track, front: $0) }
        let released = (track.isStill || travel == .away) && !redInFront
        if isClose || (wasRed.contains(track.id) && !released) || (travel == .toward && redInFront) { red.append(track) }
    }
    return Set(red.map(\.id))
}

/// `front` is ahead of `behind` in the same line of cars: closer (taller) and within `Config.lineMaxGapBoxWidths`
/// sideways, so a parked car at the curb isn't "behind" a car passing in the road.
func isInLine(behind: Track, front: Track) -> Bool {
    front.box.height > behind.box.height
        && abs(front.box.midX - behind.box.midX) <= Config.lineMaxGapBoxWidths * max(front.box.width, behind.box.width)
}
