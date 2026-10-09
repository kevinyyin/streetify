import SwiftUI

@main
struct GapCheckApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true // a locked screen stops the cameras
                    model.start()
                }
        }
    }
}
