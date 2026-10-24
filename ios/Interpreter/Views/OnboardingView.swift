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
            Text("NUA 누아\n말투까지 옮기는 통역").font(.noto(28, .bold)).foregroundStyle(Theme.text)
            Text("한국어와 영어로 마주 보고 대화하세요.\n말한 사람의 의도와 감정을 최대한 살려\n상대 언어 음성으로 들려드려요.")
                .font(.noto(15, .medium))
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(4)
            VStack(alignment: .leading, spacing: 12) {
                bullet("mic.fill", "말할 사람이 자기 언어 버튼을 누르고 말해요")
                bullet("speaker.wave.2.fill", "말이 끝나면 상대 언어로 바로 재생돼요")
                bullet("checkmark.shield.fill", "음성·대화는 기기에 저장하지 않아요")
            }
            .padding(.top, 8)
            Spacer()
            Button(action: onStart) {
                Text("시작하기")
                    .font(.noto(17, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
            Text("마이크 권한을 요청해요")
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
            Text("마이크 권한이 필요해요").font(.noto(22, .bold)).foregroundStyle(Theme.text)
            Text("통역하려면 말소리를 들어야 해요.\n설정 > 앱 > 이 앱 > 마이크를 켜 주세요.")
                .font(.noto(15, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("설정 열기")
                    .font(.noto(17, .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
            Button("다시 확인") { Task { await controller.recheckMic() } }
                .font(.noto(15, .bold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
    }
}
