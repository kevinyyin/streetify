import SwiftUI
import UniformTypeIdentifiers

/// The one screen: both camera views with boxes, a state line per side, and replay buttons. For sighted judges.
struct ContentView: View {
    let model: AppModel
    @State private var isImporting = false
    @State private var importSide: Side = .right

    var body: some View {
        VStack(spacing: 12) {
            pane(.left)
            pane(.right)
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
        let name = side == .left ? "Left" : "Right"
        return VStack(alignment: .leading, spacing: 6) {
            Group {
                if let image = p.image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .overlay { Canvas { ctx, size in drawBoxes(p.detections, in: ctx, size: size) } }
                } else {
                    Text("No feed")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(name) camera view, \(p.detections.count) vehicles")

            HStack {
                Text("\(name): \(p.detections.count) vehicles")
                    .accessibilityLabel("\(name): \(p.detections.count) vehicles")
                Spacer()
                Button("Replay \(name.lowercased())…") {
                    importSide = side
                    isImporting = true
                }
                .accessibilityLabel("Replay \(name.lowercased()) clip")
            }
            .font(.body)
        }
    }

    private func drawBoxes(_ detections: [Detection], in ctx: GraphicsContext, size: CGSize) {
        for d in detections {
            // Vision boxes have their origin bottom-left.
            let rect = CGRect(x: d.box.minX * size.width, y: (1 - d.box.maxY) * size.height,
                              width: d.box.width * size.width, height: d.box.height * size.height)
            ctx.stroke(Path(rect), with: .color(.yellow), lineWidth: 2)
        }
    }
}
