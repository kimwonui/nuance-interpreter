import SwiftUI

/// I00 시작.
struct OnboardingView: View {
    let onStart: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 88, height: 88)
                .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: 28))
                .shadow(color: .black.opacity(0.14), radius: 18, y: 6)
            Text("NUA\nInterpretation that\nkeeps the nuance").font(.noto(28, .bold)).foregroundStyle(Theme.text)
            Text("Talk face to face in Korean and English.\nNUA carries each speaker's intent and emotion\ninto speech in the other language.")
                .font(.noto(15, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
            VStack(alignment: .leading, spacing: 12) {
                bullet("mic.fill", "Each speaker taps their language and talks")
                bullet("speaker.wave.2.fill", "The interpretation plays as soon as they finish")
                bullet("checkmark.shield.fill", "Audio and conversations aren't saved on this device")
            }
            .padding(.top, 8)
            Spacer()
            Button(action: onStart) {
                Text("Get started")
                    .font(.noto(17, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
            Text("We'll ask for microphone access")
                .font(.noto(12, .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 8)
    }

    private func bullet(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 36, height: 36)
                .background(Theme.badge, in: Circle())
            Text(text).font(.noto(14, .medium)).foregroundStyle(Theme.text)
        }
    }
}

/// I07 마이크 권한 거부.
struct PermissionView: View {
    @ObservedObject var controller: InterpreterController
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 96, height: 96)
                .background(Theme.badge, in: Circle())
            Text("Microphone access needed").font(.noto(22, .bold)).foregroundStyle(Theme.text)
            Text("NUA needs to hear speech to interpret.\nGo to Settings > Apps > NUA > Microphone.")
                .font(.noto(15, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Open Settings")
                    .font(.noto(17, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
            Button("Check again") { Task { await controller.recheckMic() } }
                .font(.noto(15, .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }
}
