import AVFoundation
import os

/// 마이크 입력(24kHz PCM16 100ms 조각)과 번역 음성 재생을 한 엔진에서 처리한다.
/// - 말하기 버튼이 눌린 동안만 조각을 밖으로 내보낸다(그 외에는 직전 0.3초만 메모리에 유지 → 첫 음절 잘림 방지).
/// - 재생 중에는 아무것도 내보내지 않으므로 스피커 소리가 다시 인식되는 루프가 생기지 않는다.
/// - 음성은 파일로 저장하지 않는다.
final class AudioIO {
    static let sampleRate: Double = 24_000
    static let chunkBytes = 4_800 // 100ms (24k * 2바이트 * 0.1)
    private static let preRollBytes = 14_400 // 300ms

    var onMicChunk: ((Data) -> Void)?
    var onLevel: ((Float) -> Void)?
    /// 실제로 재생되고 있는 번역 음성의 음량(RMS). 오브 출력 반응에 쓴다.
    var onOutputLevel: ((Float) -> Void)?
    var onPlaybackDrained: (() -> Void)?
    var onRouteChange: ((String) -> Void)?
    var onInterruption: ((Bool) -> Void)?

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioIO.sampleRate, channels: 1, interleaved: false)!
    private let sendFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioIO.sampleRate, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var capturing = false
    private var preRoll = Data()
    private var accum = Data()
    private var scheduled = 0
    private var playbackGeneration = 0
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "interp", category: "audio")

    var isRunning: Bool { engine.isRunning }

    func start() throws {
        try configureSession()
        if engine.attachedNodes.contains(player) == false {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: playFormat)
            // 재생 노드 출력에 탭: 스피커로 나가는 실제 소리의 크기를 잰다.
            player.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
                guard let self, let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return }
                let n = Int(buffer.frameLength)
                var sum: Float = 0
                for i in 0..<n { sum += ch[0][i] * ch[0][i] }
                self.onOutputLevel?(self.isPlaying ? sqrt(sum / Float(n)) : 0)
            }
        }
        try installTapAndStart()
        observeSession()
        onRouteChange?(Self.routeName())
    }

    func stop() {
        endCapture()
        stopPlayback()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func configureSession() throws {
        let s = AVAudioSession.sharedInstance()
        // 스피커 기본 + 블루투스 고음질 출력(A2DP). 마이크는 아이폰 내장 마이크를 쓴다.
        try s.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try s.setPreferredSampleRate(48_000)
        try s.setPreferredIOBufferDuration(0.02)
        try s.setActive(true)
    }

    private func installTapAndStart() throws {
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioError.noInput }
        converter = AVAudioConverter(from: inFormat, to: sendFormat)
        input.installTap(onBus: 0, bufferSize: 2_048, format: inFormat) { [weak self] buffer, _ in
            self?.handleInput(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// 경로 변경(이어폰 연결 등)으로 엔진이 멈췄을 때 다시 켠다.
    func restart() {
        do {
            engine.stop()
            try installTapAndStart()
            log.info("audio engine restarted")
        } catch {
            log.error("restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 입력

    func beginCapture() {
        lock.lock()
        capturing = true
        accum = preRoll
        preRoll.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// 캡처를 멈추고 아직 100ms가 안 찬 나머지 조각을 돌려준다(호출한 쪽이 순서대로 보낸다).
    @discardableResult
    func endCapture() -> Data? {
        lock.lock()
        let wasCapturing = capturing
        capturing = false
        let rest = accum
        accum.removeAll(keepingCapacity: true)
        lock.unlock()
        return wasCapturing && !rest.isEmpty ? rest : nil
    }

    private func handleInput(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = sendFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: sendFormat, frameCapacity: capacity) else { return }
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
        let data = Data(bytes: ch[0], count: n * 2)

        var sum: Float = 0
        for i in 0..<n { let v = Float(ch[0][i]) / 32_768; sum += v * v }
        let rms = sqrt(sum / Float(n))

        var chunks: [Data] = []
        lock.lock()
        if capturing {
            accum.append(data)
            while accum.count >= Self.chunkBytes {
                chunks.append(accum.prefix(Self.chunkBytes))
                accum.removeFirst(Self.chunkBytes)
            }
        } else {
            preRoll.append(data)
            if preRoll.count > Self.preRollBytes { preRoll.removeFirst(preRoll.count - Self.preRollBytes) }
        }
        let isCapturing = capturing
        lock.unlock()

        for c in chunks { onMicChunk?(Data(c)) }
        if isCapturing { onLevel?(rms) }
    }

    // MARK: 재생

    func enqueue(pcm16 data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: playFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let dst = buf.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { dst[i] = Float(Int16(littleEndian: src[i])) / 32_768 }
        }
        if !engine.isRunning { restart() }
        lock.lock(); scheduled += 1; let gen = playbackGeneration; lock.unlock()
        player.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            guard gen == self.playbackGeneration else { self.lock.unlock(); return }
            self.scheduled -= 1
            let drained = self.scheduled == 0
            self.lock.unlock()
            if drained { DispatchQueue.main.async { self.onPlaybackDrained?() } }
        }
        if !player.isPlaying { player.play() }
    }

    var isPlaying: Bool {
        lock.lock(); defer { lock.unlock() }
        return scheduled > 0
    }

    func stopPlayback() {
        lock.lock(); playbackGeneration += 1; scheduled = 0; lock.unlock()
        player.stop()
    }

    // MARK: 세션 알림

    private func observeSession() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.onRouteChange?(Self.routeName())
        })
        observers.append(nc.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            self?.restart()
            self?.onRouteChange?(Self.routeName())
        })
        observers.append(nc.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began {
                self?.onInterruption?(true)
            } else {
                try? AVAudioSession.sharedInstance().setActive(true)
                self?.restart()
                self?.onInterruption?(false)
            }
        })
        observers.append(nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            try? self.configureSession()
            self.restart()
        })
    }

    static func routeName() -> String {
        guard let out = AVAudioSession.sharedInstance().currentRoute.outputs.first else { return "No output" }
        switch out.portType {
        case .builtInSpeaker: return "iPhone speaker"
        case .builtInReceiver: return "iPhone earpiece"
        case .headphones: return "Wired headphones"
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: return out.portName
        case .carAudio: return "Car audio"
        default: return out.portName
        }
    }

    enum AudioError: LocalizedError {
        case noInput
        var errorDescription: String? { "Couldn't find a microphone input" }
    }
}
