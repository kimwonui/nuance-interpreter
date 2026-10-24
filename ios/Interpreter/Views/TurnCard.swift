import SwiftUI

/// 원문·번역 카드(I02~I05).
struct TurnCard: View {
    let turn: Turn
    let isPlaying: Bool
    let level: Float
    let showLatency: Bool
    let onReplay: () -> Void
    let onRetry: () -> Void
    let onCopy: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(turn.source == .ko ? "한국어" : turn.source.name) → \(turn.target.code)")
                    .font(.noto(11, .medium))
                    .foregroundStyle(isFromSecondSpeaker ? Theme.textSecondary : Theme.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isFromSecondSpeaker ? AnyShapeStyle(Theme.selected) : AnyShapeStyle(Theme.badge), in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                statusView
            }

            if !turn.sourceText.isEmpty || turn.status == .listening {
                Text(turn.sourceText.isEmpty ? "말씀하세요…" : turn.sourceText)
                    .font(.noto(14, .regular))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if turn.status == .listening {
                LevelWave(level: level, color: Theme.accent)
            }
            if !turn.targetText.isEmpty {
                Text(turn.targetText)
                    .font(.noto(17, .bold))
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else if turn.status == .translating {
                Text("●  ●  ●").font(.noto(12, .medium)).foregroundStyle(Theme.accent)
            }

            footer
        }
        .padding(16)
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Theme.accent, lineWidth: turn.isLive || isPlaying ? 1.5 : 0))
        .cardShadow()
        .contentShape(Rectangle())
        .onTapGesture { if isPlaying { onStop() } }
    }

    private var isFromSecondSpeaker: Bool { turn.source == .en }

    @ViewBuilder
    private var statusView: some View {
        switch turn.status {
        case .connecting, .listening:
            pill("mic.fill", "듣는 중")
        case .translating:
            pill("arrow.triangle.2.circlepath", "통역 중")
        case .playing:
            pill("speaker.wave.2.fill", "재생 중 · 탭하면 멈춤")
        case .failed:
            Text("통역 실패").font(.noto(12, .medium)).foregroundStyle(Theme.accentText)
        case .empty:
            Text("통역할 말이 없음").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
        case .interrupted:
            Text("중단됨").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
        case .done:
            if isPlaying {
                pill("speaker.wave.2.fill", "다시 듣는 중")
            } else {
                Text(turn.createdAt, format: .dateTime.hour().minute()).font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        switch turn.status {
        case .failed(let msg):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Theme.accentText)
                Text(msg).font(.noto(13, .medium)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Spacer(minLength: 0)
                if !turn.inputAudio.isEmpty {
                    Button(action: onRetry) {
                        Label("재시도", systemImage: "arrow.clockwise")
                            .font(.noto(13, .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .background(Theme.accent, in: Capsule())
                    }
                }
            }
        case .empty:
            HStack {
                Text("같은 언어로 말했거나 소리가 작았을 수 있어요.").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
                Spacer()
                action("arrow.clockwise", "재시도", onRetry)
            }
        case .done, .interrupted:
            HStack(spacing: 16) {
                if !turn.outputAudio.isEmpty { action("gobackward", "다시 듣기", onReplay) }
                if !turn.inputAudio.isEmpty { action("arrow.clockwise", "재시도", onRetry) }
                if !turn.targetText.isEmpty { action("doc.on.doc", "복사", onCopy) }
                Spacer()
                if showLatency, let l = turn.metrics.endToFirstSound {
                    Text(String(format: "끝→첫 소리 %.2f초", l)).font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.top, 4)
        default:
            EmptyView()
        }
    }

    private func pill(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold))
            Text(text).font(.noto(13, .medium))
        }
        .foregroundStyle(Theme.accentText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Theme.badge, in: Capsule())
    }

    private func action(_ icon: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.noto(12, .medium))
            }
            .foregroundStyle(Theme.textSecondary)
        }
        .buttonStyle(.plain)
    }
}
