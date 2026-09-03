import Foundation

// MARK: - 会话事件（SessionLog JSONL 的行格式）
//
// 语义照搬 Codex Rollout：append-only、不可变；resume 时反向重放还原状态。
// Swift 5.5+ 自动合成带关联值 enum 的 Codable。

struct SessionEvent: Codable {
    var ts: Double
    var kind: Kind

    enum Kind: Codable {
        case sessionStart(title: String)
        case userMessage(text: String)
        case agentMessage(text: String)
        case toolStart(command: String)
        case toolResult(command: String, exitCode: Int, durationMs: Int, output: String)
        case note(text: String)
    }

    static func now(_ kind: Kind) -> SessionEvent {
        SessionEvent(ts: Date().timeIntervalSince1970, kind: kind)
    }
}

// MARK: - SessionLog：一行一事件的 JSONL 读写

final class SessionLog {
    let sessionID: String
    let url: URL
    private let queue = DispatchQueue(label: "qingshan.sessionlog")

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

    /// 追加一个事件（原子行写入；失败静默——M2 记录失败不阻塞会话）
    func append(_ kind: SessionEvent.Kind) {
        let ev = SessionEvent.now(kind)
        queue.sync {
            guard var data = try? JSONEncoder().encode(ev) else { return }
            data.append(0x0A) // \n
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            if let fh = try? FileHandle(forWritingTo: url) {
                defer { try? fh.close() }
                _ = try? fh.seekToEnd()
                try? fh.write(contentsOf: data)
            }
        }
    }

    // MARK: 静态查询/重放

    /// 最近修改的会话文件 ID（resume 用）
    static func latestSessionID() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return nil
        }
        let fm = FileManager.default
        let jsonls = files.filter { $0.pathExtension == "jsonl" }
        guard !jsonls.isEmpty else { return nil }
        let dated = jsonls.map { url -> (URL, Date) in
            let d = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
            return (url, d)
        }
        guard let latest = dated.max(by: { $0.1 < $1.1 })?.0 else { return nil }
        return latest.deletingPathExtension().lastPathComponent
    }

    /// 全量重放：按顺序解码所有事件（append-only，顺序即时间线）
    static func replay(sessionID: String) -> [SessionEvent] {
        let url = sessionsDir.appendingPathComponent("\(sessionID).jsonl")
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(SessionEvent.self, from: data)
        }
    }
}
