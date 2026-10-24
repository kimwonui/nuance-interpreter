import AVFoundation

/// 서버 없이 오브·재생 경로를 확인하기 위한 "테스트 신호" 음성.
/// 기기 내장 음성 합성으로 문장을 만들어 24kHz PCM16 조각으로 돌려준다. 통역 결과가 아니다.
final class TestSignal {
    private let synth = AVSpeechSynthesizer()
    private var converter: AVAudioConverter?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: AudioIO.sampleRate, channels: 1, interleaved: true)!

    /// chunk 는 메인 스레드에서 차례로 불리고, 끝나면 nil 이 한 번 온다.
    func synthesize(_ text: String, language: String, chunk: @escaping (Data?) -> Void) {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: language)
        converter = nil
        var ended = false
        synth.write(u) { [weak self] buffer in
            guard let self, !ended else { return }
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                ended = true
                DispatchQueue.main.async { chunk(nil) }
                return
            }
            if let data = self.convert(pcm) { DispatchQueue.main.async { chunk(data) } }
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> Data? {
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outFormat)
        }
        guard let converter else { return nil }
        let cap = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / buffer.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: cap) else { return nil }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard err == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
        return Data(bytes: ch[0], count: Int(out.frameLength) * 2)
    }
}
