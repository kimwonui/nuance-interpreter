import SwiftUI

/// V2 오브 중심 홈(피그마 O00~O07). 첫 진입부터 오브가 보이고, 자막·기록은 보조 영역.
struct OrbHomeView: View {
    @ObservedObject var controller: InterpreterController
    @State private var showSettings = false
    @State private var showHistory = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if controller.mode == .auto { autoBody } else { manualBody }
        }
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

    // MARK: Hands-free: face-to-face split screen

    /// Top half = the other person (rotated so they can read it), bottom half = you, orb in the middle.
    private var autoBody: some View {
        VStack(spacing: 10) {
            SideHalf(controller: controller, side: .them, cue: cue(for: .them))
                .rotationEffect(.degrees(180))
            VStack(spacing: 2) {
                OrbView(mode: orbMode, inputLevel: controller.level, outputLevel: controller.outputLevel,
                        accessibilityText: controller.canStart ? "Start conversation"
                            : controller.canFinishTurn ? "\(status.title). Done speaking" : "\(status.title). \(status.sub)", diameter: 190)
                    .frame(height: 170)
                    .contentShape(Circle())
                    // Stopped: starts (like Start conversation). Listening: "I'm done — interpret now". NUA speaking:
                    // stops NUA's voice. A tap never stops or mutes the conversation itself.
                    .onTapGesture { orbTapped() }
                    .accessibilityAddTraits(controller.canStart || controller.canFinishTurn || controller.autoState == .speaking ? .isButton : [])
                    .accessibilityHint(controller.canStart ? "Turns on the microphone and starts listening for \(controller.leftLang.name) or \(controller.rightLang.name)"
                                       : controller.canFinishTurn ? "Tells NUA you finished speaking so it interprets now"
                                       : controller.autoState == .speaking ? "Stops NUA's voice" : "")
                    .accessibilityAction { orbTapped() }
                Text(status.title).font(.noto(16, .bold)).foregroundStyle(Theme.text)
                directionLine
                statusAccessory.padding(.top, 4)
            }
            .animation(.easeInOut(duration: 0.2), value: status.title)
            SideHalf(controller: controller, side: .me, cue: cue(for: .me))
            HStack(spacing: 10) {
                circleButton("clock", "History") { showHistory = true }
                autoControls
                circleButton("slider.horizontal.3", "Settings") { showSettings = true }
            }
            Text("Nothing is saved · Audio goes to OpenAI to interpret")
                .font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 4)
    }

    /// Turn cue per half, from real state: who is talking (source transcript), who should listen (output
    /// language while NUA plays), and whose turn it looks like next. Unknown → neutral.
    private func cue(for side: InterpreterController.Side) -> SideHalf.Cue {
        switch controller.autoState {
        case .off, .connecting: return .idle
        case .muted: return .muted
        case .speaking:
            guard let listener = controller.side(of: controller.speakingLanguage) else { return .idle }
            return side == listener ? .listen : .waitOther
        case .waiting, .hearing, .interpreting:
            if let speaker = controller.speakerSide, controller.autoState != .waiting || controller.liveHolding {
                return side == speaker ? .talking : .waitOther
            }
            if let turn = controller.turnSide { return side == turn ? .yourTurn : .idle }
            return .idle
        }
    }

    // MARK: Push-to-talk layout (unchanged)

    private var manualBody: some View {
        VStack(spacing: 0) {
            topBar
            if controller.isLocalTest {
                Text("TEST SIGNAL MODE · NOT INTERPRETING")
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
                .accessibilityLabel("NUA")
            OrbView(mode: orbMode, inputLevel: controller.level, outputLevel: controller.outputLevel, accessibilityText: "\(status.title). \(status.sub)")
                .onTapGesture { if controller.phase == .playing || controller.autoState == .speaking { controller.stopPlayback() } }
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
    }

    // MARK: 상태

    private func orbTapped() {
        if controller.canStart { controller.startConversation(); return }
        if controller.canFinishTurn { controller.finishTurnNow(); return }
        if controller.phase == .playing || controller.autoState == .speaking { controller.stopPlayback() }
    }

    private var orbMode: OrbView.Mode {
        if controller.mic == .denied { return .disabled }
        if controller.mode == .auto, controller.autoState != .off {
            switch controller.autoState {
            case .connecting, .interpreting: return .processing
            // Mic is live: follow the real mic level; if NUA's voice is buffered for the pause, show waiting.
            case .waiting, .hearing: return controller.liveFinishPending ? .processing : controller.liveHolding ? .holding : .listening
            case .speaking: return .speaking(controller.speakingLanguage)
            case .muted: return .disabled
            case .off: return .idle
            }
        }
        if controller.phase == .playing { return .speaking(controller.speakingLanguage) } // Replay
        switch controller.phase {
        case .idle: return controller.connectionError != nil ? .disabled : .idle
        case .listening: return .listening
        case .finishing: return .processing
        case .playing: return .speaking(controller.speakingLanguage)
        }
    }

    private var status: (title: String, sub: String) {
        if controller.mic == .denied { return ("Microphone access needed", "NUA needs to hear speech to interpret · Not listening") }
        if controller.mode == .auto {
            switch controller.autoState {
            case .off:
                if controller.phase == .playing { return ("Speaking" + (controller.speakingLanguage.map { " \($0.name)" } ?? ""), "Tap the orb to stop") }
                if controller.engineLimit != nil { return ("Ready", "Mic off") }
                if controller.connectionError != nil { return ("Not connected", "Tap to try again · Mic off") }
                return ("Tap to start", "Mic off · Tap the orb to start")
            case .connecting: return ("Connecting…", "Getting the interpreter ready")
            case .waiting, .hearing:
                if controller.liveFinishPending { return ("Finishing your turn", "Mic paused · Interpreting what you said") }
                if controller.liveHolding { return ("Waiting for you to finish", "Tap the orb when you're done") }
                return ("Listening", controller.isOneWay ? "Speak \(controller.leftLang.name) · Tap the orb when done" : "Speak either language · Tap the orb when done")
            case .interpreting: return ("Interpreting", "Getting the translation ready")
            case .speaking:
                let lang = controller.speakingLanguage.map { " \($0.name)" } ?? ""
                return ("Speaking\(lang)", "Talk to cut in · Tap the orb to stop")
            case .muted: return ("Muted", "Mic off · Tap Unmute to continue")
            }
        }
        switch controller.phase {
        case .idle:
            if controller.connectionError != nil { return ("Not connected", "Not listening") }
            return ("Ready", controller.turns.isEmpty ? "Mic off · Tap your language to speak" : "Mic off · Tap the caption to replay")
        case .listening(let l): return ("Listening · \(l.name)", "Tap Done when you finish")
        case .finishing: return ("Interpreting", "Keeping the tone and intent")
        case .playing: return ("Speaking" + (controller.speakingLanguage.map { " \($0.name)" } ?? ""), "Tap the orb to stop")
        }
    }

    @ViewBuilder
    private var statusAccessory: some View {
        if let limit = controller.engineLimit, controller.autoState == .off, controller.phase == .idle {
            Text(limit)
                .font(.noto(12, .medium))
                .foregroundStyle(Theme.accentText)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 24)
        }
        if let note = controller.engineNote, controller.autoState != .off {
            Text(note)
                .font(.noto(11, .regular))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 24)
        }
        if controller.mic == .denied {
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("Turn on Microphone in Settings")
                    .font(.noto(15, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 28).frame(height: 48)
                    .background(Theme.gradient(scheme), in: RoundedRectangle(cornerRadius: Radius.cta))
            }
            .buttonStyle(PressScale())
        } else if let err = controller.connectionError, controller.phase == .idle {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accentText)
                Text("Can't reach the interpretation server").font(.noto(13, .medium)).foregroundStyle(Theme.text)
                Button("Retry") { controller.retryConnection() }
                    .font(.noto(12, .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.accent, in: Capsule())
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Theme.badge, in: Capsule())
            .accessibilityHint(err)
            // Show the actual reason (timeout, unauthorized, …) so a failed connection can be diagnosed on the phone.
            Text(err)
                .font(.noto(11, .regular))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.top, 6)
        }
    }

    // MARK: 영역

    private var topBar: some View {
        HStack {
            circleButton("clock", "History") { showHistory = true }
            Spacer()
            if controller.mode == .auto {
                // Hands-free is always both ways: a fixed label, no direction to pick or swap.
                Text("Korean ↔ English")
                    .font(.noto(14, .bold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(Theme.surface, in: Capsule())
                    .accessibilityLabel("Korean and English, both directions, detected automatically")
            } else {
            HStack(spacing: 10) {
                langMenu(controller.leftLang, left: true)
                Button { controller.swapLanguages() } label: {
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                }
                .accessibilityLabel("Swap languages")
                langMenu(controller.rightLang, left: false)
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .background(Theme.surface, in: Capsule())
            .disabled(controller.phase != .idle || controller.autoState != .off)
            }
            Spacer()
            circleButton("slider.horizontal.3", "Settings") { showSettings = true }
        }
        .padding(.vertical, 8)
    }

    private func langMenu(_ lang: Lang, left: Bool) -> some View {
        Menu {
            ForEach(Lang.allCases.filter { !$0.liveOnly }) { l in Button(l.name) { controller.setLanguage(l, left: left) } }
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
if controller.mode == .manual {
                                    Text("\(turn.source.code) → \(turn.target.code)")
                    .font(.noto(11, .medium)).foregroundStyle(Theme.accentText)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.badge, in: RoundedRectangle(cornerRadius: 9))
                }
                if !turn.sourceText.isEmpty {
                    Text(turn.sourceText).font(.noto(14, .regular)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                        .environment(\.layoutDirection, turn.sourceText.startsRightToLeft ? .rightToLeft : .leftToRight)
                }
                if !turn.targetText.isEmpty {
                    Text(turn.targetText).font(.noto(20, .bold)).foregroundStyle(Theme.text).lineLimit(3).minimumScaleFactor(0.8)
                        .environment(\.layoutDirection, turn.targetText.startsRightToLeft ? .rightToLeft : .leftToRight)
                } else if case .failed(let msg) = turn.status {
                    Text("Failed · \(msg)").font(.noto(13, .medium)).foregroundStyle(Theme.accentText).lineLimit(2)
                } else if turn.status == .empty {
                    Text("Nothing to interpret (same language, or too quiet)").font(.noto(13, .regular)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 132)
        .contentShape(Rectangle())
        .onTapGesture {
            guard let t = turn, controller.phase == .idle, controller.autoState == .off || controller.autoState == .waiting else { return }
            if case .failed = t.status { controller.retry(t.id) } else { controller.replay(t.id) }
        }
        .accessibilityHint(turn == nil ? "" : "Tap to replay")
    }

    private var bottom: some View {
        VStack(spacing: 10) {
            if controller.mode == .auto {
                autoControls
            } else {
                HStack(spacing: 12) {
                    SpeakerPill(lang: controller.leftLang, state: pillState(controller.leftLang)) { controller.tapSpeaker(controller.leftLang) }
                    SpeakerPill(lang: controller.rightLang, state: pillState(controller.rightLang)) { controller.tapSpeaker(controller.rightLang) }
                }
            }
            Text("Nothing is saved · Audio goes to OpenAI to interpret")
                .font(.noto(11, .regular)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    /// "Korean ↔ English" (two-way) or "Korean → English" with a swap button (one-way, while stopped).
    @ViewBuilder
    private var directionLine: some View {
        let l = controller.leftLang.name, r = controller.rightLang.name
        if controller.isOneWay {
            HStack(spacing: 6) {
                Text("\(l) → \(r)").font(.noto(12, .medium)).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel("One way, \(l) to \(r)")
                if controller.autoState == .off {
                    Button { controller.swapLanguages() } label: {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accentText)
                            .frame(width: 28, height: 22)
                            .background(Theme.badge, in: Capsule())
                    }
                    .accessibilityLabel("Swap direction")
                    .accessibilityHint("Interpret \(r) to \(l) instead")
                }
            }
        } else {
            Text("\(l) ↔ \(r)").font(.noto(12, .medium)).foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("\(l) and \(r), both directions")
        }
    }

    /// One side of the Two-way / One-way switch: the selected side is filled with NUA's coral (white text), the other
    /// stays neutral.
    private func directionSegment(_ title: String, _ value: InterpreterController.Direction, hint: String) -> some View {
        let selected = controller.direction == value
        return Button { controller.setDirection(value) } label: {
            Text(title)
                .font(.noto(15, .bold))
                .foregroundStyle(selected ? Color.white : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 40)
                .background(Capsule().fill(selected ? AnyShapeStyle(Theme.gradient(scheme)) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(hint)
    }

    /// Hands-free controls. Stopped: Two-way / One-way switch (the orb starts). Running: Mute and Stop, always
    /// visible; the switch is hidden so a running session's direction can't change under it.
    @ViewBuilder
    private var autoControls: some View {
        if controller.autoState == .off {
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    directionSegment("Two-way", .twoWay, hint: "Both languages are interpreted")
                    directionSegment("One-way", .oneWay, hint: "Only your language is interpreted")
                        .disabled(!controller.oneWayAvailable)
                        .opacity(controller.oneWayAvailable ? 1 : 0.45)
                }
                .padding(4)
                .background(Capsule().fill(Theme.surfaceRaised))
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                Text(controller.oneWayAvailable
                     ? (controller.direction == .oneWay ? "Only your language is interpreted · Tap the orb to start" : "Both languages · Tap the orb to start")
                     : "One-way needs the NUA server update · Tap the orb to start")
                    .font(.noto(10, .regular)).foregroundStyle(Theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
        } else {
            HStack(spacing: 12) {
                Button { controller.toggleMute() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: controller.autoState == .muted ? "mic.fill" : "mic.slash.fill").font(.system(size: 14, weight: .bold))
                        Text(controller.autoState == .muted ? "Unmute" : "Mute").font(.noto(15, .bold))
                    }
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Capsule().fill(Theme.surfaceRaised))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                }
                .buttonStyle(PressScale())
                Button { controller.stopConversation() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill").font(.system(size: 14, weight: .bold))
                        Text("Stop").font(.noto(15, .bold))
                    }
                    .foregroundStyle(Theme.accentText)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(Capsule().fill(Theme.surfaceRaised))
                    .overlay(Capsule().strokeBorder(Theme.accent, lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
                }
                .buttonStyle(PressScale())
                .accessibilityHint("Stops listening and turns the microphone off")
            }
        }
    }

    private func pillState(_ lang: Lang) -> SpeakerPill.State {
        if controller.mic == .denied || controller.engineLimit != nil { return .disabled }
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
        .accessibilityLabel(state == .active ? "Done speaking \(lang.name)" : "Speak \(lang.name)")
    }

    private var label: String {
        switch state {
        case .active: return "Done"
        case .cutIn: return "Cut in · \(lang.name)"
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
                Text("History").font(.noto(20, .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button("Clear") { controller.clearHistory() }
                    .font(.noto(14, .medium)).foregroundStyle(Theme.accentText)
                    .disabled(controller.turns.isEmpty || controller.phase != .idle)
            }
            Text("Shown only during this session. Cleared when you close the app.").font(.noto(12, .regular)).foregroundStyle(Theme.textSecondary)
            if controller.turns.isEmpty {
                Spacer()
                Text("No interpretations yet").font(.noto(14, .regular)).foregroundStyle(Theme.textSecondary).frame(maxWidth: .infinity)
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
