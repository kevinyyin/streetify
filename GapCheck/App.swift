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
        // Only the background stops the cameras; .inactive (Control Center, a notification pull) keeps them running.
        .onChange(of: scenePhase) { _, new in
            if new == .background { model.pause() }
            if new == .active { model.resume() }
        }
    }
}
