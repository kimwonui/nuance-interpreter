import Foundation
import NaturalLanguage

/// Interpretation languages: the 13 output languages OpenAI documents for gpt-realtime-translate.
/// OpenAI publishes no language list for gpt-live-1; only Korean↔English has been tried, the rest are
/// experimental. The app shows only the languages the deployed server returns (GET /api/languages).
enum Lang: String, CaseIterable, Identifiable, Codable {
    case en, ko, ja, zh, es, fr, de, it, pt, ru, hi, id, vi

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }
    var name: String {
        switch self {
        case .en: return "English"
        case .ko: return "Korean"
        case .ja: return "Japanese"
        case .zh: return "Chinese"
        case .es: return "Spanish"
        case .fr: return "French"
        case .de: return "German"
        case .it: return "Italian"
        case .pt: return "Portuguese"
        case .ru: return "Russian"
        case .hi: return "Hindi"
        case .id: return "Indonesian"
        case .vi: return "Vietnamese"
        }
    }
    /// The language's own name (for search and display next to the English name).
    var nativeName: String {
        switch self {
        case .en: return "English"
        case .ko: return "한국어"
        case .ja: return "日本語"
        case .zh: return "中文"
        case .es: return "Español"
        case .fr: return "Français"
        case .de: return "Deutsch"
        case .it: return "Italiano"
        case .pt: return "Português"
        case .ru: return "Русский"
        case .hi: return "हिन्दी"
        case .id: return "Bahasa Indonesia"
        case .vi: return "Tiếng Việt"
        }
    }

    /// Search by English name, native name, or code (case- and accent-insensitive).
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return name.range(of: q, options: opts) != nil || nativeName.range(of: q, options: opts) != nil
            || rawValue.range(of: q, options: opts) != nil
    }

    var speakTitle: String { "Speak \(name)" }
    var speakHint: String { "Tap and speak" }
    var listeningTitle: String { "Listening… tap to end" }
    var cutInHint: String { "Tap to cut in" }
    var waitingHint: String { "Other side speaking" }
    /// Only these have been tried with GPT-Live.
    var tried: Bool { self == .ko || self == .en }

    var nlLanguage: NLLanguage {
        switch self {
        case .en: return .english
        case .ko: return .korean
        case .ja: return .japanese
        case .zh: return .simplifiedChinese
        case .es: return .spanish
        case .fr: return .french
        case .de: return .german
        case .it: return .italian
        case .pt: return .portuguese
        case .ru: return .russian
        case .hi: return .hindi
        case .id: return .indonesian
        case .vi: return .vietnamese
        }
    }

    /// Decorative flag style for the language (a visual cue, not a nationality). Languages spoken in many
    /// countries use one representative flag and are always shown together with the language name.
    var flag: FlagArt {
        switch self {
        case .en: return .usa
        case .ko: return .korea
        case .ja: return .stripes(vertical: false, bands: [(0xFFFFFF, 1)], emblem: .disc(0xBC002D, 0.3))
        case .zh: return .stripes(vertical: false, bands: [(0xDE2910, 1)], emblem: .star(0xFFDE00))
        case .vi: return .stripes(vertical: false, bands: [(0xDA251D, 1)], emblem: .star(0xFFFF00))
        case .es: return .stripes(vertical: false, bands: [(0xAA151B, 1), (0xF1BF00, 2), (0xAA151B, 1)], emblem: nil)
        case .fr: return .stripes(vertical: true, bands: [(0x002395, 1), (0xFFFFFF, 1), (0xED2939, 1)], emblem: nil)
        case .de: return .stripes(vertical: false, bands: [(0x000000, 1), (0xDD0000, 1), (0xFFCE00, 1)], emblem: nil)
        case .it: return .stripes(vertical: true, bands: [(0x009246, 1), (0xFFFFFF, 1), (0xCE2B37, 1)], emblem: nil)
        case .pt: return .stripes(vertical: true, bands: [(0x006600, 2), (0xFF0000, 3)], emblem: nil)
        case .ru: return .stripes(vertical: false, bands: [(0xFFFFFF, 1), (0x0039A6, 1), (0xD52B1E, 1)], emblem: nil)
        case .hi: return .stripes(vertical: false, bands: [(0xFF9933, 1), (0xFFFFFF, 1), (0x138808, 1)], emblem: .ring(0x000080, 0.16))
        case .id: return .stripes(vertical: false, bands: [(0xFF0000, 1), (0xFFFFFF, 1)], emblem: nil)
        }
    }

    /// Which of the two chosen languages a text is in (nil if too short or unclear).
    static func detect(_ text: String, among pair: (Lang, Lang)) -> Lang? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else { return nil }
        let r = NLLanguageRecognizer()
        r.languageConstraints = [pair.0.nlLanguage, pair.1.nlLanguage]
        r.processString(trimmed)
        let hyp = r.languageHypotheses(withMaximum: 2)
        let a = hyp[pair.0.nlLanguage] ?? 0, b = hyp[pair.1.nlLanguage] ?? 0
        guard max(a, b) >= 0.6 else { return nil }
        return a >= b ? pair.0 : pair.1
    }
}

