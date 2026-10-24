import SwiftUI

/// 하단 독: 화자 버튼 두 개 + 개인정보 한 줄.
struct SpeakerDock: View {
    @ObservedObject var controller: InterpreterController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SpeakerButton(lang: controller.leftLang, state: state(for: controller.leftLang), level: controller.level) {
                    controller.tapSpeaker(controller.leftLang)
                }
                SpeakerButton(lang: controller.rightLang, state: state(for: controller.rightLang), level: controller.level) {
                    controller.tapSpeaker(controller.rightLang)
                }
            }
            Text("음성·대화는 저장하지 않아요 · 통역을 위해 OpenAI로 전송돼요")
                .font(.noto(11, .regular))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 4)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: Radius.xl, topTrailingRadius: Radius.xl)
                .fill(Theme.surface)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func state(for lang: Lang) -> SpeakerButton.State {
        if controller.connectionError != nil && controller.phase == .idle { return .disabled }
        switch controller.phase {
        case .idle: return .idle
        case .listening(let l): return l == lang ? .active : .waiting
        case .finishing, .playing: return .cutIn
        }
    }
}

struct SpeakerButton: View {
    enum State { case idle, active, waiting, cutIn, disabled }

    let lang: Lang
    let state: State
    let level: Float
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: state == .active ? "stop.fill" : "mic.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(state == .active ? Color.white : Theme.accent)
                        .frame(width: 44, height: 44)
                        .background(state == .active ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(Theme.badge), in: Circle())
                    Spacer()
                    if state == .active {
                        LevelWave(level: level, color: .white)
                    } else {
                        Text(lang.code).font(.noto(12, .bold)).foregroundStyle(Theme.textSecondary)
                    }
                }
                Text(state == .active ? lang.listeningTitle : lang.speakTitle)
                    .font(.noto(17, .bold))
                    .foregroundStyle(state == .active ? Color.white : Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Text(subtitle)
                    .font(.noto(12, .regular))
                    .foregroundStyle(state == .active ? Color.white.opacity(0.85) : Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.xl)
                    .strokeBorder(Theme.accent, lineWidth: state == .cutIn ? 1.5 : 0)
            )
            .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
            .shadow(color: .black.opacity(state == .active ? 0.2 : 0.12), radius: 10, y: 3)
            .opacity(state == .waiting || state == .disabled ? 0.45 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(state == .waiting || state == .disabled)
        .accessibilityLabel(state == .active ? "\(lang.name) 말하기 끝내기" : "\(lang.name) 말하기")
    }

    private var subtitle: String {
        switch state {
        case .idle: return lang.speakHint
        case .active: return lang == .ko ? "한국어 → 상대 언어 통역" : "English → other language"
        case .waiting: return lang.waitingHint
        case .cutIn: return lang.cutInHint
        case .disabled: return lang == .ko ? "연결되면 쓸 수 있어요" : "Available when connected"
        }
    }

    @ViewBuilder
    private var background: some View {
        if state == .active {
            Theme.gradient(scheme)
        } else {
            Theme.surfaceRaised
        }
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// 입력 음량에 반응하는 막대 파형.
struct LevelWave: View {
    let level: Float
    let color: Color
    private let base: [CGFloat] = [0.3, 0.55, 0.9, 0.6, 1.0, 0.45, 0.75, 0.35]

    var body: some View {
        let amp = CGFloat(min(1, max(0.12, level * 9)))
        HStack(alignment: .center, spacing: 3) {
            ForEach(base.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(width: 3, height: max(4, 26 * base[i] * amp))
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
