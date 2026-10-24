import SwiftUI

// V1(이전안, 비교용 보존) I01~I05, I08: 카드 중심 대화 홈.
struct CardHomeView: View {
    @ObservedObject var controller: InterpreterController
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            LanguageBar(controller: controller)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            if let err = controller.connectionError {
                ErrorBanner(message: err) { controller.retryConnection() }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
            }
            conversation
            SpeakerDock(controller: controller)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsSheet(controller: controller)
                .presentationDetents([.large])
                .presentationCornerRadius(24)
        }
    }

    private var header: some View {
        HStack {
            Text("NUA").font(.noto(24, .bold)).foregroundStyle(Theme.text)
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 44, height: 44)
                    .background(Theme.surfaceRaised, in: Circle())
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            }
            .accessibilityLabel("Settings")
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var conversation: some View {
        if controller.turns.isEmpty {
            EmptyStateView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(controller.turns) { turn in
                            TurnCard(turn: turn,
                                     isPlaying: controller.playingTurnID == turn.id,
                                     level: controller.level,
                                     showLatency: controller.showLatency,
                                     onReplay: { controller.replay(turn.id) },
                                     onRetry: { controller.retry(turn.id) },
                                     onCopy: { controller.copy(turn.id) },
                                     onStop: { controller.stopPlayback() })
                                .id(turn.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: controller.turns.last?.id) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: controller.turns.last?.targetText) { _, _ in
                    if let id = controller.turns.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }
}

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 88, height: 88)
                .background(Theme.badge, in: Circle())
            Text("Tap a button and speak.\nNUA says it in the other language.")
                .font(.noto(20, .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.text)
            Text("When you're done, tap the same button again.\nThe interpretation plays from this iPhone.")
                .font(.noto(14, .regular))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textSecondary)
                .lineSpacing(3)
        }
        .padding(.horizontal, 32)
    }
}

struct ErrorBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("Can't reach the interpretation server").font(.noto(14, .bold)).foregroundStyle(Theme.text)
                Text(message).font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .font(.noto(13, .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Theme.accent, in: Capsule())
        }
        .padding(14)
        .background(Theme.badge, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}
