import Foundation

// MARK: - 会话事件（v2：dsh 对齐行格式）
//
// 行结构 = {seq, type, data}；首行 = {seq:0, type:"session", data:{version,id,createdAt}}。
// 事件名/语义照 dsh（packages/core/agent-loop + session-persistence-jsonl）：
//   turn/start · step/start · step/end · user/message · assistant/message ·
//   tool/call · tool/result · turn/end(带 reason)。
// 详细对照见仓库根「dsh语义对照笔记.md」。M2 首版旧格式（{ts,kind}）不再支持。

struct SessionEventData: Codable, Equatable {
    var turn: Int?
    var step: Int?
    var version: Int?
    var id: String?
    var createdAt: Double?
    var text: String?
    var command: String?
    var name: String?
    var exitCode: Int?
    var durationMs: Int?
    var output: String?
    var reason: String?
    var toolCallsJSON: String?
    var reasoning: String?

    init(turn: Int? = nil, step: Int? = nil, version: Int? = nil, id: String? = nil,
         createdAt: Double? = nil, text: String? = nil, command: String? = nil,
         name: String? = nil, exitCode: Int? = nil, durationMs: Int? = nil,
         output: String? = nil, reason: String? = nil, toolCallsJSON: String? = nil,
         reasoning: String? = nil) {
        self.turn = turn; self.step = step; self.version = version; self.id = id
        self.createdAt = createdAt; self.text = text; self.command = command; self.name = name
        self.exitCode = exitCode; self.durationMs = durationMs; self.output = output
        self.reason = reason; self.toolCallsJSON = toolCallsJSON; self.reasoning = reasoning
    }
}

struct SessionEvent: Codable, Equatable {
    var seq: Int
    var type: String
    var data: SessionEventData

    // dsh 风格事件名
    static let sessionHeaderType = "session"
    static let turnStart = "turn/start"
    static let stepStart = "step/start"
    static let stepEnd = "step/end"
    static let userMessage = "user/message"
    static let assistantMessage = "assistant/message"
    static let agentMessage = "agent/message"
    static let toolCall = "tool/call"
    static let toolResult = "tool/result"
    static let turnEnd = "turn/end"
    static let assistantChunk = "assistant/chunk"
    static let compact = "compact"

    static func sessionHeader(id: String, seq: Int) -> SessionEvent {
        .init(seq: seq, type: sessionHeaderType,
              data: .init(version: 0, id: id, createdAt: Date().timeIntervalSince1970))
    }
}

// MARK: - SessionLog：一行一事件 JSONL（append-only + 崩溃残行容错）

final class SessionLog {
    let sessionID: String
    let url: URL
    private let queue = DispatchQueue(label: "qingshan.sessionlog")
    private var nextSeq: Int = 0
    private var headerWritten = false

    static var sessionsDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init(sessionID: String) {
        self.sessionID = sessionID
        url = Self.sessionsDir.appendingPathComponent("\(sessionID).jsonl")
    }

    /// 追加事件（自动分配 seq；首事件自动写 session header 行）
    func append(_ type: String, _ data: SessionEventData) {
        queue.sync {
            if !headerWritten {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                writeLine(SessionEvent.sessionHeader(id: sessionID, seq: 0))
                nextSeq = 1
                headerWritten = true
            }
            writeLine(SessionEvent(seq: nextSeq, type: type, data: data))
            nextSeq += 1
        }
    }

    private func writeLine(_ event: SessionEvent) {
        guard var data = try? JSONEncoder().encode(event), var line = String(data: data, encoding: .utf8) else { return }
        line.append("\n")
        guard let lineData = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: lineData)
        }
    }

    // MARK: 静态查询/重放

    /// 最近修改的会话文件 ID（resume 用）
    static func latestSessionID() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else {
            return nil
        }
        let jsonls = files.filter { $0.pathExtension == "jsonl" }
        guard !jsonls.isEmpty else { return nil }
        let dated = jsonls.map { url -> (URL, Date) in
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let d = attrs?[.modificationDate] as? Date ?? .distantPast
            return (url, d)
        }
        guard let latest = dated.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return latest.deletingPathExtension().lastPathComponent
    }

    /// 全量重放：逐行解码；解析失败的行（crash 半行等）静默丢弃——即截断修复语义。
    /// 旧格式（M2 首版 {ts,kind}）解码失败同样被丢弃。
    static func replay(sessionID: String) -> [SessionEvent] {
        let url = sessionsDir.appendingPathComponent("\(sessionID).jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SessionEvent.self, from: data)
        }
    }
}
