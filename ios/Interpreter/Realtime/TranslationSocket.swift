import Foundation
import os

/// gpt-realtime-translate 통역 세션 하나(= 발화 한 번).
/// 원문 음성을 흘려 보내는 동안 번역 음성·자막이 실시간으로 들어오고,
/// session.close 를 보내면 남은 번역을 마저 내보낸 뒤 session.closed 로 끝난다.
final class TranslationSocket: NSObject, URLSessionWebSocketDelegate {
    enum Event {
        case opened
        case inputText(String)
        case outputText(String)
        case audio(Data)
        case closed
        case failed(String)
    }

    let target: Lang
    let createdAt = Date()
    var onEvent: ((Event) -> Void)?
    /// Time spent fetching the short-lived key, set by the caller (ms).
    var ticketMs: Double = 0
    /// Source-language transcript model, enabled from the client with session.update (verified 2026-10-24).
    /// Hands-free mode uses it on one session to tell Korean from English. nil = no transcript.
    var transcribeModel: String?
    private var connectStartedAt: CFAbsoluteTime?
    private(set) var openedAt: CFAbsoluteTime?
    /// Connection preparation = key fetch + WebSocket open (ms). nil until open.
    var prepMs: Double? { openedAt.flatMap { o in connectStartedAt.map { ticketMs + (o - $0) * 1000 } } }

    private let ticket: SessionTicket
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private let sendQueue = DispatchQueue(label: "interp.ws.send")
    private var opened = false
    private var pending: [String] = []
    private var finished = false
    private let log = Logger(subsystem: "interp", category: "ws")

    init(target: Lang, ticket: SessionTicket) {
        self.target = target
        self.ticket = ticket
    }

    func connect() {
        guard let url = URL(string: ticket.url) else { emit(.failed("Invalid session URL")); return }
        var req = URLRequest(url: url)
        if ticket.mode == "direct" {
            req.setValue("Bearer \(ticket.token)", forHTTPHeaderField: "Authorization")
        }
        connectStartedAt = CFAbsoluteTimeGetCurrent()
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        urlSession = session
        let t = session.webSocketTask(with: req)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        receive()
    }

    /// 열린 지 오래된 대기 세션은 새로 받는다(임시 키 수명·유휴 끊김 대비).
    var isStale: Bool { finished || Date().timeIntervalSince(createdAt) > 240 }

    func appendAudio(_ pcm16: Data) {
        send(["type": "session.input_audio_buffer.append", "audio": pcm16.base64EncodedString()])
    }

    /// 말 끝: 남은 번역을 마저 받고 닫는다.
    func finish() {
        send(["type": "session.close"])
    }

    func cancel() {
        finished = true
        task?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()
    }

    // MARK: 내부

    private func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let text = String(data: data, encoding: .utf8) else { return }
        sendQueue.async { [weak self] in
            guard let self, !self.finished else { return }
            if self.opened {
                self.task?.send(.string(text)) { [weak self] err in
                    if let err { self?.log.error("send failed: \(err.localizedDescription, privacy: .public)") }
                }
            } else {
                self.pending.append(text)
            }
        }
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let s): self.handle(s)
                case .data(let d): if let s = String(data: d, encoding: .utf8) { self.handle(s) }
                @unknown default: break
                }
                if !self.finished { self.receive() }
            case .failure(let err):
                if !self.finished {
                    self.finished = true
                    self.emit(.failed(err.localizedDescription))
                }
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "session.output_audio.delta":
            if let b64 = obj["delta"] as? String, let pcm = Data(base64Encoded: b64) { emit(.audio(pcm)) }
        case "session.output_transcript.delta":
            if let d = obj["delta"] as? String { emit(.outputText(d)) }
        case "session.input_transcript.delta":
            if let d = obj["delta"] as? String { emit(.inputText(d)) }
        case "session.closed":
            finished = true
            emit(.closed)
            task?.cancel(with: .normalClosure, reason: nil)
        case "error":
            let msg = (obj["error"] as? [String: Any])?["message"] as? String ?? "Interpretation error"
            log.error("server error: \(msg, privacy: .public)")
            emit(.failed(msg))
        default:
            break
        }
    }

    private func emit(_ e: Event) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(e) }
    }

    // MARK: URLSessionWebSocketDelegate

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        openedAt = CFAbsoluteTimeGetCurrent()
        emit(.opened)
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.opened = true
            if self.ticket.mode == "direct" {
                // 임시 키에 이미 설정이 들어 있지만, 출력 언어를 한 번 더 명시한다.
                var audio: [String: Any] = ["output": ["language": self.target.rawValue]]
                if let model = self.transcribeModel { audio["input"] = ["transcription": ["model": model]] }
                let update: [String: Any] = ["type": "session.update", "session": ["audio": audio]]
                if let d = try? JSONSerialization.data(withJSONObject: update), let s = String(data: d, encoding: .utf8) {
                    self.task?.send(.string(s)) { _ in }
                }
            }
            for text in self.pending { self.task?.send(.string(text)) { _ in } }
            self.pending.removeAll()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        if !finished {
            finished = true
            let why = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Connection closed (\(closeCode.rawValue))"
            emit(.failed(why))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, !finished else { return }
        finished = true
        var msg = error.localizedDescription
        if let http = task.response as? HTTPURLResponse { msg = "Connection refused (HTTP \(http.statusCode))" }
        emit(.failed(msg))
    }
}
