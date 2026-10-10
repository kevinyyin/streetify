import SwiftUI
import UniformTypeIdentifiers

/// The one screen. Sighted judges see the two directions stacked (left on top), each with a colored status bar over
/// its camera; VoiceOver hears one status item. Tapping it speaks the status again. Replay buttons sit below for testers.
struct ContentView: View {
    let model: AppModel
    @State private var isImporting = false
    @State private var importSide: Side = .right

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 10) {
                levelLine
                section(.left)
                section(.right)
                if model.isPreviewOn { legend }
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
            if model.isMuted {
                Label("Volume off", systemImage: "speaker.slash").foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
    }

    /// What the outline colors mean, for sighted judges.
    private var legend: some View {
        Text("Outlines: red close, yellow coming, white leaving")
            .font(.footnote)
            .foregroundStyle(.gray)
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
                        .overlay {
                            Canvas { ctx, size in
                                drawTracks(p.tracks, masks: p.masks, redIds: p.redTrackIds, atSeconds: p.timestampSeconds,
                                           crop: p.imageCrop, in: ctx, size: size)
                            }
                        }
                        .clipped()
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

    /// Red = car, amber = problem, gray = no cars. Not green: green reads as "go" (changed 2026-10-09).
    private func statusBar(_ side: Side, _ state: DirectionState) -> some View {
        let (fill, text): (Color, Color) = switch priority(of: state) {
        case .car: (.red, .white)
        case .problem: (.orange, .black)
        case .noCars: (Color(white: 0.3), .white)
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

    /// Each car's outline tinted red (close, or in a close line of cars), yellow (facing us) or white (driving away), with its id
    /// and time to arrival ("new" while too new to measure, "-" when not closing). A car with no outline yet gets a box.
    /// Outlines matched to no track (cars not tracked yet) are drawn faint gray.
    private func drawTracks(_ tracks: [Track], masks: [SegmentMask], redIds: Set<Int>, atSeconds t: Double, crop: CGRect,
                            in ctx: GraphicsContext, size: CGSize) {
        // Vision boxes are normalized to the whole frame, origin bottom-left; the image shows only `crop` of it.
        func rect(_ box: CGRect) -> CGRect {
            CGRect(x: (box.minX - crop.minX) / crop.width * size.width, y: (crop.maxY - box.maxY) / crop.height * size.height,
                   width: box.width / crop.width * size.width, height: box.height / crop.height * size.height)
        }
        func fill(_ mask: SegmentMask, _ color: Color, opacity: Double) {
            var layer = ctx
            layer.opacity = opacity
            layer.addFilter(.colorMultiply(color))
            layer.draw(Image(decorative: mask.image, scale: 1), in: rect(mask.box))
        }
        var unused = Set(masks.indices)
        for track in tracks {
            let e = track.estimate(atSeconds: t)
            let color = highlight(track, isRed: redIds.contains(track.id)).color
            let mask = unused.filter { iou(masks[$0].box, track.box) >= 0.3 }.max { iou(masks[$0].box, track.box) < iou(masks[$1].box, track.box) }
            if let mask {
                unused.remove(mask)
                fill(masks[mask], color, opacity: 0.55)
            } else {
                ctx.stroke(Path(rect(track.box)), with: .color(color), lineWidth: 2)
            }
            let time = e.isTooNew ? "new" : e.pointSeconds.map { String(format: "%.1f s", $0) } ?? "-"
            let r = rect(track.box)
            ctx.draw(Text("\(track.id)  \(time)").font(.caption.bold()).foregroundStyle(color),
                     at: CGPoint(x: r.minX, y: r.minY - 2), anchor: .bottomLeading)
        }
        for i in unused { fill(masks[i], .gray, opacity: 0.35) }
    }
}

/// Replay swaps a live camera for a recorded clip, so it is for testers only: shown when launched with
/// `-showReplay` (the Xcode scheme passes it), never from the home screen.
func showsReplayControls(arguments: [String]) -> Bool {
    arguments.contains("-showReplay")
}

/// The camera preview and outlines cost processing the warnings could use; with VoiceOver on nobody sees them, so
/// they are off unless launched with `-showOverlay` (for a sighted judge beside a VoiceOver user).
func showsPreview(voiceOverRunning: Bool, arguments: [String]) -> Bool {
    !voiceOverRunning || arguments.contains("-showOverlay")
}

/// The part of a camera frame the screen shows, Vision-normalized: a tall (portrait) frame is cut to the centered
/// square across its full width, where the road is, dropping sky and pavement; a wide frame is shown whole.
func previewCrop(orientedWidth w: Double, orientedHeight h: Double) -> CGRect {
    guard h > w, h > 0 else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
    let height = w / h
    return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
}
