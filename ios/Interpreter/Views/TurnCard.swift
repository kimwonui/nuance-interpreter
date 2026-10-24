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
                Text("\(turn.source.code) → \(turn.target.code)")
                    .font(.noto(11, .medium))
                    .foregroundStyle(isFromSecondSpeaker ? Theme.textSecondary : Theme.accentText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(isFromSecondSpeaker ? AnyShapeStyle(Theme.selected) : AnyShapeStyle(Theme.badge), in: RoundedRectangle(cornerRadius: 9))
                Spacer()
                statusView
            }

            if !turn.sourceText.isEmpty || turn.status == .listening {
                Text(turn.sourceText.isEmpty ? "Speak now…" : turn.sourceText)
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
            pill("mic.fill", "Listening")
        case .translating:
            pill("arrow.triangle.2.circlepath", "Interpreting")
        case .playing:
            pill("speaker.wave.2.fill", "Playing · tap to stop")
        case .failed:
            Text("Failed").font(.noto(12, .medium)).foregroundStyle(Theme.accentText)
        case .empty:
            Text("Nothing to interpret").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
        case .interrupted:
            Text("Stopped").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
        case .done:
            if isPlaying {
                pill("speaker.wave.2.fill", "Replaying")
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
                        Label("Retry", systemImage: "arrow.clockwise")
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
                Text("You may have spoken the same language, or too quietly.").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
                Spacer()
                action("arrow.clockwise", "Retry", onRetry)
            }
        case .done, .interrupted:
            HStack(spacing: 16) {
                if !turn.outputAudio.isEmpty { action("gobackward", "Replay", onReplay) }
                if !turn.inputAudio.isEmpty { action("arrow.clockwise", "Retry", onRetry) }
                if !turn.targetText.isEmpty { action("doc.on.doc", "Copy", onCopy) }
                Spacer()
                if showLatency, let l = turn.metrics.endToFirstSound {
                    Text(String(format: "Done→first audio %.2fs", l)).font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
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
