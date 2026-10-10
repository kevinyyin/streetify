import SwiftUI

@main
struct GapCheckApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true // a locked screen stops the cameras
                    model.start()
                }
        }
        // Leaving the foreground (side button, call, Siri) stops the cameras: say so instead of going quiet.
        .onChange(of: scenePhase) { old, new in
            if old == .active && new != .active { model.pause() }
            if new == .active { model.resume() }
        }
    }
}
