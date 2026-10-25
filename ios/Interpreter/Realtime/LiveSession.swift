import AVFoundation
import Foundation
import WebRTC
import os

/// One GPT-Live interpreter session over WebRTC (hands-free mode).
/// Our server creates the session with the API key and fixed interpreter instructions, using the phone's
/// SDP offer; after that, audio flows directly between the phone and OpenAI. WebRTC handles echo
/// cancellation and playback; GPT-Live handles turn-taking and interruptions itself.
@MainActor
final class LiveSession: NSObject {
    enum Event {
        case started
        case inputText(String)
        case outputText(String)
        case closed(usageSeconds: Double?)
        case failed(String)
    }

    var onEvent: ((Event) -> Void)?
    /// Mic level and NUA's playback level (0…1, from WebRTC stats every 0.1 s).
    var onLevels: ((Float, Float) -> Void)?
    /// Hold-until-pause mode: seconds from the user's last speech to NUA's first released audio.
    var onRelease: ((Double, Bool) -> Void)?
    var onHoldChange: ((Bool) -> Void)?
    var onPlayingChange: ((Bool) -> Void)?
    var onCutIn: ((Float, Float) -> Void)?
    var onUserVoice: (() -> Void)?
    var onDroppedUnprompted: ((Double) -> Void)?
    var onSoftPause: (() -> Void)?
    var onTurnPlayed: ((Double, Double) -> Void)?

