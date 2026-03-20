import SwiftUI
import RealityKit

@main
struct ShrimpXRApp: App {
    @StateObject private var session = SessionManager()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ShrimpAnimationSystem.registerSystem()
        ShrimpComponent.registerComponent()
        BubblePositionComponent.registerComponent()
    }

    var body: some SwiftUI.Scene {
        WindowGroup {
            ControlPanelView()
                .environmentObject(session)
        }

        ImmersiveSpace(id: "ShrimpSpace") {
            ShrimpImmersiveView()
                .environmentObject(session)
        }
        .immersionStyle(selection: .constant(.mixed), in: .mixed)
    }
}
