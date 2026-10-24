import Foundation

/// 우리 서버에서 통역 세션 입장 정보를 받는다.
/// OpenAI API 키는 앱에 없다. 서버가 몇 분짜리 임시 키(direct) 또는 중계 입장권(relay)을 내려준다.
struct SessionTicket: Decodable {
    let mode: String // "direct" | "relay"
    let url: String
    let token: String
    let expiresAt: Double?
}

enum TicketError: LocalizedError {
    case notConfigured
    case server(Int, String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "통역 서버 주소가 설정되지 않았어요"
        case .server(let code, let msg): return "통역 서버 오류(\(code)): \(msg)"
        case .network(let msg): return "통역 서버에 연결할 수 없어요 (\(msg))"
        }
    }
}

final class TokenClient {
    private let baseURL: URL?
    private let appKey: String?

    init(bundle: Bundle = .main) {
        let raw = (bundle.object(forInfoDictionaryKey: "InterpreterServerURL") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        baseURL = raw.isEmpty ? nil : URL(string: raw)
        let key = (bundle.object(forInfoDictionaryKey: "InterpreterAppKey") as? String) ?? ""
        appKey = key.isEmpty ? nil : key
    }

    var serverDescription: String { baseURL?.host ?? "미설정" }

    func ticket(target: Lang) async throws -> SessionTicket {
        guard let baseURL else { throw TicketError.notConfigured }
        var req = URLRequest(url: baseURL.appendingPathComponent("api/session"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let appKey { req.setValue(appKey, forHTTPHeaderField: "X-App-Key") }
        req.httpBody = try JSONSerialization.data(withJSONObject: ["target": target.rawValue])
        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw TicketError.network(error.localizedDescription)
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String ?? "알 수 없음"
            throw TicketError.server(code, msg)
        }
        return try JSONDecoder().decode(SessionTicket.self, from: data)
    }
}
