import AVFoundation
import SwiftUI
import UIKit
import os

/// 화면 상태와 통역 흐름을 관리한다.
/// 흐름: 화자 버튼 탭 → 듣기(원문을 실시간 전송, 번역 음성은 보류) → 다시 탭(말 끝) → 보류분부터 바로 재생, 이후 도착분 이어서 재생 → 완료.
/// 재생 중 아무 버튼이나 누르면 재생을 끊고 바로 새로 듣는다(끼어들기).
@MainActor
final class InterpreterController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening(Lang)
        case finishing(Lang)   // 말 끝, 번역 마무리 중
        case playing
    }
    enum Mic { case undetermined, granted, denied }
    /// auto = hands-free (default): one Start, NUA detects Korean/English and interprets each utterance.
    /// manual = push-to-talk: tap your language, speak, tap Done.
    enum Mode: String { case auto, manual }
    /// Hands-free engine: live = GPT-Live over WebRTC (default); translate = two gpt-realtime-translate sessions.
    enum Engine: String { case live, translate }

    struct LatencySample {
        let direction: String
        let speechSec: Double
        let endToFirstSound: Double?
        let endToClosed: Double?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [Turn] = []
    /// Face-to-face layout: leftLang = MY language (bottom half), rightLang = THEIR language (top half).
    /// Sides are fixed by this choice; speaking the other language never flips who sits where.
    @Published var leftLang: Lang = Lang(rawValue: UserDefaults.standard.string(forKey: "myLang") ?? "") ?? .ko {
        didSet { UserDefaults.standard.set(leftLang.rawValue, forKey: "myLang") }
    }
    @Published var rightLang: Lang = Lang(rawValue: UserDefaults.standard.string(forKey: "theirLang") ?? "") ?? .en {
        didSet { UserDefaults.standard.set(rightLang.rawValue, forKey: "theirLang") }
    }
    enum Side { case me, them }
    /// Languages the deployed server accepts (GET /api/languages); Korean/English only if it can't be read.
    @Published private(set) var availableLangs: [Lang] = [.ko, .en]
    /// Guidance only: whose turn it looks like (the person who just heard a translation answers next).
    @Published private(set) var turnSide: Side?
    /// Who is talking right now, from the source transcript's language (nil = unknown).
    @Published private(set) var speakerSide: Side?
    func side(of lang: Lang?) -> Side? { lang == leftLang ? .me : lang == rightLang ? .them : nil }
    /// Hands-free direction. Two-way: both chosen languages, automatically. One-way: only my language (bottom)
    /// → their language (top); speech in their language gets no output (for one phone per person).
    enum Direction: String { case twoWay, oneWay }
    @Published var direction: Direction = Direction(rawValue: UserDefaults.standard.string(forKey: "liveDirection") ?? "") ?? .twoWay {
        didSet { UserDefaults.standard.set(direction.rawValue, forKey: "liveDirection") }
    }
    /// The deployed server accepts one-way sessions (GET /api/languages lists it).
    @Published private(set) var oneWayAvailable = false
    var isOneWay: Bool { mode == .auto && direction == .oneWay && oneWayAvailable }
    /// Change direction only while stopped, so a running session never keeps the other direction's instructions.
    func setDirection(_ d: Direction) {
        guard autoState == .off, d == .twoWay || oneWayAvailable else { return }
        direction = d
    }
    /// The chosen pair includes a language the interpreter model can't speak (Arabic): GPT-Live only.
    var pairNeedsLive: Bool { leftLang.liveOnly || rightLang.liveOnly }
    private var liveOnlyName: String { (leftLang.liveOnly ? leftLang : rightLang).name }
    /// Why the current settings can't run the chosen pair (shown instead of starting), or nil.
    var engineLimit: String? {
        if isOneWay, !pairNeedsLive, engine == .translate { return "One-way works only with GPT-Live. Switch the hands-free engine to GPT-Live in Settings." }
        guard pairNeedsLive else { return nil }
        if mode == .manual { return "Push to talk can't speak \(liveOnlyName). Use Hands-free with GPT-Live." }
        if engine == .translate { return "\(liveOnlyName) works only with GPT-Live. Switch the hands-free engine to GPT-Live in Settings." }
        return nil
    }
    /// GPT-Live is required (Arabic, or one-way): never fall back to the interpreter model.
    private var needsLive: Bool { pairNeedsLive || isOneWay }
    private var needsLiveReason: String { pairNeedsLive ? "\(liveOnlyName) works only with GPT-Live" : "One-way works only with GPT-Live" }
    @Published private(set) var mic: Mic = .undetermined
    @Published private(set) var route = "iPhone speaker"
    @Published private(set) var level: Float = 0
    @Published private(set) var outputLevel: Float = 0
    @Published private(set) var connectionError: String?
    @Published private(set) var playingTurnID: UUID?
    @Published private(set) var latency: [LatencySample] = []
    @Published var showLatency: Bool = UserDefaults.standard.bool(forKey: "showLatency") {
        didSet { UserDefaults.standard.set(showLatency, forKey: "showLatency") }
    }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "conversationMode") ?? "") ?? .auto {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "conversationMode")
            if mode == .manual, autoState != .off { stopConversation() }
        }
    }
    @Published private(set) var autoState: AutoConversation.State = .off
    @Published var engine: Engine = Engine(rawValue: UserDefaults.standard.string(forKey: "handsFreeEngine") ?? "") ?? .live {
        didSet {
            UserDefaults.standard.set(engine.rawValue, forKey: "handsFreeEngine")
            if autoState != .off { stopConversation() }
        }
    }
    @Published private(set) var engineNote: String?
    /// NUA's translated voice is buffered, waiting for the speaker to finish (from the audio gate).
    @Published private(set) var liveHolding = false
    /// GPT-Live: hold NUA's voice until the speaker has finished (app-enforced; see GatedAudioDevice).
    @Published var waitForPause: Bool = UserDefaults.standard.object(forKey: "liveWaitForPause") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(waitForPause, forKey: "liveWaitForPause")
            if live != nil { stopConversation() }
        }
    }

    var serverDescription: String { tokens.serverDescription }

    /// 실행 인자 -localTest: 서버 없이 실제 마이크 입력 + 기기 합성 "테스트 신호" 재생으로 오브·재생 경로만 확인(통역 안 함).
    /// 실행 인자 -autoDemo: 위 모드 + 정해진 순서로 버튼을 자동으로 눌러 모션을 녹화할 수 있게 한다.
    let isAutoDemo = ProcessInfo.processInfo.arguments.contains("-autoDemo")
    lazy var isLocalTest: Bool = isAutoDemo || ProcessInfo.processInfo.arguments.contains("-localTest")
    /// Launch argument -autoTurns: REAL interpretation with scripted taps (for on-device latency runs).
    let isAutoTurns = ProcessInfo.processInfo.arguments.contains("-autoTurns")

    private let audio = AudioIO()
    private let testSignal = TestSignal()
    private var active = false
    private var demoStarted = false
    private var peakIn: Float = 0   // 발화별 최대 입력 음량(검증 로그용, 숫자만)
    private var peakOut: Float = 0  // 발화별 최대 재생 음량
    private let tokens = TokenClient()
    private var prepared: [Lang: TranslationSocket] = [:]
    private var preparing: Set<Lang> = []
    private var sockets: [UUID: TranslationSocket] = [:]
    private var closed: Set<UUID> = []
    private var liveTurnID: UUID?
    private var replayingID: UUID?
    private var running = false
    private var autoEngine: AutoConversation!
    private var live: LiveSession?
    private var liveInput = ""          // source transcript since the last interpretation
    private var liveOneWay = false      // the running session's direction (fixed at Start)
    private var liveNuaPlaying = false  // pause gate: NUA's turn is playing (real playback state, not the level)
    private var liveFinishAt: Double = 0 // last "I'm done" orb tap (one per turn; repeated taps are ignored)
    private var liveLastOutLoud: Double = 0 // no gate: last time the output level was audible
    private var liveSessionTurnID: UUID?
    private var liveLastOut: Double = 0
    private var liveLastLoudIn: Double = 0
    private var liveOutputOn = false
    private var liveFirstSoundPending = false
    private var liveStarted = false
    /// Last time the phone detected someone speaking, and when the last Live turn was created.
    /// A new caption/turn is only allowed after real detected speech (never show what nobody said).
    private var liveUserVoiceAt: Double = 0
    private var liveLastTurnAt: Double = 0
    private let log = Logger(subsystem: "interp", category: "latency")

    init() {
        audio.onRouteChange = { [weak self] name in DispatchQueue.main.async { self?.route = name } }
        audio.onLevel = { [weak self] v in DispatchQueue.main.async { self?.level = v; self?.peakIn = max(self?.peakIn ?? 0, v) } }
        audio.onOutputLevel = { [weak self] v in DispatchQueue.main.async { self?.outputLevel = v; self?.peakOut = max(self?.peakOut ?? 0, v) } }
        audio.onPlaybackDrained = { [weak self] in self?.playbackDrained() }
        audio.onInterruption = { [weak self] began in if began { self?.handleInterruptionBegan() } }
        autoEngine = AutoConversation(audio: audio) { [unowned self] target in try await self.makeSocket(target) }
        autoEngine.onState = { [weak self] s in self?.autoState = s }
        autoEngine.onNewTurn = { [weak self] t in
            guard let self else { return }
            self.turns.append(t)
            self.speakerSide = self.side(of: t.source)
        }
        autoEngine.onUpdateTurn = { [weak self] id, body in self?.update(id, body) }
        autoEngine.onPlaying = { [weak self] id in
            guard let self else { return }
            if id == nil, self.playingTurnID != nil, let t = self.turns.last {
                self.turnSide = self.side(of: t.target) // the listener answers next
                self.speakerSide = nil
            }
            self.playingTurnID = id
        }
        autoEngine.onError = { [weak self] msg in self?.connectionError = msg; self?.stopConversation() }
        autoEngine.report = { [weak self] m in
            guard let self else { return }
            self.tokens.report(m)
            if let d = m["direction"] as? String, let sp = m["speechSec"] as? Double {
                self.latency.append(LatencySample(direction: d, speechSec: sp, endToFirstSound: m["endToFirstSound"] as? Double, endToClosed: nil))
            }
        }
    }

    // MARK: Hands-free

    /// True when tapping Start (or the orb) would start a conversation right now.
    var canStart: Bool { mode == .auto && autoState == .off && phase != .playing && mic != .denied && engineLimit == nil }

    /// Starts listening. Called from the Start button and from a tap on the orb.
    func startConversation() {
        guard canStart else { return }
        // Leave .off right away: a second tap (orb or button) before the mic permission returns must not open a
        // second session. Every early exit below goes back to .off so Start works again.
        autoState = .connecting
        if engine == .live { startLive(); return }
        startTranslateEngine()
    }

    private func startTranslateEngine() {
        Task {
            mic = await Self.micPermission(request: true)
            guard mic == .granted else { autoState = .off; return }
            do {
                try audio.start(voiceProcessing: true)
                running = true
            } catch {
                connectionError = "Couldn't start audio: \(error.localizedDescription)"
                autoState = .off
                return
            }
            connectionError = nil
            audio.onMicChunk = { [weak self] chunk in DispatchQueue.main.async { self?.autoEngine.mic(chunk) } }
            audio.beginCapture()
            autoEngine.start(pair: (leftLang, rightLang))
        }
    }

    /// Stops listening completely: sessions closed, mic engine stopped (iOS mic indicator goes off).
    func stopConversation() {
        if let live {
            live.stop()
            self.live = nil
            liveHolding = false
            liveStarted = false
            autoState = .off
            playingTurnID = nil
            level = 0
            outputLevel = 0
            return
        }
        autoEngine.stop()
        audio.endCapture()
        audio.onMicChunk = nil
        audio.stop()
        running = false
        level = 0
        outputLevel = 0
    }

    /// Mute turns the mic engine off but keeps the sessions; Unmute turns it back on.
    func toggleMute() {
        if let live {
            let mute = autoState != .muted
            live.setMuted(mute)
            autoState = mute ? .muted : .waiting
            if mute { level = 0 }
            return
        }
        if autoState == .muted {
            do { try audio.start(voiceProcessing: true); running = true } catch { connectionError = "Couldn't start audio: \(error.localizedDescription)"; return }
            audio.onMicChunk = { [weak self] chunk in DispatchQueue.main.async { self?.autoEngine.mic(chunk) } }
            audio.beginCapture()
            autoEngine.setMuted(false)
        } else if autoState != .off {
            autoEngine.setMuted(true)
            audio.endCapture()
            audio.stop()
            running = false
            level = 0
        }
    }

    // MARK: Hands-free · GPT-Live

    private func startLive() {
        Task {
            mic = await Self.micPermission(request: true)
            guard mic == .granted else { autoState = .off; return }
            if running { audio.stop(); running = false } // WebRTC owns the audio session in this mode
            connectionError = nil
            engineNote = nil
            autoState = .connecting
            turnSide = nil
            speakerSide = nil
            liveUserVoiceAt = 0
            liveLastTurnAt = 0
            liveLastOut = 0
            liveSessionTurnID = nil
            liveInput = ""
            liveSessionTurnID = nil
            liveStarted = false
            liveOneWay = isOneWay
            liveNuaPlaying = false
            liveFinishAt = 0
            liveLastOutLoud = 0
            // Two-way: ding when NUA finishes a translation so the other person knows to answer.
            LiveSession.gatedDevice.setTurnEndChime(!liveOneWay)
            let s = LiveSession(waitForPause: waitForPause)
            live = s
            // Events from a stopped session must never touch the current one.
            s.onEvent = { [weak self, weak s] e in guard let self, let s, self.live === s else { return }; self.liveEvent(e) }
            s.onLevels = { [weak self, weak s] i, o in guard let self, let s, self.live === s else { return }; self.liveLevels(i, o) }
            s.onHoldChange = { [weak self, weak s] h in guard let self, let s, self.live === s else { return }; self.liveHolding = h }
            s.onPlayingChange = { [weak self, weak s] p in guard let self, let s, self.live === s else { return }; self.liveNuaPlaying = p }
            s.onUserVoice = { [weak self, weak s] in
                guard let self, let s, self.live === s else { return }
                self.liveUserVoiceAt = CFAbsoluteTimeGetCurrent()
            }
            s.onDroppedUnprompted = { [weak self, weak s] sec in
                guard let self, let s, self.live === s else { return }
                self.tokens.report(["mode": "live:dropped-unprompted", "speechSec": sec])
            }
            s.onCutIn = { [weak self, weak s] mic, out in
                guard let self, let s, self.live === s else { return }
                self.tokens.report(["mode": "live:cutin", "route": String(format: "mic %.3f out %.3f", mic, out)])
            }
            s.onSoftPause = { [weak self, weak s] in
                guard let self, let s, self.live === s else { return }
                self.tokens.report(["mode": "live:pause"])
            }
            s.onTurnPlayed = { [weak self, weak s] played, skipped in
                guard let self, let s, self.live === s else { return }
                // NUA's turn length as played and any over-long silence skipped (pauses ≤ 1 s are kept).
                self.tokens.report(["mode": "live:turn", "speechSec": played, "trimmedTailSec": skipped])
            }
            s.onRelease = { [weak self, weak s] dt, early in
                guard let self, let s, self.live === s else { return }
                let dir = self.turns.last.map { "\($0.source.code)→\($0.target.code)" } ?? "?"
                if let id = self.liveSessionTurnID { self.update(id) { $0.metrics.tPlaybackStart = CFAbsoluteTimeGetCurrent() } }
                self.latency.append(LatencySample(direction: dir, speechSec: 0, endToFirstSound: dt, endToClosed: nil))
                // Exact: last detected user speech → first released NUA audio. "early" = NUA's audio began while the
                // speaker was still talking, so the gate waited the longer hold.
                self.tokens.report(["mode": "live:gated", "direction": dir, "endToFirstSound": dt,
                                    "route": LiveSession.gatedDevice.diagnosticsShort + (early ? " early" : "")])
            }
            s.start { [weak self] offer in
                guard let self else { throw CancellationError() }
                return try await self.tokens.liveAnswer(offer: offer, languages: [self.leftLang, self.rightLang], oneWay: self.liveOneWay)
            }
        }
    }

    private func liveEvent(_ e: LiveSession.Event) {
        let now = CFAbsoluteTimeGetCurrent()
        switch e {
        case .started:
            liveStarted = true
            autoState = .waiting
            tokens.report(["mode": "live:started", "route": AudioIO.routeName()])
            if waitForPause {
                // Evidence for noise issues: voice processing actually on? noise floor after a few seconds.
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.live != nil else { return }
                    self.tokens.report(["mode": "live:audio", "route": LiveSession.gatedDevice.diagnostics])
                }
            }
        case .inputText(let d):
            // New source speech after an interpretation finished starts a new turn.
            if liveSessionTurnID != nil, now - liveLastOut > 1.5 { liveSessionTurnID = nil; liveInput = "" }
            liveInput += d
            if let id = liveSessionTurnID { update(id) { $0.sourceText += d } }
            if let lang = Lang.detect(liveInput, among: (leftLang, rightLang)) { speakerSide = side(of: lang); turnSide = speakerSide }
        case .outputText(let d):
            let newTurn = liveSessionTurnID == nil || now - liveLastOut > 1.5
            // With the pause gate on, a new turn needs speech detected after the previous turn;
            // otherwise this is unprompted model output (its audio is discarded by the gate too).
            if newTurn && waitForPause && liveUserVoiceAt <= liveLastTurnAt { return }
            if newTurn {
                liveLastTurnAt = now
                let pair = (leftLang, rightLang)
                let other: (Lang) -> Lang = { $0 == pair.0 ? pair.1 : pair.0 }
                // One-way: always my language → theirs.
                let src = liveOneWay ? pair.0 : Lang.detect(liveInput, among: pair) ?? Lang.detect(d, among: pair).map(other) ?? pair.0
                var t = Turn(source: src, target: other(src))
                t.status = .playing
                t.sourceText = liveInput.trimmingCharacters(in: .whitespacesAndNewlines)
                t.metrics.tStop = liveLastLoudIn
                turns.append(t)
                liveSessionTurnID = t.id
                liveInput = ""
            }
            liveLastOut = now
            if let id = liveSessionTurnID {
                update(id) { $0.targetText += d }
                let detected = turns.first(where: { $0.id == id }).flatMap { Lang.detect($0.targetText, among: (leftLang, rightLang)) }
                if liveOneWay, let t = turns.first(where: { $0.id == id }), t.targetText.count >= 12, detected == leftLang {
                    // One-way safety net: NUA is speaking my language, i.e. it translated (or answered) the other
                    // person. Cut that audio and drop the turn; the gate stays closed until someone speaks again.
                    LiveSession.gatedDevice.discardUntilVoice()
                    turns.removeAll { $0.id == id }
                    liveSessionTurnID = nil
                    tokens.report(["mode": "live:wrong-dir"])
                    return
                }
                // Confirm the output language once the text shows it, then keep it for the whole turn (no flipping
                // back and forth as the text grows). Until then the orb shows no flag.
                if let outLang = detected, let t = turns.first(where: { $0.id == id }), !t.outputLangConfirmed,
                   !liveOneWay || outLang == rightLang {
                    update(id) {
                        $0.target = outLang
                        $0.source = outLang == self.leftLang ? self.rightLang : self.leftLang
                        $0.outputLangConfirmed = true
                    }
                }
            }
        case .closed(let usage):
            tokens.report(["mode": "live:closed", "speechSec": usage ?? -1])
            // Closed by OpenAI: still tear the connection down, or it keeps the mic and audio engine running.
            live?.stop()
            live = nil
            liveStarted = false
            autoState = .off
        case .failed(let msg):
            let wasStarting = !liveStarted
            live?.stop()
            live = nil
            liveStarted = false
            autoState = .off
            tokens.report(["mode": "live:failed", "route": String(msg.prefix(40))])
            if wasStarting && needsLive {
                // The interpreter model can't do this (Arabic voice / one-way): say so instead of switching silently.
                connectionError = "GPT-Live unavailable (\(msg.prefix(60))). \(needsLiveReason), so NUA did not switch engines."
            } else if wasStarting {
                // Live couldn't start (e.g. server not updated yet): fall back to the interpreter model.
                engineNote = "GPT-Live unavailable (\(msg.prefix(60))). Using the interpreter model."
                startTranslateEngine()
            } else {
                connectionError = msg
            }
        }
    }

    /// Orb levels + state from WebRTC stats. Latency here is approximate: audio levels are sampled every 0.1 s.
    private func liveLevels(_ input: Float, _ output: Float) {
        guard live != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        level = autoState == .muted ? 0 : input
        outputLevel = output
        if input > 0.03 && autoState != .muted { liveLastLoudIn = now; liveFirstSoundPending = true }
        // "Speaking" = NUA's turn is playing, from the gate's real playback state — not the instantaneous level,
        // which dips between words and at every pause inside a translation and made the orb and flags flicker.
        // Without the gate, the level with a 0.6 s hangover.
        if output > 0.02 { liveLastOutLoud = now }
        let speakingNow = waitForPause ? liveNuaPlaying : now - liveLastOutLoud < 0.6
        if speakingNow && !liveOutputOn { live?.ensureSpeaker() }
        if speakingNow && !liveOutputOn && liveFirstSoundPending && !waitForPause {
            liveFirstSoundPending = false
            let gap = now - liveLastLoudIn
            if gap < 10 {
                let dir = turns.last.map { "\($0.source.code)→\($0.target.code)" } ?? "?"
                if let id = liveSessionTurnID { update(id) { $0.metrics.tPlaybackStart = now } }
                latency.append(LatencySample(direction: dir, speechSec: 0, endToFirstSound: gap, endToClosed: nil))
                tokens.report(["mode": "live", "direction": dir, "endToFirstSound": gap, "route": AudioIO.routeName()])
            }
        }
        if !speakingNow && liveOutputOn, let t = turns.last {
            turnSide = side(of: Lang.detect(t.targetText, among: (leftLang, rightLang))) // the listener answers next
            speakerSide = nil
        }
        liveOutputOn = speakingNow
        guard liveStarted, autoState != .muted else { return }
        if speakingNow {
            autoState = .speaking
            playingTurnID = liveSessionTurnID
        } else {
            playingTurnID = nil
            if let id = liveSessionTurnID, now - liveLastOut > 1.5 { update(id) { if $0.status == .playing { $0.status = .done } } }
            autoState = input > 0.03 ? .hearing : .waiting
        }
    }

    /// Language NUA is speaking right now, only when certain:
    /// interpreter-model / push-to-talk turns know their target; GPT-Live turns need the translation text to prove it.
    /// nil → the orb shows a neutral "Speaking".
    var speakingLanguage: Lang? {
        guard let id = playingTurnID ?? (autoState == .speaking ? turns.last?.id : nil),
              let t = turns.first(where: { $0.id == id }) else { return nil }
        if live != nil { return t.outputLangConfirmed ? t.target : nil } // confirmed once per turn, then stable
        return t.target
    }

    /// Reads the languages the deployed server accepts. If unavailable (older server), only Korean/English.
    func loadLanguages() async {
        let info = try? await tokens.languages()
        let langs = info?.langs ?? [.ko, .en]
        oneWayAvailable = info?.oneWay ?? false
        availableLangs = langs.isEmpty ? [.ko, .en] : langs
        if !availableLangs.contains(leftLang) || !availableLangs.contains(rightLang) || leftLang == rightLang {
            leftLang = .ko
            rightLang = .en
        }
    }

    /// Set a side's language (only while not running). Picking the other side's language swaps them.
    func setLanguage(_ lang: Lang, for side: Side) {
        guard autoState == .off, phase == .idle, availableLangs.contains(lang) else { return }
        switch side {
        case .me:
            if lang == rightLang { rightLang = leftLang }
            leftLang = lang
        case .them:
            if lang == leftLang { leftLang = rightLang }
            rightLang = lang
        }
    }

    // MARK: 시작·종료

    /// 화면이 보이면 호출: 통역 세션을 미리 열고, 마이크 권한이 이미 있으면 오디오를 켠다.
    /// 마이크 권한 요청은 처음 말하기 버튼을 누를 때 한다.
    func start() async {
        active = true
        Task { await loadLanguages() }
        mic = await Self.micPermission(request: false)
        // The mic is never opened at launch. Push-to-talk prewarms its sessions (no audio is sent);
        // hands-free opens everything only when Start is tapped.
        if mode == .manual {
            prepare(leftLang)
            prepare(rightLang)
        }
        if isAutoDemo && !demoStarted { demoStarted = true; runAutoDemo() }
        if isAutoTurns && !demoStarted { demoStarted = true; runAutoTurns() }
        // Test-only launch argument: tap "Start conversation" automatically (hands-free runs).
        if ProcessInfo.processInfo.arguments.contains("-autoStart") && !demoStarted {
            demoStarted = true
            mode = .auto
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.startConversation() }
        }
    }

    @discardableResult
    private func startAudioIfNeeded() -> Bool {
        if running { return true }
        do {
            try audio.start()
            running = true
            return true
        } catch {
            connectionError = "Couldn't start audio: \(error.localizedDescription)"
            return false
        }
    }

    func recheckMic() async {
        mic = await Self.micPermission(request: false)
        if mic == .granted { startAudioIfNeeded() }
    }

    func suspend() {
        active = false
        if autoState != .off { stopConversation() }
        guard running else { return }
        if let id = liveTurnID { cancelTurn(id, as: .interrupted) }
        audio.stopPlayback()
        audio.stop()
        prepared.values.forEach { $0.cancel() }
        prepared.removeAll()
        sockets.values.forEach { $0.cancel() }
        sockets.removeAll()
        playingTurnID = nil
        replayingID = nil
        phase = .idle
        running = false
    }

    func retryConnection() {
        connectionError = nil
        if mode == .manual {
            prepare(leftLang)
            prepare(rightLang)
        }
    }

    static func micPermission(request: Bool) async -> Mic {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        default:
            guard request else { return .undetermined }
            return await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }
    }

    // MARK: 화자 버튼

    func tapSpeaker(_ lang: Lang) {
        guard engineLimit == nil else { return }
        if mic != .granted || !running {
            Task {
                mic = await Self.micPermission(request: true)
                guard mic == .granted, startAudioIfNeeded() else { return }
                tapSpeaker(lang)
            }
            return
        }
        switch phase {
        case .listening(let l):
            if l == lang { finishListening() }
        case .idle:
            startListening(lang)
        case .finishing, .playing:
            tokens.report(["mode": "cutin", "route": route])
            interruptPlayback()
            startListening(lang)
        }
    }

    private func makeSocket(_ target: Lang) async throws -> TranslationSocket {
        let t0 = CFAbsoluteTimeGetCurrent()
        let ticket = try await tokens.ticket(target: target)
        let s = TranslationSocket(target: target, ticket: ticket)
        s.ticketMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return s
    }

    func swapLanguages() {
        guard phase == .idle, autoState == .off else { return }
        (leftLang, rightLang) = (rightLang, leftLang)
    }

    func setLanguage(_ lang: Lang, left: Bool) {
        guard phase == .idle else { return }
        if left {
            if lang == rightLang { rightLang = leftLang }
            leftLang = lang
        } else {
            if lang == leftLang { leftLang = rightLang }
            rightLang = lang
        }
        prepare(leftLang)
        prepare(rightLang)
    }

    private func other(_ l: Lang) -> Lang { l == leftLang ? rightLang : leftLang }

    private func startListening(_ source: Lang) {
        guard running else { retryConnection(); return }
        let target = other(source)
        var turn = Turn(source: source, target: target)
        turn.status = .listening
        turn.metrics.tTap = CFAbsoluteTimeGetCurrent()
        turns.append(turn)
        let id = turn.id
        liveTurnID = id
        peakIn = 0
        peakOut = 0
        phase = .listening(source)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        audio.onMicChunk = { [weak self] chunk in
            DispatchQueue.main.async { self?.micChunk(chunk, turn: id) }
        }
        audio.beginCapture()

        if isLocalTest {
            update(id) { $0.sourceText = "[TEST SIGNAL] Real mic input only · not interpreting" }
            return
        }
        if let s = prepared.removeValue(forKey: target), !s.isStale {
            attach(s, to: id)
        } else {
            Task {
                do {
                    let s = try await makeSocket(target)
                    s.connect()
                    attach(s, to: id)
                } catch {
                    failTurn(id, error.localizedDescription)
                }
            }
        }
        // 다음 차례용 세션을 미리 연다.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.prepare(target) }
    }

    private func finishListening() {
        guard case .listening(let source) = phase, let id = liveTurnID else { return }
        let rest = audio.endCapture()
        level = 0
        phase = .finishing(source)
        update(id) {
            $0.status = .translating
            $0.metrics.tStop = CFAbsoluteTimeGetCurrent()
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // 메인 큐 순서를 지켜, 이미 들어와 있는 마이크 조각 → 나머지 조각 → 종료 신호 순으로 보낸다.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let rest { self.micChunk(rest, turn: id) }
            self.sockets[id]?.finish()
            self.flushHeldAudio(id)
            if self.isLocalTest { self.runTestOutput(id) }
        }
    }

    /// 테스트 신호: 0.9초 "처리" 뒤 기기 합성 음성을 번역 음성 자리에 흘려 실제 재생 경로·출력 반응을 확인한다.
    private func runTestOutput(_ id: UUID) {
        guard let t = turns.first(where: { $0.id == id }) else { return }
        let text = t.target == .en ? "This is a local test signal. The orb should move with this voice."
                                   : "테스트 신호입니다. 오브가 이 목소리에 맞춰 움직여야 해요."
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, let cur = self.turns.first(where: { $0.id == id }), cur.status == .translating else { return }
            self.update(id) { $0.targetText = "[TEST SIGNAL] " + text }
            self.testSignal.synthesize(text, language: t.target == .en ? "en-US" : "ko-KR") { [weak self] pcm in
                guard let self else { return }
                if let pcm { self.turnEvent(.audio(pcm), turn: id) } else { self.turnEvent(.closed, turn: id) }
            }
        }
    }

    /// 자동 시연(-autoDemo): 대기 → 한국어 듣기 4초 → 처리 → 재생 → 대기 → 영어 듣기 4초 → 처리 → 재생.
    private func runAutoDemo() {
        let steps: [(Double, Lang)] = [(3, .ko), (7, .ko), (16, .en), (20, .en)]
        for (t, lang) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.tapSpeaker(lang) }
        }
    }

    /// Real-mode script: KO, EN, KO, EN turns of 4 s each, ~26 s apart (session rate limits),
    /// then a cut-in during the last playback.
    private func runAutoTurns() {
        let steps: [(Double, Lang)] = [(4, .ko), (8, .ko), (30, .en), (34, .en), (56, .ko), (60, .ko), (82, .en), (86, .en), (87.2, .ko), (89.5, .ko)]
        for (t, lang) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in self?.tapSpeaker(lang) }
        }
    }

    private func micChunk(_ chunk: Data, turn id: UUID) {
        guard let i = index(id) else { return }
        turns[i].inputAudio.append(chunk)
        sockets[id]?.appendAudio(chunk)
    }

    private func attach(_ s: TranslationSocket, to id: UUID) {
        guard let turn = turns.first(where: { $0.id == id }), turn.isLive else { s.cancel(); return }
        sockets[id] = s
        update(id) { $0.metrics.prewarmed = s.openedAt != nil; $0.metrics.prepMs = s.prepMs }
        s.onEvent = { [weak self, weak s] e in
            if case .opened = e, let s { self?.update(id) { $0.metrics.prepMs = s.prepMs } }
            self?.turnEvent(e, turn: id)
        }
        // 소켓 준비 전에 쌓인 음성을 먼저 보낸다.
        var off = 0
        let audioSoFar = turn.inputAudio
        while off < audioSoFar.count {
            let end = min(off + AudioIO.chunkBytes, audioSoFar.count)
            s.appendAudio(audioSoFar.subdata(in: off..<end))
            off = end
        }
        if turn.status != .listening { s.finish() }
    }

    // MARK: 통역 이벤트

    private func turnEvent(_ e: TranslationSocket.Event, turn id: UUID) {
        guard let cur = turns.first(where: { $0.id == id }), cur.status != .interrupted else { return }
        switch e {
        case .opened:
            break
        case .inputText(let d):
            update(id) { $0.sourceText += d }
        case .outputText(let d):
            update(id) { $0.targetText += d }
        case .audio(let pcm):
            update(id) {
                $0.outputAudio.append(pcm)
                if $0.metrics.tFirstAudio == nil { $0.metrics.tFirstAudio = CFAbsoluteTimeGetCurrent() }
                if $0.metrics.tFirstVoiced == nil, SilenceGate.hasVoice(pcm) { $0.metrics.tFirstVoiced = CFAbsoluteTimeGetCurrent() }
            }
            if let t = turns.first(where: { $0.id == id }), t.status != .listening { flushHeldAudio(id) }
        case .closed:
            closed.insert(id)
            sockets[id] = nil
            update(id) { $0.metrics.tClosed = CFAbsoluteTimeGetCurrent() }
            if let t = turns.first(where: { $0.id == id }), !SilenceGate.hasVoice(t.outputAudio) {
                tokens.report(["mode": "empty", "direction": "\(t.source.code)→\(t.target.code)", "speechSec": Double(t.inputAudio.count) / 48_000])
                update(id) { $0.status = .empty }
                endTurn(id)
            } else if playingTurnID != id || !audio.isPlaying {
                completeTurn(id)
            }
        case .failed(let msg):
            sockets[id] = nil
            if closed.contains(id) { return }
            if let t = turns.first(where: { $0.id == id }), !t.outputAudio.isEmpty, t.status != .listening {
                // 일부 번역은 받았음 → 받은 만큼 재생하고 끝낸다.
                closed.insert(id)
                if !audio.isPlaying { completeTurn(id) }
            } else {
                failTurn(id, msg)
            }
        }
    }

    /// 말 끝 이후: 아직 재생하지 않은 번역 음성을 재생 대기열에 넣는다.
    private func flushHeldAudio(_ id: UUID) {
        guard let i = index(id) else { return }
        let t = turns[i]
        guard t.outputAudio.count > t.playedBytes else { return }
        if let other = playingTurnID, other != id { return }
        let fresh = t.outputAudio.subdata(in: t.playedBytes..<t.outputAudio.count)
        turns[i].playedBytes = t.outputAudio.count
        let play = SilenceGate.process(fresh, turn: &turns[i])
        guard !play.isEmpty else { return } // padding silence only — keep waiting
        audio.enqueue(pcm16: play)
        if turns[i].metrics.tPlaybackStart == nil, turns[i].metrics.tStop != nil {
            turns[i].metrics.tPlaybackStart = CFAbsoluteTimeGetCurrent()
        }
        turns[i].status = .playing
        playingTurnID = id
        phase = .playing
    }

    private func playbackDrained() {
        if replayingID == nil, autoEngine.isOn { autoEngine.playbackDrained(); return }
        if let r = replayingID {
            replayingID = nil
            if playingTurnID == r { playingTurnID = nil }
            if phase == .playing { phase = .idle }
            return
        }
        guard let id = playingTurnID else { return }
        if closed.contains(id) {
            completeTurn(id)
        } else if let t = turns.first(where: { $0.id == id }) {
            phase = .finishing(t.source) // 남은 번역을 기다리는 중
        }
    }

    private func completeTurn(_ id: UUID) {
        update(id) { if $0.status != .empty { $0.status = .done } }
        if let t = turns.first(where: { $0.id == id }) { record(t) }
        endTurn(id)
    }

    private func endTurn(_ id: UUID) {
        if playingTurnID == id { playingTurnID = nil }
        if liveTurnID == id { liveTurnID = nil }
        if case .listening = phase { return }
        if liveTurnID == nil && playingTurnID == nil { phase = .idle }
    }

    private func failTurn(_ id: UUID, _ msg: String) {
        if let t = turns.first(where: { $0.id == id }) {
            // Short error label only (no speech content).
            tokens.report(["mode": "failed", "direction": "\(t.source.code)→\(t.target.code)", "route": String(msg.prefix(40))])
        }
        if liveTurnID == id, case .listening = phase { audio.endCapture(); level = 0 }
        sockets[id]?.cancel()
        sockets[id] = nil
        update(id) { $0.status = .failed(msg) }
        if liveTurnID == id { liveTurnID = nil }
        if playingTurnID == id { audio.stopPlayback(); playingTurnID = nil }
        phase = .idle
    }

    private func cancelTurn(_ id: UUID, as status: TurnStatus) {
        audio.endCapture()
        sockets[id]?.cancel()
        sockets[id] = nil
        update(id) { $0.status = status }
        if liveTurnID == id { liveTurnID = nil }
    }

    private func interruptPlayback() {
        audio.stopPlayback()
        replayingID = nil
        if let id = playingTurnID ?? liveTurnID {
            if sockets[id] != nil || !closed.contains(id) {
                sockets[id]?.cancel()
                sockets[id] = nil
            }
            if let t = turns.first(where: { $0.id == id }), t.isLive { update(id) { $0.status = .interrupted } }
        }
        playingTurnID = nil
        liveTurnID = nil
        phase = .idle
    }

    private func handleInterruptionBegan() {
        if let id = liveTurnID { cancelTurn(id, as: .interrupted) }
        audio.stopPlayback()
        playingTurnID = nil
        phase = .idle
    }

    // MARK: 카드 동작

    func replay(_ id: UUID) {
        guard let t = turns.first(where: { $0.id == id }), !t.outputAudio.isEmpty else { return }
        if phase != .idle { interruptPlayback() }
        replayingID = id
        playingTurnID = id
        phase = .playing
        audio.enqueue(pcm16: SilenceGate.trimmed(t.outputAudio))
    }

    func stopPlayback() {
        if phase == .playing { interruptPlayback() }
        guard autoState == .speaking else { return }
        if live != nil {
            // GPT-Live (pause gate): stop NUA now and drop the rest of this answer. (Before, this called the other
            // engine's player and didn't stop GPT-Live at all.)
            if waitForPause { LiveSession.gatedDevice.discardUntilVoice(); tokens.report(["mode": "live:tap-stop"]) }
            return
        }
        audio.stopPlayback(); autoEngine.playbackDrained()
    }

    /// Orb tap while listening: "I'm done — interpret now." Keeps the session and everything already heard.
    var canFinishTurn: Bool { live != nil && liveStarted && (autoState == .waiting || autoState == .hearing) }

    func finishTurnNow() {
        guard canFinishTurn, let live else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - liveFinishAt > 3 else { return } // one request per turn; ignore quick repeated taps
        guard waitForPause else {
            // No gate: nothing is held on the phone; only the model can be asked.
            liveFinishAt = now; live.nudgeInterpretNow(); tokens.report(["mode": "live:tap-nudge"]); return
        }
        switch LiveSession.gatedDevice.finishTurn() {
        case .nothingHeard:
            tokens.report(["mode": "live:tap-nothing"]) // no speech detected: nothing to interpret
        case .releasedHeld:
            liveFinishAt = now
            tokens.report(["mode": "live:tap-release"]) // translation was ready: plays now
        case .waitingForModel:
            liveFinishAt = now
            live.nudgeInterpretNow() // nothing generated yet: ask the model to interpret now
            tokens.report(["mode": "live:tap-nudge"])
        }
    }

    func retry(_ id: UUID) {
        guard let i = index(id), !turns[i].inputAudio.isEmpty, !turns[i].isLive else { return }
        if phase != .idle { interruptPlayback() }
        let target = turns[i].target
        turns[i].targetText = ""
        turns[i].sourceText = ""
        turns[i].outputAudio = Data()
        turns[i].playedBytes = 0
        turns[i].voicedStarted = false
        turns[i].pendingSilence = Data()
        turns[i].status = .translating
        turns[i].metrics = TurnMetrics(tTap: nil, tStop: CFAbsoluteTimeGetCurrent())
        closed.remove(id)
        liveTurnID = id
        phase = .finishing(turns[i].source)
        Task {
            do {
                let s: TranslationSocket
                if let p = prepared.removeValue(forKey: target), !p.isStale { s = p } else {
                    s = try await makeSocket(target)
                    s.connect()
                }
                attach(s, to: id)
                prepare(target)
            } catch {
                failTurn(id, error.localizedDescription)
            }
        }
    }

    func copy(_ id: UUID) {
        guard let t = turns.first(where: { $0.id == id }) else { return }
        UIPasteboard.general.string = t.targetText
    }

    func clearHistory() {
        guard phase == .idle else { return }
        turns.removeAll()
        closed.removeAll()
    }

    // MARK: 세션 준비

    private func prepare(_ target: Lang) {
        guard active, !isLocalTest, !leftLang.liveOnly, !rightLang.liveOnly else { return }
        if let s = prepared[target], !s.isStale { return }
        prepared[target]?.cancel()
        prepared[target] = nil
        guard !preparing.contains(target) else { return }
        preparing.insert(target)
        Task {
            defer { preparing.remove(target) }
            do {
                let s = try await makeSocket(target)
                s.onEvent = { [weak self, weak s] e in
                    // 대기 중 세션이 끊기면 버리고, 곧바로 끊긴 경우(인증 거부 등)만 오류로 알린다.
                    guard let self, let s, case .failed(let msg) = e, self.prepared[target] === s else { return }
                    self.prepared[target] = nil
                    if Date().timeIntervalSince(s.createdAt) < 5 { self.connectionError = msg }
                }
                s.connect()
                prepared[target] = s
                connectionError = nil
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }

    // MARK: 도우미

    private func index(_ id: UUID) -> Int? { turns.firstIndex { $0.id == id } }

    private func update(_ id: UUID, _ body: (inout Turn) -> Void) {
        guard let i = index(id) else { return }
        body(&turns[i])
    }

    private func record(_ t: Turn) {
        let speech = Double(t.inputAudio.count) / 2 / AudioIO.sampleRate
        let s = LatencySample(direction: "\(t.source.code)→\(t.target.code)", speechSec: speech, endToFirstSound: t.metrics.endToFirstSound, endToClosed: t.metrics.endToClosed)
        latency.append(s)
        log.info("turn \(s.direction, privacy: .public) speech=\(speech, format: .fixed(precision: 2)) endToFirstSound=\(s.endToFirstSound ?? -1, format: .fixed(precision: 3)) endToClosed=\(s.endToClosed ?? -1, format: .fixed(precision: 3)) route=\(self.route, privacy: .public) peakIn=\(self.peakIn, format: .fixed(precision: 4)) peakOut=\(self.peakOut, format: .fixed(precision: 4)) test=\(self.isLocalTest)")
        var m: [String: Any] = ["direction": s.direction, "speechSec": speech, "prewarmed": t.metrics.prewarmed,
                                "route": route, "mode": isLocalTest ? "test-signal" : (isAutoTurns ? "auto-turns" : "manual"),
                                "trimmedLeadSec": Double(t.metrics.trimmedLeadBytes) / 48_000,
                                "trimmedTailSec": Double(t.metrics.trimmedTailBytes + t.pendingSilence.count) / 48_000]
        if let v = t.metrics.prepMs { m["prepMs"] = v }
        if let v = t.metrics.endToFirstSound { m["endToFirstSound"] = v }
        if let v = t.metrics.endToFirstVoicedArrival { m["endToFirstVoicedArrival"] = v }
        if let v = t.metrics.endToClosed { m["endToClosed"] = v }
        tokens.report(m)
    }
}
