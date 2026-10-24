import SwiftUI

/// V2 오브 중심 홈(피그마 O00~O07). 첫 진입부터 오브가 보이고, 자막·기록은 보조 영역.
struct OrbHomeView: View {
    @ObservedObject var controller: InterpreterController
    @State private var showSettings = false
    @State private var showHistory = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if controller.isLocalTest {
                Text("테스트 신호 모드 · 통역 안 함")
                    .font(.noto(12, .bold))
                    .foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.badge, in: Capsule())
            }
            Spacer(minLength: 0)
            Text("NUA")
                .font(.noto(15, .bold))
                .tracking(3.6)
                .foregroundStyle(Theme.accentText)
                .accessibilityLabel("누아")
            OrbView(mode: orbMode, inputLevel: controller.level, outputLevel: controller.outputLevel, accessibilityText: "\(status.title). \(status.sub)")
                .onTapGesture { if controller.phase == .playing { controller.stopPlayback() } }
            VStack(spacing: 4) {
                Text(status.title).font(.noto(17, .bold)).foregroundStyle(Theme.text)
                Text(status.sub).font(.noto(13, .regular)).foregroundStyle(Theme.textSecondary)
            }
            .multilineTextAlignment(.center)
            .animation(.easeInOut(duration: 0.2), value: status.title)
            statusAccessory.padding(.top, 14)
            Spacer(minLength: 0)
            caption
            bottom
        }
        .padding(.horizontal, 16)
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $showSettings) {
            SettingsSheet(controller: controller).presentationCornerRadius(24)
        }
        .sheet(isPresented: $showHistory) {
            HistorySheet(controller: controller)
                .presentationDetents([.fraction(0.75), .large])
                .presentationCornerRadius(24)
        }
    }

    // MARK: 상태

    private var orbMode: OrbView.Mode {
        if controller.mic == .denied { return .disabled }
        switch controller.phase {
        case .idle: return controller.connectionError != nil ? .disabled : .idle
        case .listening: return .listening
        case .finishing: return .processing
        case .playing: return .speaking
        }
    }

    private var status: (title: String, sub: String) {
        if controller.mic == .denied { return ("마이크 권한이 필요해요", "통역하려면 말소리를 들어야 해요 · 듣고 있지 않아요") }
        switch controller.phase {
        case .idle:
            if controller.connectionError != nil { return ("연결 안 됨", "듣고 있지 않아요") }
            return ("대기 중", controller.turns.isEmpty ? "마이크 꺼짐 · 말할 사람이 자기 언어를 누르세요" : "마이크 꺼짐 · 다시 들으려면 자막을 탭")
        case .listening(let l): return ("듣는 중 · \(l.name)", "말이 끝나면 끝내기를 누르세요")
        case .finishing: return ("통역 중", "말투를 살려 옮기는 중이에요")
        case .playing: return ("재생 중", "오브를 탭하면 멈춰요")
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        if controller.mic == .denied {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("설정에서 마이크 켜기")
                    .font(.noto(15, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 28).frame(height: 48)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
        } else if let err = controller.connectionError, controller.phase == .idle {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                Text("통역 서버에 연결할 수 없어요").font(.noto(13, .medium)).foregroundStyle(Theme.text)
                Button("다시 시도") { controller.retryConnection() }
                    .font(.noto(12, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.badge, in: Capsule())
            .accessibilityHint(err)
        }
    }

    // MARK: 영역

    private var topBar: some View {
        HStack {
            circleButton("clock", "대화 기록") { showHistory = true }
            Spacer()
            HStack(spacing: 10) {
                langMenu(controller.leftLang, left: true)
                Button { controller.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("언어 바꾸기")
                langMenu(controller.rightLang, left: false)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.surface, in: Capsule())
            .disabled(controller.phase != .idle)
            Spacer()
            circleButton("slider.horizontal.3", "설정") { showSettings = true }
        }
        .padding(.vertical, 8)
    }

    private func langMenu(_ lang: Lang, left: Bool) -> some View {
        Menu {
            ForEach(Lang.allCases) { l in Button(l.name) { controller.setLanguage(l, left: left) } }
        } label: {
            HStack(spacing: 5) {
                Text(lang.code).font(.noto(11, .bold)).foregroundStyle(Theme.accentText)
                Text(lang.name).font(.noto(14, .bold)).foregroundStyle(Theme.text)
            }
        }
    }

    private func circleButton(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 44, height: 44)
                .background(Theme.surfaceRaised, in: Circle())
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        }
        .accessibilityLabel(label)
    }

    /// 보조 자막: 진행 중이면 그 발화, 아니면 직전 발화. 탭하면 다시 듣기.
    private var caption: some View {
        let turn = controller.turns.last
        return VStack(spacing: 6) {
            if let turn {
                Text("\(turn.source == .ko ? "한국어" : turn.source.name) → \(turn.target.code)")
                    .font(.noto(11, .medium)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.badge, in: RoundedRectangle(cornerRadius: 9))
                if !turn.sourceText.isEmpty {
                    Text(turn.sourceText).font(.noto(14, .regular)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                }
                if !turn.targetText.isEmpty {
                    Text(turn.targetText).font(.noto(20, .bold)).foregroundStyle(Theme.text).lineLimit(3).minimumScaleFactor(0.8)
                } else if case .failed(let msg) = turn.status {
                    Text("통역 실패 · \(msg)").font(.noto(13, .medium)).foregroundStyle(Theme.accentText).lineLimit(2)
                } else if turn.status == .empty {
                    Text("통역할 말이 없었어요 (같은 언어였거나 소리가 작았어요)").font(.noto(13, .regular)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 132)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let t = turn, controller.phase == .idle else { return }
            if case .failed = t.status { controller.retry(t.id) } else { controller.replay(t.id) }
        }
        .accessibilityHint(turn == nil ? "" : "탭하면 다시 듣기")
    }

    private var bottom: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                SpeakerPill(lang: controller.leftLang, state: pillState(controller.leftLang)) { controller.tapSpeaker(controller.leftLang) }
                SpeakerPill(lang: controller.rightLang, state: pillState(controller.rightLang)) { controller.tapSpeaker(controller.rightLang) }
            }
            Text("음성·대화는 저장하지 않아요 · 통역을 위해 OpenAI로 전송돼요")
                .font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    private func pillState(_ lang: Lang) -> SpeakerPill.State {
        if controller.mic == .denied { return .disabled }
        switch controller.phase {
        case .idle: return controller.connectionError != nil ? .disabled : .idle
        case .listening(let l): return l == lang ? .active : .waiting
        case .finishing, .playing: return controller.turns.last?.source == lang ? .idle : .cutIn
        }
    }
}

/// 하단 화자 알약(피그마 "화자 알약").
struct SpeakerPill: View {
    enum State { case idle, active, waiting, cutIn, disabled }
    let lang: Lang
    let state: State
    let action: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: state == .active ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(state == .active ? Color.white : Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(state == .active ? AnyShapeStyle(Color.white.opacity(0.22)) : AnyShapeStyle(Theme.badge), in: Circle())
                Text(label)
                    .font(.noto(15, .bold))
                    .foregroundStyle(state == .active ? Color.white : Theme.text)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background {
                if state == .active { Capsule().fill(Theme.gradient(scheme)) } else { Capsule().fill(Theme.surfaceRaised) }
            }
            .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: state == .cutIn ? 1.5 : 0))
            .shadow(color: .black.opacity(state == .active ? 0.2 : 0.12), radius: 10, y: 3)
            .opacity(state == .waiting || state == .disabled ? 0.45 : 1)
        }
        .buttonStyle(PressScale())
        .disabled(state == .waiting || state == .disabled)
        .accessibilityLabel(state == .active ? "\(lang.name) 말하기 끝내기" : "\(lang.name) 말하기")
    }

    private var label: String {
        switch state {
        case .active: return lang == .ko ? "끝내기" : "Done"
        case .cutIn: return lang == .ko ? "끊고 한국어로" : "Cut in · English"
        default: return lang.speakTitle
        }
    }
}

/// O07 대화 기록 시트(이전안 카드 재사용).
struct HistorySheet: View {
    @ObservedObject var controller: InterpreterController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("대화 기록").font(.noto(20, .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("지우기") { controller.clearHistory() }
                    .font(.noto(14, .medium)).foregroundStyle(Theme.accentText)
                    .disabled(controller.turns.isEmpty || controller.phase != .idle)
            }
            Text("이번 실행 중에만 보여요. 앱을 닫으면 사라져요.").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
            if controller.turns.isEmpty {
                Spacer()
                Text("아직 통역한 대화가 없어요").font(.noto(14, .regular)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(controller.turns.reversed()) { turn in
                            TurnCard(turn: turn, isPlaying: controller.playingTurnID == turn.id, level: controller.level, showLatency: controller.showLatency,
                                     onReplay: { controller.replay(turn.id) }, onRetry: { controller.retry(turn.id) },
                                     onCopy: { controller.copy(turn.id) }, onStop: { controller.stopPlayback() })
                        }
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 24)
        .background(Theme.surface)
    }
}