    /// Standard WebRTC audio (plays NUA as soon as it arrives).
    private static let standardFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    /// App-owned audio device that holds NUA's voice until the user has paused (see GatedAudioDevice).
    static let gatedDevice = GatedAudioDevice()
    /// The session that currently owns the shared device callbacks (a stopped session must not clear a new one's).
    private static var gatedOwner: ObjectIdentifier?
    private static let gatedFactory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory(), audioDevice: gatedDevice)
    }()

    let gated: Bool
    init(waitForPause: Bool) {
        gated = waitForPause
        super.init()
    }

    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var micTrack: RTCAudioTrack?
    private var statsTimer: Timer?
    private var closing = false
    private var routeObserver: NSObjectProtocol?
    private let log = Logger(subsystem: "interp", category: "live")

    /// `exchange` posts our SDP offer to the server and returns OpenAI's SDP answer.
    func start(exchange: @escaping (String) async throws -> String) {
        let factory = gated ? Self.gatedFactory : Self.standardFactory
        if gated {
            let device = Self.gatedDevice
            device.reset()
            Self.gatedOwner = ObjectIdentifier(self)
            device.onLevels = { [weak self] i, o in Task { @MainActor in self?.onLevels?(i, o) } }
            device.onRelease = { [weak self] dt, early in Task { @MainActor in self?.onRelease?(dt, early) } }
            device.onHoldChange = { [weak self] h in Task { @MainActor in self?.onHoldChange?(h) } }
            device.onPlayingChange = { [weak self] p in Task { @MainActor in self?.onPlayingChange?(p) } }
            device.onCutIn = { [weak self] m, o in Task { @MainActor in self?.onCutIn?(m, o) } }
            device.onUserVoice = { [weak self] in Task { @MainActor in self?.onUserVoice?() } }
            device.onDroppedUnprompted = { [weak self] sec in Task { @MainActor in self?.onDroppedUnprompted?(sec) } }
            device.onSoftPause = { [weak self] in Task { @MainActor in self?.onSoftPause?() } }
            device.onTurnPlayed = { [weak self] p, k in Task { @MainActor in self?.onTurnPlayed?(p, k) } }
        } else {
            configureAudioSession()
        }
        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            onEvent?(.failed("Couldn't create the audio connection")); return
        }
        self.pc = pc
        // In pause-gate mode Apple voice processing (same engine as playback, so its echo reference is exact)
        // does echo cancellation and noise suppression. Turn off WebRTC's own software processing here: its
        // echo reference would be the audio NUA pulled, not what actually played (held/dropped), and it could
        // suppress the user's voice as "echo", especially in noise.
        let audioConstraints = gated
            ? RTCMediaConstraints(mandatoryConstraints: ["googEchoCancellation": "false", "googNoiseSuppression": "false",
                                                         "googAutoGainControl": "false", "googHighpassFilter": "false"],
                                  optionalConstraints: nil)
            : constraints
        let source = factory.audioSource(with: audioConstraints)
        let track = factory.audioTrack(with: source, trackId: "nua-mic")
        pc.add(track, streamIds: ["nua"])
        micTrack = track
        let dcConfig = RTCDataChannelConfiguration()
        channel = pc.dataChannel(forLabel: "oai-events", configuration: dcConfig)
        channel?.delegate = self

        pc.offer(for: constraints) { [weak self] offer, error in
            Task { @MainActor in
                guard let self, let pc = self.pc else { return }
                guard let offer, error == nil else { self.fail(error?.localizedDescription ?? "Offer failed"); return }
                do {
                    try await pc.setLocalDescription(offer)
                    let answer = try await exchange(offer.sdp)
                    try await pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
                    if !self.gated { self.startStats() }
                    // WebRTC starts its audio unit after negotiation; re-check the route once it has.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.ensureSpeaker() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.ensureSpeaker() }
                } catch {
                    self.fail(error.localizedDescription)
                }
            }
        }
    }

    /// Diagnostics: the type name of each data-channel event we don't handle, once per session (no content).
    var onUnhandledEvent: ((String) -> Void)?
    private var seenTypes = Set<String>()
    private var nudgeCount = 0
    /// The speaker said they're done (orb tap) and no translation has started: ask the model, through the
    /// documented trusted-instruction event, to interpret now. Model behaviour — it may still wait or answer late.
    func nudgeInterpretNow() {
        nudgeCount += 1
        send(["type": "session.instructions.append", "event_id": "nua_finish_\(nudgeCount)", "delegation_id": NSNull(),
              "content": "The speaker has finished their turn. Translate their last utterance now, even if it is short or sounds unfinished. Speak only the translation of what they actually said."])
    }

    func setMuted(_ muted: Bool) {
        micTrack?.isEnabled = !muted
        send(["type": muted ? "session.input_audio.mute" : "session.input_audio.unmute"])
    }

    /// Ends billing: session.close, then the connection is torn down shortly after.
    func stop() {
        guard !closing else { return }
        closing = true
        micTrack?.isEnabled = false // stop sending the mic immediately
        if gated { Self.gatedDevice.reset() }
        send(["type": "session.close"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.teardown() }
    }

    private func teardown() {
        if let routeObserver { NotificationCenter.default.removeObserver(routeObserver) }
        routeObserver = nil
        statsTimer?.invalidate()
        statsTimer = nil
        channel?.close()
        pc?.close()
        pc = nil
        channel = nil
        micTrack = nil
        if gated {
            if Self.gatedOwner == ObjectIdentifier(self) {
                Self.gatedDevice.onLevels = nil
                Self.gatedDevice.onRelease = nil
                Self.gatedDevice.onHoldChange = nil
                Self.gatedDevice.onPlayingChange = nil
                Self.gatedDevice.onCutIn = nil
                Self.gatedDevice.onUserVoice = nil
                Self.gatedDevice.onDroppedUnprompted = nil
                Self.gatedDevice.onSoftPause = nil
                Self.gatedDevice.onTurnPlayed = nil
                Self.gatedOwner = nil
            }
            return
        }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        try? s.setActive(false)
        s.unlockForConfiguration()
    }

    private func fail(_ msg: String) {
        log.error("live failed: \(msg, privacy: .public)")
        onEvent?(.failed(msg))
        closing = true
        teardown()
    }

    private func configureAudioSession() {
        // WebRTC re-applies its own default configuration when its audio unit starts. That default has no
        // .defaultToSpeaker, so in voiceChat mode playback went to the earpiece (owner heard nothing,
        // 2026-10-24). Set WebRTC's default itself, then make sure the built-in speaker is used.
        let cfg = RTCAudioSessionConfiguration.webRTC()
        cfg.category = AVAudioSession.Category.playAndRecord.rawValue
        cfg.mode = AVAudioSession.Mode.voiceChat.rawValue
        cfg.categoryOptions = [.defaultToSpeaker, .allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(cfg)

        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        do {
            // voiceChat mode = Apple voice processing (echo cancellation); speaker by default, Bluetooth allowed.
            try s.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try s.setActive(true)
        } catch {
            log.error("audio session: \(error.localizedDescription, privacy: .public)")
        }
        s.unlockForConfiguration()
        ensureSpeaker()
        if routeObserver == nil {
            routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.ensureSpeaker() }
            }
        }
    }

    /// If playback is on the earpiece, switch to the built-in speaker (headphones/Bluetooth are left alone).
    func ensureSpeaker() {
        if gated { Self.gatedDevice.ensureSpeaker(); return }
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard outputs.contains(where: { $0.portType == .builtInReceiver }) else { return }
        let s = RTCAudioSession.sharedInstance()
        s.lockForConfiguration()
        do { try s.overrideOutputAudioPort(.speaker) } catch { log.error("speaker override: \(error.localizedDescription, privacy: .public)") }
        s.unlockForConfiguration()
    }

    private func send(_ obj: [String: Any]) {
        guard let channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func startStats() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStats() }
        }
    }

    private func pollStats() {
        pc?.statistics { [weak self] report in
            var input: Float = 0, output: Float = 0
            for stat in report.statistics.values {
                let kind = stat.values["kind"] as? String
                let level = (stat.values["audioLevel"] as? NSNumber)?.floatValue
                if stat.type == "media-source", kind == "audio", let level { input = level }
                if stat.type == "inbound-rtp", kind == "audio", let level { output = level }
            }
            Task { @MainActor in self?.onLevels?(input, output) }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "session.started":
            if gated { Self.gatedDevice.playChime(.start) } // "ready, listening"
            onEvent?(.started)
        case "session.input_transcript.delta":
            if let d = obj["delta"] as? String { onEvent?(.inputText(d)) }
        case "session.output_transcript.delta":
            if let d = obj["delta"] as? String { onEvent?(.outputText(d)) }
        case "session.closed":
            let usage = (obj["usage"] as? [String: Any])?["seconds"] as? NSNumber
            onEvent?(.closed(usageSeconds: usage?.doubleValue))
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Live session error"
            log.error("server error: \(msg, privacy: .public)")
            onEvent?(.failed(msg))
        default:
            if seenTypes.insert(type).inserted { onUnhandledEvent?(type) }
        }
    }
}

extension LiveSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed || newState == .disconnected {
            Task { @MainActor in if !self.closing { self.fail("Connection lost") } }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

extension LiveSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let text = String(data: buffer.data, encoding: .utf8) else { return }
        Task { @MainActor in self.handle(text) }
    }
}
