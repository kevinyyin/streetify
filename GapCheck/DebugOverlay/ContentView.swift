import SwiftUI
import UniformTypeIdentifiers

/// The one screen. Sighted viewers see the two directions stacked (left on top), or side by side (left first) when the
/// phone is held sideways, each with a colored status bar over its camera; VoiceOver hears one status item. Tapping it
/// speaks the status again. Replay buttons sit below for testers.
struct ContentView: View {
    let model: AppModel
    /// Compact height = the phone is sideways (the hold since 2026-10-10): the two feeds go side by side.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isImporting = false
    @State private var importSide: Side = .right

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                levelLine
                let sections = verticalSizeClass == .compact ? AnyLayout(HStackLayout(spacing: 10))
                    : AnyLayout(VStackLayout(spacing: 10))
                sections {
                    section(.left)
                    section(.right)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { model.speakStatus() }
            .onLongPressGesture { model.speakHoldInstructions() }
            // For VoiceOver the whole display is one item: the status sentence.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.status(model.panes.mapValues(\.state)))
            .accessibilityHint("Double-tap to hear it again")
            .accessibilityAction { model.speakStatus() }
            .accessibilityAction(named: "How to hold the phone") { model.speakHoldInstructions() }

            if showsReplayControls(arguments: ProcessInfo.processInfo.arguments) {
                HStack {
                    replayButton(.left)
                    Spacer()
                    replayButton(.right)
                }
                .font(.body)
            }
        }
        .padding(16)
        .background(Color.black)
        .foregroundStyle(.white)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie]) { result in
            guard case .success(let url) = result else { return }
            _ = url.startAccessingSecurityScopedResource() // held for the replay's lifetime
            model.replay(url, on: importSide)
        }
    }

    private var levelLine: some View {
        HStack(spacing: 16) {
            if model.isLevel {
                Label("Level", systemImage: "checkmark.circle").foregroundStyle(.gray)
            } else {
                Text("Tilted \(Int(model.tiltErrorDegrees.rounded()))°").foregroundStyle(.orange)
            }
            Text("Motion \(String(format: "%.2f", model.motionG)) g")
                .foregroundStyle(model.motionG > Config.movingAccelerationG ? .orange : .gray)
            if model.isMuted {
                Label("Volume off", systemImage: "speaker.slash").foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    /// One direction: its status bar on top, its camera below. Left is the top section, right the bottom.
    private func section(_ side: Side) -> some View {
        let p = model.panes[side] ?? AppModel.Pane()
        return VStack(spacing: 6) {
            statusBar(side, p.state)
            Group {
                if let image = p.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .overlay { Canvas { ctx, size in drawTracks(p.tracks, masks: p.masks, redIds: p.redTrackIds, atSeconds: p.timestampSeconds, in: ctx, size: size) } }
                } else {
                    Text(!model.isPreviewOn ? "Preview off while VoiceOver is on"
                         : showsReplayControls(arguments: ProcessInfo.processInfo.arguments)
                         ? "No feed. Tap Replay \(side == .left ? "left" : "right")… to load a clip." : "No feed")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Red = car, amber = problem, green = no cars (owner's choice, 2026-10-09; the words still never say "go").
    private func statusBar(_ side: Side, _ state: DirectionState) -> some View {
        let (fill, text): (Color, Color) = switch priority(of: state) {
        case .car, .closeCar: (.red, .white)
        case .problem: (.orange, .black)
        case .noCars: (.green, .black)
        }
        return Text("\(side == .left ? "Left" : "Right") · \(Strings.label(state))")
            .font(.title3.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(fill, in: RoundedRectangle(cornerRadius: 8))
    }

    private func replayButton(_ side: Side) -> some View {
        let name = side == .left ? "left" : "right"
        return Button("Replay \(name)…") {
            importSide = side
            isImporting = true
        }
        .accessibilityLabel("Replay \(name) clip")
    }

    /// Each car's outline tinted red (close, or in a close line of cars), yellow (facing us) or green (driving away).
    /// Outlines arrive a frame or two late, so each is carried along with its car to where the car is now. A car with
    /// no outline gets a box. Red cars get their time to arrival, and cars the front/rear model sees from behind get
    /// "rear" (stage 1 shows it only here), closest first, skipping any label that would overlap one already drawn. Outlines matched to no car (people, cars not tracked yet) are drawn faint gray.
    private func drawTracks(_ tracks: [Track], masks: [SegmentMask], redIds: Set<Int>, atSeconds t: Double, in ctx: GraphicsContext, size: CGSize) {
        // Vision boxes have their origin bottom-left.
        func rect(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * size.width, y: (1 - box.maxY) * size.height, width: box.width * size.width, height: box.height * size.height)
        }
        func fill(_ mask: SegmentMask, at box: CGRect, _ color: Color, opacity: Double) {
            var layer = ctx
            layer.opacity = opacity
            layer.addFilter(.colorMultiply(color))
            layer.draw(Image(decorative: mask.image, scale: 1), in: rect(box))
        }
        var unused = Set(masks.indices)
        var labels: [CGRect] = []
        for track in tracks.sorted(by: { $0.box.height > $1.box.height }) {
            let isRed = redIds.contains(track.id)
            let color = highlight(track, isRed: isRed).color
            let then = masks.first.flatMap { track.box(atSeconds: $0.timestampSeconds) } ?? track.box
            let mask = unused.filter { iou(masks[$0].box, then) >= Config.maskMatchIoU }.max { iou(masks[$0].box, then) < iou(masks[$1].box, then) }
            if let mask {
                unused.remove(mask)
                fill(masks[mask], at: carried(masks[mask].box, from: then, to: track.box), color, opacity: 0.55)
            } else {
                ctx.stroke(Path(rect(track.box)), with: .color(color), lineWidth: 2)
            }
            guard isRed || track.isSeenFromBehind else { continue }
            let e = track.estimate(atSeconds: t)
            let time = isRed ? e.pointSeconds.map { String(format: "%.1f s", $0) } ?? "car" : nil
            let words = [time, track.isSeenFromBehind ? "rear" : nil].compactMap { $0 }.joined(separator: "  ")
            let text = ctx.resolve(Text(words).font(.caption.bold()).foregroundStyle(color))
            let r = rect(track.box), textSize = text.measure(in: size)
            let label = CGRect(x: r.minX, y: r.minY - 2 - textSize.height, width: textSize.width, height: textSize.height)
            guard !labels.contains(where: { $0.intersects(label) }) else { continue }
            labels.append(label)
            ctx.draw(text, in: label)
        }
        for i in unused { fill(masks[i], at: masks[i].box, .gray, opacity: 0.35) }
    }
}

/// Replay swaps a live camera for a recorded clip, so it is for testers only: shown when launched with
/// `-showReplay` (the Xcode scheme passes it), never from the home screen.
func showsReplayControls(arguments: [String]) -> Bool {
    arguments.contains("-showReplay")
}

/// The camera preview costs processing the warnings could use; with VoiceOver on nobody sees it, so it is off
/// unless launched with `-showOverlay` (for a sighted viewer beside a VoiceOver user).
func showsPreview(voiceOverRunning: Bool, arguments: [String]) -> Bool {
    !voiceOverRunning || arguments.contains("-showOverlay")
}
