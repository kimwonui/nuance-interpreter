import Foundation

/// 통역 언어. 엔진(gpt-realtime-translate)은 출력 13개 언어를 지원하므로 여기에 케이스만 늘리면 확장된다.
enum Lang: String, CaseIterable, Identifiable, Codable {
    case ko, en

    var id: String { rawValue }
    var code: String { rawValue.uppercased() }
    var name: String {
        switch self {
        case .ko: return "한국어"
        case .en: return "English"
        }
    }
    var speakTitle: String { self == .ko ? "한국어로 말하기" : "Speak English" }
    var speakHint: String { self == .ko ? "탭하고 말하세요" : "Tap and speak" }
    var listeningTitle: String { self == .ko ? "듣는 중… 끝나면 탭" : "Listening… tap to end" }
    var cutInHint: String { self == .ko ? "탭하면 끊고 말하기" : "Tap to cut in" }
    var waitingHint: String { self == .ko ? "상대가 말하는 중" : "Other side speaking" }
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
    var tPlaybackStart: Double?    // 말 끝 이후 실제 재생 시작
    var tClosed: Double?

    /// 말 끝(끝 버튼 탭) → 첫 번역 소리 재생 시작
    var endToFirstSound: Double? {
        guard let s = tStop, let p = tPlaybackStart else { return nil }
        return max(0, p - s)
    }
    var endToClosed: Double? {
        guard let s = tStop, let c = tClosed else { return nil }
        return c - s
    }
}

/// 발화 한 번. 음성(원문·번역)은 메모리에만 있고 앱이 종료되면 사라진다.
struct Turn: Identifiable {
    let id = UUID()
    let source: Lang
    let target: Lang
    var sourceText = ""
    var targetText = ""
    var status: TurnStatus = .connecting
    var inputAudio = Data()   // 재시도용
    var outputAudio = Data()  // 다시 듣기용
    var playedBytes = 0       // 말하는 동안 보류했다가 재생한 위치
    var metrics = TurnMetrics()
    let createdAt = Date()

    var isLive: Bool {
        switch status {
        case .connecting, .listening, .translating, .playing: return true
        default: return false
        }
    }
}
