import Foundation

/// The interpretation model pads its output with silence (measured 2026-10-24: ~2 s before the
/// translation and ~7 s after, for a 2.5 s sentence). Playing that padding delays the first audible
/// word and keeps the orb "speaking" over nothing, so playback skips it:
/// - leading silence before the first voiced frame is dropped,
/// - pauses inside speech are kept up to 0.6 s (natural rhythm),
/// - silence after the last voiced frame is never played.
enum SilenceGate {
    static let threshold: Float = 0.008
    static let frameBytes = 480          // 10 ms of 24 kHz PCM16
    static let maxPauseBytes = 28_800    // 0.6 s

    static func rms(_ d: Data) -> Float {
        let n = d.count / 2
        guard n > 0 else { return 0 }
        var sum: Float = 0
        d.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<n { let v = Float(Int16(littleEndian: s[i])) / 32_768; sum += v * v }
        }
        return sqrt(sum / Float(n))
    }

    static func hasVoice(_ d: Data) -> Bool {
        var i = 0
        while i < d.count {
            let end = min(i + frameBytes, d.count)
            if rms(d.subdata(in: i..<end)) > threshold { return true }
            i = end
        }
        return false
    }

    /// Feeds newly arrived output audio for a turn and returns the part to play now.
    static func process(_ data: Data, turn: inout Turn) -> Data {
        var out = Data()
        var i = 0
        while i < data.count {
            let end = min(i + frameBytes, data.count)
            let frame = data.subdata(in: i..<end)
            let voiced = rms(frame) > threshold
            if !turn.voicedStarted {
                if voiced {
                    turn.voicedStarted = true
                    out.append(frame)
                } else {
                    turn.metrics.trimmedLeadBytes += frame.count
                }
            } else if voiced {
                let keep = turn.pendingSilence.suffix(maxPauseBytes)
                turn.metrics.trimmedTailBytes += turn.pendingSilence.count - keep.count
                out.append(keep)
                turn.pendingSilence.removeAll(keepingCapacity: true)
                out.append(frame)
            } else {
                turn.pendingSilence.append(frame)
            }
            i = end
        }
        return out
    }

    /// Leading/trailing silence removed, for Replay.
    static func trimmed(_ data: Data) -> Data {
        var t = Turn(source: .ko, target: .en)
        return process(data, turn: &t)
    }
}