/// Decorative flag drawings used by the orb and the split-screen backgrounds.
enum FlagArt {
    enum Emblem { case disc(UInt32, Double), star(UInt32), ring(UInt32, Double) }
    case usa
    case korea
    case stripes(vertical: Bool, bands: [(UInt32, Int)], emblem: Emblem?)
}

enum TurnStatus: Equatable {
    case connecting
    case listening
    case translating
    case playing
    case done
    case interrupted
    case empty      // 번역할 말이 없었음(같은 언어로 말했거나 무음)
    case failed(String)
}

/// 지연 측정용 시각(CFAbsoluteTime, 초). 숫자만 기록하고 내용은 기록하지 않는다.
struct TurnMetrics {
    var tTap: Double?
    var tStop: Double?
    var tFirstAudio: Double?       // 첫 번역 음성 조각 도착
    var tFirstVoiced: Double?      // first output chunk that actually contains speech (not padding silence)
    var tPlaybackStart: Double?    // 말 끝 이후 실제 재생 시작
    var tClosed: Double?
    var prepMs: Double?            // ticket fetch + WebSocket open, measured separately from speech latency
    var prewarmed = false          // session was already open before the speaker tapped
    var trimmedLeadBytes = 0       // leading output silence skipped
    var trimmedTailBytes = 0       // pause/trailing silence skipped

    /// 말 끝(끝 버튼 탭) → 첫 번역 소리 재생 시작
    var endToFirstSound: Double? {
        guard let s = tStop, let p = tPlaybackStart else { return nil }
        return max(0, p - s)
    }
    /// Done → first voiced output chunk arrived (negative = arrived while the speaker was still talking)
    var endToFirstVoicedArrival: Double? {
        guard let s = tStop, let v = tFirstVoiced else { return nil }
        return v - s
    }
    var endToClosed: Double? {
        guard let s = tStop, let c = tClosed else { return nil }
        return c - s
    }
}

/// 발화 한 번. 음성(원문·번역)은 메모리에만 있고 앱이 종료되면 사라진다.
struct Turn: Identifiable {
    let id = UUID()
    var source: Lang
    var target: Lang
    var sourceText = ""
    var targetText = ""
    var status: TurnStatus = .connecting
    var inputAudio = Data()   // 재시도용
    var outputAudio = Data()  // 다시 듣기용
    var playedBytes = 0       // 말하는 동안 보류했다가 재생한 위치
    var voicedStarted = false // output speech has begun (leading padding silence is skipped)
    var pendingSilence = Data() // silence after speech, played only if more speech follows
    var metrics = TurnMetrics()
    let createdAt = Date()

    var isLive: Bool {
        switch status {
        case .connecting, .listening, .translating, .playing: return true
        default: return false
        }
    }
}
