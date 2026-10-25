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
///   has been quiet for `holdSeconds` since the last speech. If the user resumes before that, it stays on
///   hold and the count restarts from the new last speech. Speaking clearly over NUA while it plays stops it
///   and clears the buffer (cut-in); the model itself also stops when interrupted.
/// This is a hold-until-pause gate, not a fixed delay: audio produced early waits for the pause.
final class GatedAudioDevice: NSObject, RTCAudioDevice {
    static let rate: Double = 48_000

    var holdSeconds: Double = 0.5
    /// Mic level and the level of audio actually played (called at ~10 Hz on audio threads).
    var onLevels: ((Float, Float) -> Void)?
    /// Seconds from the user's last speech to the first released NUA audio of a turn.
    var onRelease: ((Double) -> Void)?

    private weak var adm: RTCAudioDeviceDelegate?
    private let engine = AVAudioEngine()
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
    private var silentQueued = 0 // consecutive silent samples queued while holding

    // Render-thread scratch (preallocated).
    private var pull = [Int16](repeating: 0, count: 8_192)
    private var playTime: Double = 0
    private var recTime: Double = 0
    private var levelTick: Double = 0
    private var lastMic: Float = 0

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

    func startPlayout() -> Bool { isPlaying = startEngine(); return isPlaying }
    func startRecording() -> Bool { isRecording = startEngine(); return isRecording }

    func stopPlayout() -> Bool { isPlaying = false; stopEngineIfIdle(); return true }
    func stopRecording() -> Bool { isRecording = false; stopEngineIfIdle(); return true }

    // MARK: Engine

    private func setup() -> Bool {
        if source != nil { return true }
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

    private func stopEngineIfIdle() {
        guard !isPlaying, !isRecording, engine.isRunning else { return }
        engine.stop()
    }

    private func teardown() {
        engine.inputNode.removeTap(onBus: 0)
        if let source { engine.detach(source) }
        source = nil
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

        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = recTime
        ts.mFlags = .sampleTimeValid
        recTime += Double(n)
        var abl = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(n * 2), mData: UnsafeMutableRawPointer(ch[0])))
        _ = adm.deliverRecordedData(&flags, &ts, 1, UInt32(n), &abl, nil, nil)
    }

    private func detectSpeech(rms: Float, frames: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let playing = releasing
        // Stricter while NUA plays, so leftover echo is not taken for the user.
        let threshold = playing ? max(0.06, noiseFloor * 6) : max(0.015, noiseFloor * 3)
        let needed = Int(Self.rate * (playing ? 0.3 : 0.08))
        if rms > threshold {
            voiceRun += frames
            if voiceRun >= needed {
                lastVoice = now
                if playing {
                    // Cut-in: stop NUA and drop what was queued; the model also stops when interrupted.
                    ring.clear()
                    releasing = false
                }
            }
        } else {
            voiceRun = 0
            if !playing { noiseFloor = min(0.03, noiseFloor * 0.98 + rms * 0.02) }
        }
        os_unfair_lock_unlock(&lock)
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
        var outSum: Float = 0
        os_unfair_lock_lock(&lock)
        // Queue NUA's speech. While holding, pauses between its phrases are kept up to 0.6 s (natural rhythm);
        // while playing, silence is skipped so a backlog drains instead of becoming permanent lag.
        if pulledVoiced {
            pull.withUnsafeBufferPointer { ring.write($0.baseAddress!, count) }
            silentQueued = 0
        } else if !releasing, !ring.isEmpty, silentQueued < Int(Self.rate * 0.6) {
            pull.withUnsafeBufferPointer { ring.write($0.baseAddress!, count) }
            silentQueued += count
        }
        let quietFor = now - lastVoice
        if !releasing, !ring.isEmpty, quietFor >= holdSeconds {
            releasing = true
            released = quietFor
        }
        if releasing {
            let got = ring.read(into: dst, count)
            for i in 0..<got { outSum += dst[i] * dst[i] }
            if got < count { for i in got..<count { dst[i] = 0 } }
            if ring.isEmpty && !pulledVoiced { releasing = false }
        } else {
            for i in 0..<count { dst[i] = 0 }
        }
        os_unfair_lock_unlock(&lock)
        if count < n { for i in count..<n { dst[i] = 0 } }

        if let released { onRelease?(released) }
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
