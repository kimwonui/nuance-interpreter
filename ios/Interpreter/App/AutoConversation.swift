import Foundation
import os

/// Hands-free conversation: one tap starts the mic, then NUA keeps listening, works out whether
/// Korean or English was spoken, and plays the interpretation in the other language.
///
/// How the direction is decided (checked against the API on 2026-10-24):
/// - gpt-realtime-translate has one output language per session and no detected-language event, so
///   two sessions run side by side (→English and →Korean) on the same mic audio.
/// - The →English session also returns the source transcript (gpt-4o-mini-transcribe, enabled from the
///   client). Hangul vs. Latin letters in that text picks the direction; the other session's output is
///   dropped. (Relying on "same-language input stays silent" alone failed: the →English session
///   sometimes repeated English input.)
/// - Fallback if no transcript arrives: Korean input left the →Korean session silent in testing, so a
///   →Korean session that produced speech means the input was English.
///
/// Audio is sent only while someone is speaking (0.5 s pre-roll + 1.5 s tail), never during silence or
/// while NUA is playing (no feedback loop). With echo cancellation on, talking over NUA cuts it off.
@MainActor
final class AutoConversation {
    enum State: Equatable { case off, connecting, waiting, hearing, interpreting, speaking, muted }

    private(set) var state: State = .off { didSet { if state != oldValue { onState?(state) } } }
    var onState: ((State) -> Void)?
    var onNewTurn: ((Turn) -> Void)?
    var onUpdateTurn: ((UUID, (inout Turn) -> Void) -> Void)?
    var onPlaying: ((UUID?) -> Void)?
    var onError: ((String) -> Void)?
    var report: (([String: Any]) -> Void)?

    static let transcribeModel = "gpt-4o-mini-transcribe"
    static let preRollChunks = 5   // 0.5 s kept before speech is detected, so the first syllable isn't lost
    static let tailChunks = 15     // 1.5 s sent after the speaker stops, so the model can finish
    static let fallbackDelay = 2.0 // s after the end of speech without a transcript

    private struct Utterance {
        var tStart: Double
        var tLastVoice: Double
        var tEnd: Double?
        var detected: Lang?
        var decidedBy = ""
        var tDecision: Double?
        var tFirstPlay: Double?
        var out: [Lang: Data] = [:]
        var text: [Lang: String] = [:]
        var voiced: Set<Lang> = []
        var transcript = ""
        var turnID: UUID?
        var gate = Turn(source: .ko, target: .en) // silence-gate state for playback
        var sentChunks = 0
        var reported = false
    }

    private let audio: AudioIO
    private let makeSocket: (Lang) async throws -> TranslationSocket
    private var pair: (Lang, Lang) = (.ko, .en)
    private var sockets: [Lang: TranslationSocket] = [:] // keyed by output language
    private var connecting: Set<Lang> = []
    private var failures = 0
    private var vad = SpeechDetector()
    private var preRoll: [Data] = []
    private var sending = false
    private var tailLeft = 0
    private var u: Utterance?
    private var fallbackWork: DispatchWorkItem?
    private var holdoffUntil: Double = 0
    /// What NUA last said out loud, to recognise its own voice coming back through the mic.
    private var lastSpoken: (text: String, lang: Lang, end: Double)?
    private let log = Logger(subsystem: "interp", category: "auto")

    init(audio: AudioIO, makeSocket: @escaping (Lang) async throws -> TranslationSocket) {
        self.audio = audio
        self.makeSocket = makeSocket
    }

    var isOn: Bool { state != .off }
    private var now: Double { CFAbsoluteTimeGetCurrent() }
    private func other(_ l: Lang) -> Lang { l == pair.0 ? pair.1 : pair.0 }
    /// The session that also carries the source transcript (any one would do; →English is used).
    private var transcriptTarget: Lang { pair.0 == .en ? pair.0 : pair.1 }

    // MARK: Control

