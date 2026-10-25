import Foundation

/// Energy-based speech start/end detection on 100 ms mic chunks.
/// This only decides *when* someone is talking (to gate audio and find pauses). It does not identify
/// the language — that comes from the interpretation session's source transcript.
struct SpeechDetector {
    enum Event { case start, end }

    private(set) var speaking = false
    private(set) var noiseFloor: Float = 0.004
    private var above = 0
    private var below = 0

    /// Silence needed to call the end of an utterance. Short pauses inside a sentence stay below this.
    static let endChunks = 7 // 0.7 s

    mutating func reset() { speaking = false; above = 0; below = 0 }

    /// `bargeIn`: stricter start threshold while NUA is playing, so leftover echo doesn't count as speech.
    mutating func feed(_ rms: Float, bargeIn: Bool = false) -> Event? {
        let startThreshold = bargeIn ? max(0.06, noiseFloor * 6) : max(0.012, noiseFloor * 3)
        let endThreshold = max(0.008, noiseFloor * 2)
        if !speaking {
            if rms > startThreshold {
                above += 1
            } else {
                above = 0
                noiseFloor = min(0.03, noiseFloor * 0.95 + rms * 0.05)
            }
            if above >= (bargeIn ? 4 : 2) {
                speaking = true
                below = 0
                return .start
            }
        } else {
            below = rms < endThreshold ? below + 1 : 0
            if below >= Self.endChunks {
                speaking = false
                above = 0
                return .end
            }
        }
        return nil
    }
}
