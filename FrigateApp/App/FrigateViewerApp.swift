import SwiftUI

@main
struct FrigateViewerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var model: AppModel { appDelegate.model }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task { await model.reload() }
        }
        .onChange(of: scenePhase) { _, phase in
            model.playback.scenePhaseChanged(phase)
            model.scenePhaseChanged(phase)
        }
    }
}