    func start(pair: (Lang, Lang)) {
        guard state == .off else { return }
        self.pair = pair
        failures = 0
        vad.reset()
        preRoll.removeAll()
        sending = false
        u = nil
        state = .connecting
        connect(pair.0)
        connect(pair.1)
    }

    func stop() {
        finishUtterance()
        fallbackWork?.cancel()
        sockets.values.forEach { $0.cancel() }
        sockets.removeAll()
        sending = false
        u = nil
        audio.stopPlayback()
        onPlaying?(nil)
        state = .off
    }

    func setMuted(_ muted: Bool) {
        guard state != .off else { return }
        sending = false
        vad.reset()
        preRoll.removeAll()
        state = muted ? .muted : .waiting
    }

    // MARK: Mic (100 ms chunks, main thread)

    func mic(_ chunk: Data) {
        guard state != .off, state != .muted else { return }
        let level = SilenceGate.rms(chunk)
        preRoll.append(chunk)
        if preRoll.count > Self.preRollChunks { preRoll.removeFirst(preRoll.count - Self.preRollChunks) }

        let playing = audio.isPlaying
        var sentThisChunk = false
        if !playing, now < holdoffUntil { return } // tail of NUA's own voice right after playback
        if let event = vad.feed(level, bargeIn: playing) {
            switch event {
            case .start:
                if playing { bargeIn() }
                beginUtterance()          // sends the pre-roll, which already contains this chunk
                sentThisChunk = true
            case .end:
                endUtterance()
            }
        }
        if vad.speaking, level > 0.012, !playing { u?.tLastVoice = now }
        if sending && !sentThisChunk && !playing {
            send(chunk)
            if !vad.speaking {
                tailLeft -= 1
                if tailLeft <= 0 { sending = false }
            }
        }
    }

    private func send(_ chunk: Data) {
        for s in sockets.values { s.appendAudio(chunk) }
        u?.sentChunks += 1
    }

    private func beginUtterance() {
        let t = now
        if let cur = u, cur.detected == nil, let end = cur.tEnd, t - end < 2.0 {
            // The speaker resumed after a short pause before anything was interpreted: same utterance.
            u?.tEnd = nil
            fallbackWork?.cancel()
        } else {
            finishUtterance()
            u = Utterance(tStart: t, tLastVoice: t)
        }
        for l in [pair.0, pair.1] where sockets[l] == nil { connect(l) }
        sending = true
        tailLeft = Self.tailChunks
        for c in preRoll { send(c) }
        state = .hearing
    }

