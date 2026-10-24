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

    struct LatencySample {
        let direction: String
        let speechSec: Double
        let endToFirstSound: Double?
        let endToClosed: Double?
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var turns: [Turn] = []
    @Published var leftLang: Lang = .ko
    @Published var rightLang: Lang = .en
    @Published private(set) var mic: Mic = .undetermined
    @Published private(set) var route = "iPhone 스피커"
    @Published private(set) var level: Float = 0
    @Published private(set) var connectionError: String?
    @Published private(set) var playingTurnID: UUID?
    @Published private(set) var latency: [LatencySample] = []
    @Published var showLatency: Bool = UserDefaults.standard.bool(forKey: "showLatency") {
        didSet { UserDefaults.standard.set(showLatency, forKey: "showLatency") }
    }

    var serverDescription: String { tokens.serverDescription }

    private let audio = AudioIO()
    private let tokens = TokenClient()
    private var prepared: [Lang: TranslationSocket] = [:]
    private var preparing: Set<Lang> = []
    private var sockets: [UUID: TranslationSocket] = [:]
    private var closed: Set<UUID> = []
    private var liveTurnID: UUID?
    private var replayingID: UUID?
    private var running = false
    private let log = Logger(subsystem: "interp", category: "latency")

    init() {
        audio.onRouteChange = { [weak self] name in DispatchQueue.main.async { self?.route = name } }
        audio.onLevel = { [weak self] v in DispatchQueue.main.async { self?.level = v } }
        audio.onPlaybackDrained = { [weak self] in self?.playbackDrained() }
        audio.onInterruption = { [weak self] began in if began { self?.handleInterruptionBegan() } }
    }

    // MARK: 시작·종료

    func start() async {
        guard !running else { return }
        mic = await Self.micPermission(request: true)
        guard mic == .granted else { return }
        do {
            try audio.start()
            running = true
        } catch {
            connectionError = "오디오를 시작할 수 없어요: \(error.localizedDescription)"
            return
        }
        prepare(leftLang)
        prepare(rightLang)
    }

    func recheckMic() async {
        mic = await Self.micPermission(request: false)
        if mic == .granted { await start() }
    }

    func suspend() {
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
        if !running { Task { await start() } } else { prepare(leftLang); prepare(rightLang) }
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
        switch phase {
        case .listening(let l):
            if l == lang { finishListening() }
        case .idle:
            startListening(lang)
        case .finishing, .playing:
            interruptPlayback()
            startListening(lang)
        }
    }

    func swapLanguages() {
        guard phase == .idle else { return }
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
        phase = .listening(source)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()

        audio.onMicChunk = { [weak self] chunk in
            DispatchQueue.main.async { self?.micChunk(chunk, turn: id) }
        }
        audio.beginCapture()

        if let s = prepared.removeValue(forKey: target), !s.isStale {
            attach(s, to: id)
        } else {
            Task {
                do {
                    let t = try await tokens.ticket(target: target)
                    let s = TranslationSocket(target: target, ticket: t)
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
        s.onEvent = { [weak self] e in self?.turnEvent(e, turn: id) }
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
        guard index(id) != nil else { return }
        switch e {
        case .inputText(let d):
            update(id) { $0.sourceText += d }
        case .outputText(let d):
            update(id) { $0.targetText += d }
        case .audio(let pcm):
            update(id) {
                $0.outputAudio.append(pcm)
                if $0.metrics.tFirstAudio == nil { $0.metrics.tFirstAudio = CFAbsoluteTimeGetCurrent() }
            }
            if let t = turns.first(where: { $0.id == id }), t.status != .listening { flushHeldAudio(id) }
        case .closed:
            closed.insert(id)
            sockets[id] = nil
            update(id) { $0.metrics.tClosed = CFAbsoluteTimeGetCurrent() }
            if let t = turns.first(where: { $0.id == id }), t.outputAudio.isEmpty {
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
        audio.enqueue(pcm16: t.outputAudio.subdata(in: t.playedBytes..<t.outputAudio.count))
        turns[i].playedBytes = t.outputAudio.count
        if turns[i].metrics.tPlaybackStart == nil, turns[i].metrics.tStop != nil {
            turns[i].metrics.tPlaybackStart = CFAbsoluteTimeGetCurrent()
        }
        turns[i].status = .playing
        playingTurnID = id
        phase = .playing
    }

    private func playbackDrained() {
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
        audio.enqueue(pcm16: t.outputAudio)
    }

    func stopPlayback() {
        if phase == .playing { interruptPlayback() }
    }

    func retry(_ id: UUID) {
        guard let i = index(id), !turns[i].inputAudio.isEmpty, !turns[i].isLive else { return }
        if phase != .idle { interruptPlayback() }
        let target = turns[i].target
        turns[i].targetText = ""
        turns[i].sourceText = ""
        turns[i].outputAudio = Data()
        turns[i].playedBytes = 0
        turns[i].status = .translating
        turns[i].metrics = TurnMetrics(tTap: nil, tStop: CFAbsoluteTimeGetCurrent())
        closed.remove(id)
        liveTurnID = id
        phase = .finishing(turns[i].source)
        Task {
            do {
                let s: TranslationSocket
                if let p = prepared.removeValue(forKey: target), !p.isStale { s = p } else {
                    s = TranslationSocket(target: target, ticket: try await tokens.ticket(target: target))
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
        guard running else { return }
        if let s = prepared[target], !s.isStale { return }
        prepared[target]?.cancel()
        prepared[target] = nil
        guard !preparing.contains(target) else { return }
        preparing.insert(target)
        Task {
            defer { preparing.remove(target) }
            do {
                let t = try await tokens.ticket(target: target)
                let s = TranslationSocket(target: target, ticket: t)
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
        log.info("turn \(s.direction, privacy: .public) speech=\(speech, format: .fixed(precision: 2)) endToFirstSound=\(s.endToFirstSound ?? -1, format: .fixed(precision: 3)) endToClosed=\(s.endToClosed ?? -1, format: .fixed(precision: 3)) route=\(self.route, privacy: .public)")
    }
}
