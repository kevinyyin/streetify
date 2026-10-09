import SwiftUI
import UniformTypeIdentifiers

/// The one screen. Sighted judges see both camera views with boxes and a state line per side; VoiceOver hears
/// one status item. Tapping it speaks the status again. Replay buttons sit below for testers.
struct ContentView: View {
    let model: AppModel
    @State private var isImporting = false
    @State private var importSide: Side = .right

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 12) {
                pane(.left)
                pane(.right)
            }
            .contentShape(Rectangle())
            .onTapGesture { model.speakStatus() }
            // For VoiceOver the camera views, boxes and state lines are one item: the status sentence.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Strings.status(model.panes.mapValues(\.state)))
            .accessibilityHint("Double-tap to hear it again")
            .accessibilityAction { model.speakStatus() }

            HStack {
                replayButton(.left)
                Spacer()
                replayButton(.right)
            }
            .font(.body)
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

    private func pane(_ side: Side) -> some View {
        let p = model.panes[side] ?? AppModel.Pane()
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = p.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .overlay { Canvas { ctx, size in drawTracks(p.tracks, atSeconds: p.timestampSeconds, in: ctx, size: size) } }
                } else {
                    Text("No feed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Text(Strings.sentence(side, p.state))
                .font(.body)
        }
    }

    private func replayButton(_ side: Side) -> some View {
        let name = side == .left ? "left" : "right"
        return Button("Replay \(name)…") {
            importSide = side
            isImporting = true
        }
        .accessibilityLabel("Replay \(name) clip")
    }

    /// Each track's box, id and time to arrival ("new" while too new to measure, "-" when not closing).
    private func drawTracks(_ tracks: [Track], atSeconds t: Double, in ctx: GraphicsContext, size: CGSize) {
        for track in tracks {
            // Vision boxes have their origin bottom-left.
            let rect = CGRect(x: track.box.minX * size.width, y: (1 - track.box.maxY) * size.height,
                              width: track.box.width * size.width, height: track.box.height * size.height)
            ctx.stroke(Path(rect), with: .color(.yellow), lineWidth: 2)
            let e = track.estimate(atSeconds: t)
            let time = e.isTooNew ? "new" : e.pointSeconds.map { String(format: "%.1f s", $0) } ?? "-"
            ctx.draw(Text("\(track.id)  \(time)").font(.caption).foregroundStyle(.yellow),
                     at: CGPoint(x: rect.minX, y: rect.minY - 2), anchor: .bottomLeading)
        }
    }
}