    private func endUtterance() {
        guard u != nil else { return }
        u?.tEnd = now
        tailLeft = Self.tailChunks
        if u?.detected == nil {
            state = .interpreting
            let w = DispatchWorkItem { [weak self] in self?.fallbackDecide() }
            fallbackWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.fallbackDelay, execute: w)
        } else if state == .hearing {
            state = audio.isPlaying ? .speaking : .interpreting
        }
    }

    private func bargeIn() {
        audio.stopPlayback()
        if let cur = u, let det = cur.detected, let text = cur.text[other(det)], !text.isEmpty {
            lastSpoken = (text, other(det), now) // the pre-roll may contain NUA's own last words
        }
        if let id = u?.turnID {
            onUpdateTurn?(id) { $0.status = .interrupted }
            report?(["mode": "cutin", "route": "auto"])
        }
        onPlaying?(nil)
    }

    // MARK: Session events

    private func event(_ e: TranslationSocket.Event, from s: TranslationSocket) {
        let target = s.target
        guard sockets[target] === s else { return }
        switch e {
        case .opened:
            failures = 0
            if state == .connecting, sockets.count == 2, sockets.values.allSatisfy({ $0.openedAt != nil }) { state = .waiting }
        case .inputText(let d):
            guard u != nil else { return }
            u?.transcript += d
            if u?.detected == nil, let lang = Self.language(of: u?.transcript ?? "") { decide(lang, by: "transcript") }
        case .outputText(let d):
            guard u != nil else { return }
            u?.text[target, default: ""] += d
            if let det = u?.detected, target == other(det), let id = u?.turnID { onUpdateTurn?(id) { $0.targetText += d } }
        case .audio(let pcm):
            guard u != nil else { return } // output with no utterance (e.g. after Stop) is ignored
            u?.out[target, default: Data()].append(pcm)
            if u?.voiced.contains(target) == false, SilenceGate.hasVoice(pcm) { u?.voiced.insert(target) }
            if let det = u?.detected, target == other(det) { play(pcm) }
        case .closed, .failed:
            sockets[target] = nil
            s.cancel()
            guard state != .off else { return }
            var msg = "Connection closed"
            if case .failed(let m) = e { msg = m }
            failures += 1
            log.error("session \(target.rawValue, privacy: .public) ended: \(msg, privacy: .public)")
            if failures > 3 { onError?(msg); stop(); return }
            // Reconnect now (bounded); the next utterance would also reconnect on demand.
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures) * 0.8) { [weak self] in self?.connect(target) }
        }
    }

    private func connect(_ target: Lang) {
        guard state != .off, sockets[target] == nil, !connecting.contains(target) else { return }
        connecting.insert(target)
        Task {
            defer { connecting.remove(target) }
            do {
                let s = try await makeSocket(target)
                guard state != .off, sockets[target] == nil else { s.cancel(); return }
                if target == transcriptTarget { s.transcribeModel = Self.transcribeModel }
                s.onEvent = { [weak self, weak s] e in
                    guard let self, let s else { return }
                    self.event(e, from: s)
                }
                sockets[target] = s
                s.connect()
            } catch {
                failures += 1
                if failures > 3 { onError?(error.localizedDescription); stop(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(failures) * 0.8) { [weak self] in self?.connect(target) }
            }
        }
    }

    // MARK: Direction + playback

    private func decide(_ lang: Lang, by: String) {
        guard var cur = u, cur.detected == nil else { return }
        fallbackWork?.cancel()
        // Echo guard: the transcript is in the language NUA just spoke and matches what it said → ignore.
        if let last = lastSpoken, last.lang == lang, now - last.end < 10,
           Self.similarity(cur.transcript, last.text) >= 0.5 {
            u?.detected = lang
            u?.reported = true
            report?(["mode": "auto:echo-ignored", "speechSec": cur.tLastVoice - cur.tStart])
            log.info("echo ignored")
            if state != .hearing { state = .waiting }
            return
        }
        let target = other(lang)
        cur.detected = lang
        cur.decidedBy = by
        cur.tDecision = now
        var turn = Turn(source: lang, target: target)
        turn.status = .translating
        turn.targetText = cur.text[target] ?? ""
        if Self.language(of: cur.transcript) == lang { turn.sourceText = cur.transcript.trimmingCharacters(in: .whitespacesAndNewlines) }
        turn.metrics.tTap = cur.tStart
        turn.metrics.tStop = cur.tLastVoice
        cur.turnID = turn.id
        u = cur
        onNewTurn?(turn)
        if let held = cur.out[target], !held.isEmpty { play(held) }
        if state == .interpreting || state == .waiting, !audio.isPlaying { state = .interpreting }
    }

    private func fallbackDecide() {
        guard let cur = u, cur.detected == nil, cur.tEnd != nil else { return }
        if cur.voiced.contains(.ko) {
            decide(.en, by: "fallback")
        } else if cur.voiced.contains(.en) {
            decide(.ko, by: "fallback")
        } else {
            // Nothing came back (very short reply, noise, or the model is still waiting for context).
            report?(["mode": "auto:empty", "speechSec": cur.tLastVoice - cur.tStart, "route": "sent \(String(format: "%.1f", Double(cur.sentChunks) / 10))s x2"])
            u?.reported = true
            if state == .interpreting { state = .waiting }
        }
    }

    private func play(_ pcm: Data) {
        guard var cur = u, let id = cur.turnID else { return }
        var gate = cur.gate
        let audible = SilenceGate.process(pcm, turn: &gate)
        cur.gate = gate
        onUpdateTurn?(id) { $0.outputAudio.append(pcm) } // full output kept in memory for Replay
        if !audible.isEmpty {
            if cur.tFirstPlay == nil {
                let t = now
                cur.tFirstPlay = t
                onUpdateTurn?(id) { $0.metrics.tPlaybackStart = t; $0.status = .playing }
            }
            sending = false // half-duplex: the mic isn't streamed while NUA talks
            audio.enqueue(pcm16: audible)
            onPlaying?(id)
            state = .speaking
        }
        u = cur
    }

    /// Called by the controller when queued playback finishes.
    func playbackDrained() {
        guard state == .speaking else { return }
        onPlaying?(nil)
        holdoffUntil = now + 0.4
        if let cur = u, let det = cur.detected, let text = cur.text[other(det)], !text.isEmpty {
            lastSpoken = (text, other(det), now)
        }
        if let id = u?.turnID { onUpdateTurn?(id) { if $0.status == .playing { $0.status = .done } } }
        reportUtterance()
        vad.reset() // the tail of NUA's own voice must not open a new utterance
        state = .waiting
    }

    private func finishUtterance() {
        guard let cur = u else { return }
        if let id = cur.turnID { onUpdateTurn?(id) { if $0.status == .translating || $0.status == .playing { $0.status = .done } } }
        reportUtterance()
    }

    private func reportUtterance() {
        guard let cur = u, !cur.reported, let det = cur.detected else { return }
        u?.reported = true
        var m: [String: Any] = [
            "direction": "\(det.code)→\(other(det).code)",
            "speechSec": cur.tLastVoice - cur.tStart,
            "mode": "auto:\(cur.decidedBy)",
            "route": "sent \(String(format: "%.1f", Double(cur.sentChunks) / 10))s x2",
            "trimmedLeadSec": Double(cur.gate.metrics.trimmedLeadBytes) / 48_000,
            "trimmedTailSec": Double(cur.gate.metrics.trimmedTailBytes + cur.gate.pendingSilence.count) / 48_000,
        ]
        // Speech end = last voiced mic chunk. "endToFirstVoicedArrival" here carries the direction-decision delay.
        if let p = cur.tFirstPlay { m["endToFirstSound"] = p - cur.tLastVoice }
        if let d = cur.tDecision { m["endToFirstVoicedArrival"] = d - cur.tLastVoice }
        report?(m)
    }

    /// Character-bigram overlap (Dice) on letters only; works for Korean and English.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> [String: Int] {
            let chars = Array(s.lowercased().unicodeScalars.filter { CharacterSet.letters.contains($0) })
            var g: [String: Int] = [:]
            if chars.count < 2 { return g }
            for i in 0..<(chars.count - 1) { g["\(chars[i])\(chars[i + 1])", default: 0] += 1 }
            return g
        }
        let ga = grams(a), gb = grams(b)
        let total = ga.values.reduce(0, +) + gb.values.reduce(0, +)
        guard total > 0 else { return 0 }
        let common = ga.reduce(0) { $0 + min($1.value, gb[$1.key] ?? 0) }
        return 2 * Double(common) / Double(total)
    }

    /// Korean if the text is mostly Hangul, English if mostly Latin letters, nil if too little to tell.
    static func language(of text: String) -> Lang? {
        var hangul = 0, latin = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0xAC00...0xD7A3, 0x1100...0x11FF, 0x3130...0x318F: hangul += 1
            case 65...90, 97...122: latin += 1
            default: break
            }
        }
        if hangul == 0 && latin < 2 { return nil }
        return hangul * 2 >= latin ? .ko : .en // one Hangul syllable ≈ 2–3 Latin letters
    }
}
