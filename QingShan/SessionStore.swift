import Foundation

// MARK: - 会话元数据（左栏导航数据源；日志文件为唯一事实来源）
// Project 模型在 Sidebar.swift 中定义（带 git 字段）

struct SessionMeta: Identifiable, Equatable {
    let id: String
    var title: String
    var updatedAt: Date
}

/// 会话存储：扫描 JSONL 文件列表 + 标题缓存 + 重命名/删除
@MainActor
final class SessionStore: ObservableObject {
    @Published var sessions: [SessionMeta] = []

    private var titleCache: [String: String] = [:]   // sessionID → title（从 header 行读）

    /// 扫描全部会话（按更新时间倒序）
    func refresh() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: SessionLog.sessionsDir, includingPropertiesForKeys: nil) else {
            sessions = []
            return
        }
        let metas: [SessionMeta] = files.filter { $0.pathExtension == "jsonl" }.compactMap { url in
            let id = url.deletingPathExtension().lastPathComponent
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let date = attrs?[.modificationDate] as? Date ?? .distantPast
            let title = titleOf(id: id, fallback: id)
            return SessionMeta(id: id, title: title, updatedAt: date)
        }
        sessions = metas.sorted { $0.updatedAt > $1.updatedAt }
    }

    func titleOf(id: String) -> String {
        titleCache[id] ?? id
    }

    /// 从 JSONL 的 session header 行读标题（start(title:) 记录在 header.text）
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
        if let o = UserDefaults.standard.dictionary(forKey: "sess.title.override") as? [String: String],
           let t = o[id], !t.isEmpty { titleCache[id] = t; return t }
        if let t = titleCache[id] { return t }
        let t = loadTitle(id: id)
        titleCache[id] = t
        return t
    }

    /// 重命名：标题覆盖存 UserDefaults（不重写 append-only 日志，避免与 append 竞态）
    func rename(sessionID id: String, title: String) {
        titleCache[id] = title
        var o = UserDefaults.standard.dictionary(forKey: "sess.title.override") as? [String: String] ?? [:]
        o[id] = title
        UserDefaults.standard.set(o, forKey: "sess.title.override")
        refresh()
    }

    func deleteSession(id: String) {
        let url = SessionLog.sessionsDir.appendingPathComponent("\(id).jsonl")
        try? FileManager.default.removeItem(at: url)
        titleCache[id] = nil
        refresh()
    }
}
