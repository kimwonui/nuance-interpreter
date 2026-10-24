import SwiftUI

@main
struct InterpreterApp: App {
    @StateObject private var controller = InterpreterController()
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if !onboarded {
                    OnboardingView { onboarded = true; Task { await controller.start() } }
                } else if controller.mic == .denied {
                    PermissionView(controller: controller)
                } else {
                    HomeView(controller: controller)
                        .task { await controller.start() }
                }
            }
            .background(Theme.background.ignoresSafeArea())
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.suspend()
            case .active: if onboarded { Task { await controller.start() } }
            default: break
            }
        }
    }
}
