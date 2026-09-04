import Foundation

// MARK: - 记忆管线（Codex 两阶段管线的 iOS 简化版）
//
// Phase 1（逐会话提取）：把 SessionLog 重放文本发给 LLM，产出 rollout_summary + 记忆条目。
//   照 Codex stage_one_system.md：no-op 门禁（没价值返回空）+ 脱敏 + 证据先行。
// Phase 2（全局整合）：Codex 用"整合 sub-agent + git diff"；iOS 简化为确定性代码
//   （21 天淘汰 + usage_count 排序 + 重写 MEMORY.md/memory_summary.md）——语义等价。
//
// 触发：App 启动 / 退后台（iOS 无并发竞争，单线程串跑即可）。

@MainActor
final class MemoryPipeline {
    static let shared = MemoryPipeline()

    private var running = false

    /// 已提取过的会话集合（防重复提取）
    private var extractedSessions: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mem.extracted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "mem.extracted") }
    }

    /// 有待提取会话时跑 Phase1+Phase2；无待提取时只跑轻量 Phase2（淘汰检查）
    func kick(force: Bool = false) async {
        guard !running else { return }
        running = true
        defer { running = false }

        let store = MemoryStore.shared
        let settings = SettingsStore.shared
        guard settings.hasKey else { return }   // 无真大脑不跑管线（假大脑会话不值得记）

        let done = extractedSessions
        let candidates = store.sessions.isEmpty ? [] : store.sessions.map { $0.id }
            .filter { !done.contains($0) }

        // 首条用户消息太短的会话不值得提取（打招呼/测试）
        var extractedAny = false
        for sid in candidates.prefix(5) {
            let events = SessionLog.replay(sessionID: sid)
            let userMsgs = events.filter { $0.type == SessionEvent.userMessage }
            guard let first = userMsgs.first?.data.text, first.count >= 6 else {
                var d = done; d.insert(sid); extractedSessions = d
                continue
            }
            if await phase1(sessionID: sid, events: events) {
                var d = done; d.insert(sid); extractedSessions = d
                extractedAny = true
            }
        }

        if extractedAny || force || !store.entries.isEmpty {
            store.consolidate()
        }
        NotificationCenter.default.post(name: Notification.Name("memory.changed"), object: nil)
    }

    // MARK: Phase 1 —— 单会话提取（Codex stage_one_system 语义）

    private func phase1(sessionID: String, events: [SessionEvent]) async -> Bool {
        // 重放文本（压缩：user/assistant 全文 + 工具命令行，上限 8K 字符）
        var lines: [String] = []
        for ev in events {
            switch ev.type {
            case SessionEvent.userMessage:
                if let t = ev.data.text { lines.append("用户: \(t)") }
            case SessionEvent.assistantMessage:
                if let t = ev.data.text, !t.isEmpty { lines.append("Agent: \(String(t.prefix(800)))") }
            case SessionEvent.toolCall:
                if let c = ev.data.command { lines.append("[工具] \(String(c.prefix(160)))") }
            default: break
            }
        }
        let transcript = lines.joined(separator: "\n").prefix(8_000)
        guard transcript.count > 10 else { return false }

        let prompt = """
        你是记忆提炼代理。把下面的会话记录提炼为可复用记忆。

        ## 规则（严格遵守）
        - 只提取对"未来类似任务"有用的信息：用户偏好与约束、项目的持久事实、踩过的坑与解法、验证过的流程。
        - 证据先行：不得编造。 secrets/token/密码 一律替换为 [REDACTED_SECRET]。
        - 不要复制大段工具输出，写紧凑结论。
        - No-op 门禁：如果这个会话没有值得沉淀的内容（寒暄、一次性查询、无新知识），返回空数组。
        - 每条记忆必须自包含（不依赖上下文也能懂），一条一个事实/偏好/教训。

        ## 输出格式（只输出 JSON，不要多余文字）
        {"rollout_summary":"本次会话一段话摘要（可空）","entries":["记忆条目1","记忆条目2"]}

        ## 会话记录
        \(transcript)
        """

        var text = ""
        do {
            let settings = SettingsStore.shared
            let stream = DeepSeekAdapter(settings: settings)
                .stream(messages: [.init(role: .user, content: prompt)], tools: [])
            for try await ev in stream {
                if case .textDelta(let d) = ev { text += d }
                if case .done(let t, _, _, _, _) = ev { if text.isEmpty { text = t } }
            }
        } catch {
            return false
        }

        // 解析 JSON（容错 markdown 代码围栏）
        var jsonText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if jsonText.hasPrefix("```") {
            jsonText = jsonText
                .replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let d = jsonText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return false }

        let summary = obj["rollout_summary"] as? String ?? ""
        let entries = (obj["entries"] as? [String]) ?? []
        MemoryStore.shared.insert(summary: summary, newEntries: entries, sourceSession: sessionID)
        return true
    }
}
