import Foundation

// MARK: - 项目 / 会话元数据（左栏导航数据源；日志文件为唯一事实来源）

struct SessionMeta: Identifiable, Equatable {
    let id: String
    var title: String
    var updatedAt: Date
    var projectID: String
}

struct Project: Identifiable, Equatable {
    let id: String
    var name: String
    var colorHex: UInt32
    var pinned: Bool
}

/// 会话存储：扫描 JSONL 文件列表 + 项目归属（M4 数据结构支持多项目，默认单工作区）
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [SessionMeta] = []
    @Published var projects: [Project] = [
        Project(id: "workspace", name: "工作区", colorHex: 0xD97706, pinned: false)
    ]

    private var titleCache: [String: String] = [:]   // sessionID → title（从 header 行读）

    /// 扫描全部会话（按更新时间倒序）
    func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: SessionLog.sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            sessions = []
            return
        }
        let metas: [SessionMeta] = files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = attrs?[.modificationDate] as? Date ?? .distantPast
            let title = titleOf(id: id, fallback: id)
            return SessionMeta(id: id, title: title, updatedAt: date, projectID: "workspace")
        }
        sessions = metas.sorted { $0.updatedAt > $1.updatedAt }
    }

    func titleOf(id: String) -> String {
        titleCache[id] ?? id
    }

    /// 从 JSONL 的 session header 行读标题（send 时记录在 header.text）
    func loadTitle(id: String) -> String {
        let events = SessionLog.replay(sessionID: id)
        for ev in events where ev.type == SessionEvent.sessionHeaderType {
            if let t = ev.data.text, !t.isEmpty { return t }
        }
        // 退化：第一条用户消息前 16 字
        for ev in events where ev.type == SessionEvent.userMessage {
            if let t = ev.data.text { return String(t.prefix(16)) }
        }
        return id
    }

    private func titleOf(id: String, fallback: String) -> String {
        let t = loadTitle(id: id)
        titleCache[id] = t
        return t
    }

    func deleteSession(id: String) {
        let url = SessionLog.sessionsDir.appendingPathComponent("\(id).jsonl")
        try? FileManager.default.removeItem(at: url)
        titleCache[id] = nil
        refresh()
    }
}
