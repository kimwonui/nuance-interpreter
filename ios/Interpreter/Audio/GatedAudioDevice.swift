import AVFoundation
import WebRTC
import os

/// Custom WebRTC audio device for GPT-Live hands-free mode.
///
/// GPT-Live has no turn-detection setting, so the owner's "wait ~0.5 s after the speaker stops" rule is
/// enforced here, on the phone:
/// - Mic: AVAudioEngine input with Apple voice processing (echo cancellation) → 48 kHz mono PCM16 → WebRTC.
///   A local speech detector (adaptive noise floor) records when the user last spoke.
/// - Speaker: NUA's audio is pulled from WebRTC continuously into a buffer and is released only once the mic
///   has been quiet long enough since the last speech: `holdSeconds` when NUA started after the speaker had
///   already stopped (the model judged the sentence finished), `earlyHoldSeconds` when NUA's audio began while
///   the speaker was still talking or they kept talking over the held audio (likely a breath mid-sentence).
///   If the user resumes before that, it stays on hold and the count restarts from the new last speech.
/// - While NUA plays, the first ~0.12 s of the user's voice pauses it (buffer kept); ~0.35 s confirms a cut-in
///   (buffer cleared, the muted start of the interruption handed to the model). A false alarm resumes.
/// - NUA's own pauses are kept as generated (up to `maxGap` each): no silence skipping, no rate change.
/// This is a hold-until-pause gate, not a fixed delay: audio produced early waits for the pause.
final class GatedAudioDevice: NSObject, RTCAudioDevice {
    static let rate: Double = 48_000

    /// Owner's latest priority is near-instant output: a short guard so NUA doesn't start while the speaker is
    /// mid-word, not a full pause rule (was 0.5 s).
    var holdSeconds: Double = 0.2
    /// Hold for audio the model produced while the speaker was still talking: long enough to ride over a
    /// breath or hesitation inside a sentence, short enough to feel prompt after the sentence really ends.
    var earlyHoldSeconds: Double = 0.6
    /// NUA's silences up to this length are played as generated (its rhythm and meaningful pauses).
    private static let maxGap = 1.0
    /// Mic level and the level of audio actually played (called at ~10 Hz on audio threads).
    var onLevels: ((Float, Float) -> Void)?
    /// Seconds from the user's last speech to the first released NUA audio of a turn.
    var onRelease: ((Double, Bool) -> Void)?
    /// true while NUA's voice is buffered and waiting for the user's pause (real gate state, not a timer).
    var onHoldChange: ((Bool) -> Void)?
    /// NUA's turn is playing (true from release until the turn really ends: pauses inside the translation
    /// shorter than `turnGap` don't end it; a cut-in, a voice pause, Stop or a discard do).
    var onPlayingChange: ((Bool) -> Void)?
    /// A cut-in stopped NUA: mic level and NUA's playing level at that moment (diagnostics).
    var onCutIn: ((Float, Float) -> Void)?
    /// The phone detected the user (or the other person) starting to speak.
    var onUserVoice: (() -> Void)?
    /// NUA audio that arrived with no detected speech before it was discarded (seconds of audio).
    var onDroppedUnprompted: ((Double) -> Void)?
    /// The user's voice paused NUA mid-playback (before a cut-in was confirmed).
    var onSoftPause: (() -> Void)?
    /// A NUA turn finished playing: seconds of audio played (with its pauses), seconds of over-long silence skipped.
    var onTurnPlayed: ((Double, Double) -> Void)?
    private var holdingReported = false
    private var playingReported = false

