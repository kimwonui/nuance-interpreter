import SwiftUI

@main
struct InterpreterApp: App {
    @StateObject private var controller = InterpreterController()
    /// "orb" = V2 오브 중심(기본), "card" = V1 카드 중심(이전안, 비교용)
    @AppStorage("uiVersion") private var uiVersion = "orb"
    @AppStorage("onboarded") private var onboarded = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if uiVersion == "card" {
                    if !onboarded {
                        OnboardingView { onboarded = true }
                    } else if controller.mic == .denied {
                        PermissionView(controller: controller)
                    } else {
                        CardHomeView(controller: controller)
                    }
                } else {
                    // 첫 진입부터 오브. 마이크 권한은 처음 말하기 버튼을 누를 때 요청한다.
                    OrbHomeView(controller: controller)
                }
            }
            .task { await controller.start() }
            .background(Theme.background.ignoresSafeArea())
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.suspend()
            case .active: Task { await controller.start() }
            default: break
            }
        }
    }
}
