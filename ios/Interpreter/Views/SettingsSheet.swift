import SwiftUI

/// I06 설정.
struct SettingsSheet: View {
    @ObservedObject var controller: InterpreterController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("설정").font(.noto(20, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(Theme.surface, in: Circle())
                    }
                    .accessibilityLabel("닫기")
                }

                group("언어", note: "통역 엔진은 더 많은 언어를 지원해요. 다른 언어는 순서대로 열 예정이에요.") {
                    row("globe", "내 언어", controller.leftLang.name)
                    row("globe", "상대 언어", controller.rightLang.name)
                }

                group("화자 전환", note: "말할 사람이 자기 언어 버튼을 직접 누르는 방식이에요. 자동 감지는 아직 준비 중이에요.") {
                    row("hand.tap", "방식", "버튼으로")
                }

                group("소리", note: "이어폰·블루투스를 연결하면 자동으로 그쪽으로 바뀌어요.") {
                    row("headphones", "지금 출력", controller.route)
                }

                group("측정", note: nil) {
                    Toggle(isOn: $controller.showLatency) {
                        Label("지연 시간 표시", systemImage: "timer").font(.noto(15, .medium)).foregroundStyle(Theme.text)
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    if !controller.latency.isEmpty { latencySummary }
                }

                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark.shield").foregroundStyle(Theme.accentText)
                    Text("음성과 대화 내용은 기기에 저장하지 않아요. 통역을 위해 음성이 OpenAI 서버로 실시간 전송되고, 앱을 닫으면 화면 기록도 지워져요.")
                        .font(.noto(13, .regular))
                        .foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Theme.badge, in: RoundedRectangle(cornerRadius: Radius.lg))

                Button(role: .destructive) { controller.clearHistory(); dismiss() } label: {
                    Text("화면 기록 지우기").font(.noto(15, .bold)).frame(maxWidth: .infinity).frame(height: 48)
                }
                .disabled(controller.turns.isEmpty || controller.phase != .idle)

                Text("통역 서버: \(controller.serverDescription)").font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
            }
            .padding(20)
        }
        .background(Theme.background)
    }

    private var latencySummary: some View {
        let vals = controller.latency.compactMap(\.endToFirstSound).sorted()
        let avg = vals.isEmpty ? 0 : vals.reduce(0, +) / Double(vals.count)
        return VStack(alignment: .leading, spacing: 4) {
            Text("표본 \(vals.count)건 · 평균 \(String(format: "%.2f", avg))초 · 가장 느림 \(String(format: "%.2f", vals.last ?? 0))초")
                .font(.noto(13, .medium)).foregroundStyle(Theme.text)
            Text("기준: 끝 버튼 탭 → 번역 소리 재생 시작 (이번 실행 중에만 보관)")
                .font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private func group<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.noto(13, .medium)).foregroundStyle(Theme.textSecondary)
            VStack(spacing: 0) { content() }
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
            if let note {
                Text(note).font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 20).foregroundStyle(Theme.textSecondary)
            Text(title).font(.noto(15, .medium)).foregroundStyle(Theme.text)
            Spacer()
            Text(value).font(.noto(15, .medium)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}