    private weak var adm: RTCAudioDeviceDelegate?
    /// Rebuilt from scratch whenever WebRTC restarts audio after a full stop, so every session's audio path is
    /// set up exactly like the first one (Stop → Start used to leave the second session without audio).
    private var engine = AVAudioEngine()
    private var source: AVAudioSourceNode?
    private var converter: AVAudioConverter?
    private let pcm16 = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: GatedAudioDevice.rate, channels: 1, interleaved: true)!
    private let floatFormat = AVAudioFormat(standardFormatWithSampleRate: GatedAudioDevice.rate, channels: 1)!
    private let log = Logger(subsystem: "interp", category: "gate")

    // Shared between the mic tap thread and the render thread.
    private var lock = os_unfair_lock()
    private var ring = Ring(capacity: Int(GatedAudioDevice.rate) * 30)
    private var lastVoice: Double = 0
    private var releasing = false
    private var noiseFloor: Float = 0.004
    private var voiceRun = 0
    private var silentQueued = 0 // consecutive silent samples queued (NUA's current pause)
    /// Half-duplex echo guard: while NUA's voice plays (and 0.4 s after), the model receives silence instead
    /// of the mic, so it can never hear and re-translate its own voice. Local cut-in detection still runs.
    private var suppressUntil: Double = 0
    private var lastReleaseEnd: Double = 0
    /// Last time NUA's incoming audio had speech. NUA's turn stays "playing" through gaps shorter than
    /// `turnGap`, so a small sound between its phrases can't re-arm the hold and pause it mid-translation.
    private var lastNuaVoice: Double = 0
    private static let turnGap = 0.6
    /// Smoothed level of what NUA is playing; echo of NUA's own voice tracks it, a real interruption exceeds it.
    private var outLevel: Float = 0
    /// Speech was detected since NUA last started a turn. NUA may only start speaking after real speech
    /// (owner rule: never produce what nobody said). Continuations within 2 s of its last turn are allowed.
    private var voiceSinceTurn = false
    private var heldSince: Double = 0
    /// The held audio began while the speaker was talking, or they kept talking over it → `earlyHoldSeconds`.
    private var earlyAudio = false
    /// NUA paused by the user's voice, waiting for a confirmed cut-in or a resume (0 = not paused).
    private var pausedAt: Double = 0
    /// Notification sounds, synthesized once. Mixed into NUA's own output (so Apple's echo canceller removes them
    /// from the mic) while the model gets silence and the speech detector ignores the mic (so a chime can never
    /// count as someone speaking or cut NUA off). That window is only the chime itself + 50 ms of echo decay
    /// (≈ 0.27 s for the turn chime): people start talking ~0.3 s or more after hearing a cue, so their first
    /// words arrive after it. The muted window is not replayed to the model afterwards, because it contains the
    /// chime itself.
    enum Chime { case start, yourTurn }
    private static func tones(_ notes: [(freq: Double, at: Double)], length: Double, amp: Float) -> [Float] {
        var out = [Float](repeating: 0, count: Int(rate * length))
        for note in notes {
            for i in Int(note.at * rate)..<out.count {
                let t = Double(i) / rate - note.at
                let fadeOut = min(1, Double(out.count - i) / (rate * 0.03)) // ends at silence: no click, short window
                let env = min(1, t / 0.005) * exp(-t / 0.07) * fadeOut
                out[i] += amp * Float(env * (sin(2 * .pi * note.freq * t) + 0.25 * sin(4 * .pi * note.freq * t)))
            }
        }
        return out
    }
    /// Start: two rising notes. Your turn (NUA finished speaking a translation): a quick two-note "ti-ring".
    private static let startChime = tones([(1046.5, 0), (1568.0, 0.09)], length: 0.3, amp: 0.16)
    private static let yourTurnChime = tones([(1318.5, 0), (1760.0, 0.06)], length: 0.22, amp: 0.12)
    private var chime: [Float] = []
    private var chimePos = 0
    /// Ding when NUA finishes speaking a translation, so the other person knows it's their turn (two-way only;
    /// set per session by the controller, kept across resets).
    private var turnEndChime = false

    func setTurnEndChime(_ on: Bool) {
        os_unfair_lock_lock(&lock); turnEndChime = on; os_unfair_lock_unlock(&lock)
    }
    private var chimeUntil: Double = 0 // speech detection ignores the mic until then (chime + echo tail)

    func playChime(_ c: Chime) {
        os_unfair_lock_lock(&lock)
        startChimeLocked(c)
        os_unfair_lock_unlock(&lock)
    }

    private func startChimeLocked(_ c: Chime) {
        chime = c == .start ? Self.startChime : Self.yourTurnChime
        chimePos = 0
        let until = CFAbsoluteTimeGetCurrent() + Double(chime.count) / Self.rate + 0.05
        chimeUntil = until
        suppressUntil = max(suppressUntil, until)
    }

    /// The speaker tapped "I'm done" (orb) — also mid-sentence. Releases held audio at once and lets the next audio
    /// of this turn play without waiting for a pause, even if the mic still hears voice. Expires after 6 s.
    private var userDoneAt: Double = 0
    /// After a "done" tap the model hears silence instead of the mic (up to 4 s, until NUA starts speaking): the turn
    /// ends at the tap, and silence after speech is what GPT-Live's own turn-taking listens for.
    private var tapMuteUntil: Double = 0
    enum FinishResult { case releasedHeld, waitingForModel, nothingHeard }
    struct FinishInfo { let result: FinishResult; let quietFor: Double; let heldSec: Double }

    /// `heardByModel`: the model's own input transcript has text since the last turn — proof that real speech
    /// reached it even if this phone's detector (0.15 s above the noise bar) didn't count it as speech.
    func finishTurn(heardByModel: Bool) -> FinishInfo {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let now = CFAbsoluteTimeGetCurrent()
        let continuation = lastReleaseEnd > 0 && now - lastReleaseEnd < 2.0
        if !voiceSinceTurn, heardByModel { voiceSinceTurn = true }
        let info = { (r: FinishResult) in FinishInfo(result: r, quietFor: now - self.lastVoice, heldSec: Double(self.ring.count) / Self.rate) }
        // Never release what nobody said (same rule as the gate).
        guard voiceSinceTurn || continuation || pausedAt > 0 else { return info(.nothingHeard) }
        userDoneAt = now
        tapMuteUntil = now + 4
        return info(ring.isEmpty && pausedAt == 0 ? .waitingForModel : .releasedHeld)
    }

    /// Wrong-direction output was cut: ignore NUA's audio until the next detected speech.
    private var discarding = false
    private var turnPlayed = 0
    private var turnSkipped = 0
    /// Last 0.8 s of the REAL mic (before muting), kept on the mic thread. On a cut-in the muted part of the
    /// interruption is sent to the model first, so its start is not lost (and nothing is sent twice).
    private var micHistory = [Int16](repeating: 0, count: Int(GatedAudioDevice.rate * 0.8))
    private var historyWrite = 0
    private var historyFill = 0
    private var mutedTail = 0 // most recent consecutive samples the model received as silence
    private var flushPreRoll = false

    // Render-thread scratch (preallocated).
    private var pull = [Int16](repeating: 0, count: 8_192)
    private var playTime: Double = 0
    private var recTime: Double = 0
    private var levelTick: Double = 0
    private var lastMic: Float = 0
    /// Samples seen since the last reset (diagnostics: proves the mic and playout are actually running).
    private var micSamples = 0
    private var renderSamples = 0

    private(set) var isInitialized = false
    private(set) var isPlayoutInitialized = false
    private(set) var isPlaying = false
    private(set) var isRecordingInitialized = false
    private(set) var isRecording = false

    var deviceInputSampleRate: Double { Self.rate }
    var inputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var inputNumberOfChannels: Int { 1 }
    var inputLatency: TimeInterval { AVAudioSession.sharedInstance().inputLatency }
    var deviceOutputSampleRate: Double { Self.rate }
    var outputIOBufferDuration: TimeInterval { AVAudioSession.sharedInstance().ioBufferDuration }
    var outputNumberOfChannels: Int { 1 }
    var outputLatency: TimeInterval { AVAudioSession.sharedInstance().outputLatency }

    /// Clears queued NUA audio and gate state (new session / Stop), so nothing from a previous session plays.
    func reset() {
        os_unfair_lock_lock(&lock)
        ring.clear()
        releasing = false
        lastVoice = 0
        voiceRun = 0
        silentQueued = 0
        suppressUntil = 0
        lastReleaseEnd = 0
        lastNuaVoice = 0
        outLevel = 0
        voiceSinceTurn = false
        heldSince = 0
        userDoneAt = 0
        tapMuteUntil = 0
        chime = []
        chimePos = 0
        chimeUntil = 0
        earlyAudio = false
        pausedAt = 0
        discarding = false
        turnPlayed = 0
        turnSkipped = 0
        micSamples = 0
        renderSamples = 0
        os_unfair_lock_unlock(&lock)
        holdingReported = false
        playingReported = false
    }

    /// Stop NUA now and drop its queued and still-arriving audio until someone speaks again (one-way mode, when
    /// NUA answered or translated the other person).
    func discardUntilVoice() {
        os_unfair_lock_lock(&lock)
        ring.clear()
        releasing = false
        pausedAt = 0
        earlyAudio = false
        voiceSinceTurn = false
        discarding = true
        os_unfair_lock_unlock(&lock)
    }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        adm = delegate
        isInitialized = true
        return true
    }

    func terminateDevice() -> Bool {
        _ = stopPlayout()
        _ = stopRecording()
        teardown()
        isInitialized = false
        return true
    }

    func initializePlayout() -> Bool { isPlayoutInitialized = setup(); return isPlayoutInitialized }
    func initializeRecording() -> Bool { isRecordingInitialized = setup(); return isRecordingInitialized }

    func startPlayout() -> Bool { reset(); isPlaying = startEngine(); return isPlaying }
    func startRecording() -> Bool { isRecording = startEngine(); return isRecording }

    func stopPlayout() -> Bool { isPlaying = false; reset(); stopEngineIfIdle(); return true }
    func stopRecording() -> Bool { isRecording = false; stopEngineIfIdle(); return true }

    // MARK: Engine

    private func setup() -> Bool {
        if source != nil { return true }
        engine = AVAudioEngine()
        configureSession()
        do { try engine.inputNode.setVoiceProcessingEnabled(true) } catch { log.error("voice processing: \(error.localizedDescription, privacy: .public)") }
        let node = AVAudioSourceNode(format: floatFormat) { [unowned self] _, _, frameCount, abl -> OSStatus in
            self.render(frameCount: Int(frameCount), abl: abl)
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: floatFormat)
        source = node
        let inFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0 else { log.error("no mic input"); return false }
        converter = AVAudioConverter(from: inFormat, to: pcm16)
        engine.inputNode.installTap(onBus: 0, bufferSize: 480, format: inFormat) { [weak self] buffer, _ in
            self?.captured(buffer)
        }
        engine.prepare()
        return true
    }

    private func startEngine() -> Bool {
        // WebRTC calls start again after a full stop without re-initializing, so rebuild here if needed.
        guard setup() else { return false }
        if engine.isRunning { return true }
        configureSession() // push-to-talk may have changed the session in between
        do {
            try engine.start()
            ensureSpeaker()
            return true
        } catch {
            log.error("engine start: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Both directions stopped (Stop / session ended): release the mic completely and drop the engine, so the
    /// next start builds a fresh one instead of restarting a stopped voice-processing engine.
    private func stopEngineIfIdle() {
        guard !isPlaying, !isRecording, source != nil else { return }
        releaseEngine()
    }

    private func releaseEngine() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        if let source { engine.detach(source) }
        source = nil
        converter = nil
    }

    private func teardown() {
        if source != nil { releaseEngine() }
        os_unfair_lock_lock(&lock); ring.clear(); releasing = false; os_unfair_lock_unlock(&lock)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        do {
            // Face-to-face interpreter: built-in speaker by default; a connected headset/Bluetooth is respected.
            try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try s.setPreferredSampleRate(Self.rate)
            try s.setPreferredIOBufferDuration(0.01)
            try s.setActive(true)
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// If playback is on the earpiece, switch to the built-in speaker (headphones/Bluetooth untouched).
    /// Diagnostics: is Apple voice processing really on, and the current noise floor.
    var diagnostics: String {
        os_unfair_lock_lock(&lock); let nf = noiseFloor; let m = micSamples; let r = renderSamples; os_unfair_lock_unlock(&lock)
        guard source != nil else { return String(format: "no engine nf %.3f", nf) }
        // "mic/out" = seconds of mic input and playout pulled since the session started (0 = not running).
        return String(format: "vp %@ nf %.3f mic %.1f out %.1f", engine.inputNode.isVoiceProcessingEnabled ? "on" : "off", nf,
                      Double(m) / Self.rate, Double(r) / Self.rate)
    }

    /// Short form for per-turn metrics (the server keeps 40 characters).
    var diagnosticsShort: String {
        os_unfair_lock_lock(&lock); let nf = noiseFloor; os_unfair_lock_unlock(&lock)
        return String(format: "vp %@ nf %.3f", source != nil && engine.inputNode.isVoiceProcessingEnabled ? "on" : "off", nf)
    }

    func ensureSpeaker() {
        let s = AVAudioSession.sharedInstance()
        guard s.currentRoute.outputs.contains(where: { $0.portType == .builtInReceiver }) else { return }
        try? s.overrideOutputAudioPort(.speaker)
    }

    // MARK: Mic → WebRTC (+ speech detection)

    private func captured(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let adm else { return }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * Self.rate / buffer.format.sampleRate) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: pcm16, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
        let n = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<n { let v = Float(ch[0][i]) / 32_768; sum += v * v }
        let rms = sqrt(sum / Float(n))
        lastMic = rms
        detectSpeech(rms: rms, frames: n)
        os_unfair_lock_lock(&lock)
        micSamples += n
        // Paused by the user's voice: keep the model muted until it's a confirmed cut-in, so a false alarm
        // (e.g. NUA's own echo) never reaches the model.
        let tNow = CFAbsoluteTimeGetCurrent()
        let suppress = tNow < suppressUntil || pausedAt > 0 || tNow < tapMuteUntil
        let flush = flushPreRoll
        flushPreRoll = false
        os_unfair_lock_unlock(&lock)

        if flush {
            // Cut-in: give the model the interruption's opening that it received as silence. Only the most recent
            // muted run (in order, ≤ 0.5 s), so nothing is sent twice or out of order.
            let k = min(mutedTail, historyFill, Int(Self.rate * 0.5))
            if k > 0 {
                var pre = [Int16](repeating: 0, count: k)
                let start = (historyWrite - k + micHistory.count) % micHistory.count
                for i in 0..<k { pre[i] = micHistory[(start + i) % micHistory.count] }
                pre.withUnsafeMutableBufferPointer { deliver(adm, $0.baseAddress!, k) }
            }
            mutedTail = 0
        }
        for i in 0..<n {
            micHistory[historyWrite] = ch[0][i]
            historyWrite = (historyWrite + 1) % micHistory.count
        }
        historyFill = min(micHistory.count, historyFill + n)
        if suppress { memset(ch[0], 0, n * 2); mutedTail += n } else { mutedTail = 0 } // silence while NUA is audible
        deliver(adm, ch[0], n)
    }

    private func deliver(_ adm: RTCAudioDeviceDelegate, _ samples: UnsafeMutablePointer<Int16>, _ n: Int) {
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = recTime
        ts.mFlags = .sampleTimeValid
        recTime += Double(n)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 2), mData: UnsafeMutableRawPointer(samples)))
        _ = adm.deliverRecordedData(&flags, &ts, 1, UInt32(n), &abl, nil, nil)
    }

    private func detectSpeech(rms: Float, frames: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let playing = releasing
        let paused = pausedAt > 0
        if now < chimeUntil { os_unfair_lock_unlock(&lock); return } // our own chime, not someone speaking
        // While NUA plays, the voice must be above a fixed floor, above the noise floor, AND clearly above the
        // level NUA is playing at (its own echo follows that level; a person talking over it exceeds it).
        // Paused: NUA is silent, so no echo — a moderate bar. Otherwise: a lower bar, used to time the pause.
        let threshold = playing ? max(0.06, noiseFloor * 6, outLevel * 0.6)
            : paused ? max(0.03, noiseFloor * 4) : max(0.015, noiseFloor * 3)
        // Sustained speech, not clicks or coughs: ~0.35 s confirms a cut-in, ~0.12 s pauses NUA, ~0.15 s
        // otherwise. Brief dips are tolerated (leaky count) instead of resetting, so syllable gaps don't reset it.
        let needed = Int(Self.rate * (playing || paused ? 0.35 : 0.15))
        let pauseNeeded = Int(Self.rate * 0.12)
        let voiced = rms > threshold
        if voiced {
            // Bounded: the count only needs to reach `needed`; unbounded growth kept "still talking" alive for
            // seconds after the speaker stopped (≈2 s per 1 s of speech) and delayed every translation.
            voiceRun = min(voiceRun + frames, needed * 2)
        } else {
            voiceRun = max(0, voiceRun - frames / 2)
            // Learn the room's noise only from clearly non-speech sound, so quiet speech is never learned as noise.
            if !playing, !paused, rms < threshold * 0.5 { noiseFloor = min(0.02, noiseFloor * 0.995 + rms * 0.005) }
        }
        var cutIn: (Float, Float)?
        var newVoice = false
        var softPause = false
        if playing, voiced, voiceRun >= pauseNeeded, voiceRun < needed {
            // The speaker (or the other person) started talking over NUA: pause it now, keep what's queued.
            releasing = false
            pausedAt = now
            lastVoice = now
            softPause = true
        } else if voiceRun >= needed {
            // "Last speech" = an actually voiced moment, not the tail of the counter.
            if voiced { lastVoice = now }
            if !voiceSinceTurn { voiceSinceTurn = true; newVoice = true; discarding = false }
            // Still talking while NUA's audio waits → that audio was early (mid-sentence): wait longer for it.
            if !playing, !paused, !ring.isEmpty { earlyAudio = true }
            if playing || paused {
                cutIn = (rms, outLevel)
                flushPreRoll = true
                // Confirmed cut-in: stop NUA, drop what was queued, and let the mic through right away.
                ring.clear()
                userDoneAt = 0
                tapMuteUntil = 0
                releasing = false
                pausedAt = 0
                earlyAudio = false
                suppressUntil = 0
                lastReleaseEnd = now
                lastNuaVoice = 0
            }
        } else if paused, voiced {
            lastVoice = now
        }
        os_unfair_lock_unlock(&lock)
        if let cutIn { onCutIn?(cutIn.0, cutIn.1) }
        if softPause { onSoftPause?() }
        if newVoice { onUserVoice?() }
    }

    // MARK: WebRTC → hold-until-pause gate → speaker

    private func render(frameCount n: Int, abl: UnsafeMutablePointer<AudioBufferList>) {
        let out = UnsafeMutableAudioBufferListPointer(abl)
        guard let dst = out[0].mData?.assumingMemoryBound(to: Float.self) else { return }
        let count = min(n, pull.count)

        // Always pull from WebRTC so its jitter buffer keeps flowing.
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = playTime
        ts.mFlags = .sampleTimeValid
        playTime += Double(count)
        var pulledVoiced = false
        pull.withUnsafeMutableBytes { raw in
            var buf = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 2), mData: raw.baseAddress))
            if let adm { _ = adm.getPlayoutData(&flags, &ts, 0, UInt32(count), &buf) } else { memset(raw.baseAddress, 0, count * 2) }
        }
        var sum: Float = 0
        for i in 0..<count { let v = Float(pull[i]) / 32_768; sum += v * v }
        pulledVoiced = sqrt(sum / Float(max(count, 1))) > 0.004

        let now = CFAbsoluteTimeGetCurrent()
        var released: Double?
        var releasedEarly = false
        var turnDone: (Double, Double)?
        var outSum: Float = 0
        os_unfair_lock_lock(&lock)
        renderSamples += count
        // Queue NUA's speech with its own pauses (each up to `maxGap`), whether holding or playing a backlog:
        // skipping silence to drain a backlog squeezed the gaps between words and phrases and made NUA sound
        // rushed. Leading silence is not queued (latency, not rhythm); when caught up, silence plays as is.
        let quietFor = now - lastVoice
        if discarding {
            // Cut output (one-way wrong direction): drop the rest of that response.
        } else if pulledVoiced {
            if ring.isEmpty, !releasing, pausedAt == 0 { earlyAudio = quietFor < 0.15 } // began while they talked?
            pull.withUnsafeBufferPointer { ring.write($0.baseAddress!, count) }
            silentQueued = 0
            lastNuaVoice = now
        } else if !ring.isEmpty {
            if silentQueued < Int(Self.rate * Self.maxGap) {
                pull.withUnsafeBufferPointer { ring.write($0.baseAddress!, count) }
                silentQueued += count
            } else {
                turnSkipped += count
            }
        }
        if ring.isEmpty { heldSince = 0 } else if heldSince == 0 { heldSince = now }
        let continuation = lastReleaseEnd > 0 && now - lastReleaseEnd < 2.0
        let hold = earlyAudio ? earlyHoldSeconds : holdSeconds
        var dropped: Double?
        // "Done" tap still valid (6 s). Not cancelled by voice: tapping mid-sentence means "this turn ends now".
        let userDone = userDoneAt > 0 && now - userDoneAt < 6
        if pausedAt > 0 {
            // Paused by a voice that never became a cut-in (a short sound or echo): resume after a short quiet.
            if quietFor >= 0.3 || userDone { pausedAt = 0; releasing = true; voiceRun = 0; userDoneAt = 0; tapMuteUntil = 0 }
        } else if !releasing, !ring.isEmpty, quietFor >= hold || userDone, voiceSinceTurn || continuation {
            userDoneAt = 0
            tapMuteUntil = 0 // NUA is speaking now; the usual echo guard takes over
            releasing = true
            voiceRun = 0 // the speaker's leftover count must not read as talking over NUA's first syllable
            let wasEarly = earlyAudio
            earlyAudio = false
            if voiceSinceTurn {
                voiceSinceTurn = false
                // Report once per turn (a turn's audio can arrive in several pieces).
                if now - lastReleaseEnd > 1.0 { released = quietFor; releasedEarly = wasEarly }
            }
        } else if !releasing, !ring.isEmpty, !voiceSinceTurn, !continuation, now - heldSince > 1.5 {
            // NUA started talking with no detected speech before it: never play it.
            dropped = Double(ring.count) / Self.rate
            ring.clear()
            heldSince = 0
        }
        if releasing {
            let got = ring.read(into: dst, count)
            turnPlayed += got
            for i in 0..<got { outSum += dst[i] * dst[i] }
            // Mute the model's mic input only while NUA is actually audible, plus a short echo-decay tail.
            // (Muting for the whole "turn" cut the start of the user's reply.)
            if got > 0, sqrt(outSum / Float(got)) > 0.004 { suppressUntil = now + 0.15 }
            if got < count { for i in got..<count { dst[i] = 0 } }
            // NUA's turn ends only after a real gap, not at every pause between its phrases.
            if ring.isEmpty && !pulledVoiced && now - lastNuaVoice > Self.turnGap {
                releasing = false
                lastReleaseEnd = now
                turnDone = (Double(turnPlayed) / Self.rate, Double(turnSkipped) / Self.rate)
                turnPlayed = 0
                turnSkipped = 0
                // NUA finished this translation (not a cut-in or a discarded answer): "your turn" — unless someone
                // already started answering, so the ding never mutes the beginning of a reply.
                if turnEndChime, now - lastVoice > Self.turnGap { startChimeLocked(.yourTurn) }
            }
        } else {
            for i in 0..<count { dst[i] = 0 }
        }
        let level = sqrt(outSum / Float(max(count, 1)))
        outLevel = releasing ? outLevel * 0.8 + level * 0.2 : 0
        // Mix the chime on top (after the level, so it never counts as NUA's voice).
        if chimePos < chime.count {
            let k = min(count, chime.count - chimePos)
            for i in 0..<k { dst[i] += chime[chimePos + i] }
            chimePos += k
        }
        let holdingNow = !releasing && !ring.isEmpty
        let playingNow = releasing
        os_unfair_lock_unlock(&lock)
        if count < n { for i in count..<n { dst[i] = 0 } }

        if let released { onRelease?(released, releasedEarly) }
        if let turnDone { onTurnPlayed?(turnDone.0, turnDone.1) }
        if let dropped { onDroppedUnprompted?(dropped) }
        if holdingNow != holdingReported {
            holdingReported = holdingNow
            onHoldChange?(holdingNow)
        }
        if playingNow != playingReported {
            playingReported = playingNow
            onPlayingChange?(playingNow)
        }
        if now - levelTick > 0.1 {
            levelTick = now
            onLevels?(lastMic, sqrt(outSum / Float(max(count, 1))))
        }
    }
}

/// Fixed-size PCM16 ring buffer (drops the oldest audio when full).
private struct Ring {
    private var buf: [Int16]
    private var r = 0, w = 0, n = 0
    init(capacity: Int) { buf = [Int16](repeating: 0, count: capacity) }
    var isEmpty: Bool { n == 0 }
    var count: Int { n }
    mutating func clear() { r = 0; w = 0; n = 0 }
    mutating func write(_ src: UnsafePointer<Int16>, _ count: Int) {
        for i in 0..<count {
            buf[w] = src[i]
            w = (w + 1) % buf.count
            if n == buf.count { r = (r + 1) % buf.count } else { n += 1 }
        }
    }
    mutating func read(into dst: UnsafeMutablePointer<Float>, _ count: Int) -> Int {
        let k = min(count, n)
        for i in 0..<k {
            dst[i] = Float(buf[r]) / 32_768
            r = (r + 1) % buf.count
        }
        n -= k
        return k
    }
}
