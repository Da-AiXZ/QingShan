import Foundation

// MARK: - 记忆条目（Codex stage-1 产出对齐：内容 + 引用计数 + 时间戳）

struct MemoryEntry: Identifiable, Codable {
    let id: String            // "m<timestamp>"（同时用作 MEMORY.md 引用锚点）
    var content: String       // 一条独立记忆（自包含、可执行）
    var usageCount: Int = 0   // 被引用次数（排序依据）
    var lastUsage: Date?      // 最近被引用时间（21 天淘汰依据）
    let generatedAt: Date     // 产出时间
    let sourceSession: String // 出处会话
}

// MARK: - 记忆文件存储（Codex memories root 的 iOS 文件版）
//
// 位置：沙箱 guest /memory = 宿主 Documents/root/data/memory
// （Agent 在 shell 里可 cat /memory/MEMORY.md，用户在 Files App 也可编辑——双通道）
//
// 文件：
//   memory/entries.json    结构化索引（Swift 管线用）
//   memory/MEMORY.md       人类可读目录（Codex 同名；模型检索入口）
//   memory/memory_summary.md 恒定注入的摘要（≤2500 token，Codex 同名）
//   memory/AGENTS.md       项目指令（用户手写，恒定注入）

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published var entries: [MemoryEntry] = []
    @Published var lastPhase1At: Date?
    @Published var lastPhase2At: Date?

    static var memoryDir: URL {
        FirstRun.rootURL.appendingPathComponent("data/memory", isDirectory: true)
    }

    private var entriesURL: URL { Self.memoryDir.appendingPathComponent("entries.json") }
    private var memoryMDURL: URL { Self.memoryDir.appendingPathComponent("MEMORY.md") }
    private var summaryURL: URL { Self.memoryDir.appendingPathComponent("memory_summary.md") }
    static var agentsMDURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AGENTS.md")
    }

    init() {
        load()
    }

    func load() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.memoryDir, withIntermediateDirectories: true)
        if let d = fm.contents(atPath: entriesURL.path),
           let es = try? JSONDecoder().decode([MemoryEntry].self, from: d) {
            entries = es
        }
        if let d = fm.contents(atPath: Self.memoryDir.appendingPathComponent(".pipeline_meta").path),
           let meta = try? JSONDecoder().decode([String: Date].self, from: d) {
            lastPhase1At = meta["phase1"]
            lastPhase2At = meta["phase2"]
        }
    }

    private func saveEntries() {
        let d = try? JSONEncoder().encode(entries)
        try? d?.write(to: entriesURL, options: .atomic)
    }

    private func saveMeta() {
        let meta: [String: Date] = ["phase1": lastPhase1At ?? .distantPast,
                                    "phase2": lastPhase2At ?? .distantPast]
        let d = try? JSONEncoder().encode(meta)
        try? d?.write(to: Self.memoryDir.appendingPathComponent(".pipeline_meta"), options: .atomic)
    }

    // MARK: Phase2 整合（确定性代码，替代 Codex 的整合 sub-agent）

    /// 返回被淘汰的条目数。规则照 Codex：21 天未用淘汰 + usage_count 优先排序 + top-N。
    @discardableResult
    func consolidate(maxUnusedDays: Int = 21, topN: Int = 200) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(maxUnusedDays) * 86_400)
        let before = entries.count
        entries = entries.filter { e in
            let anchor = e.lastUsage ?? e.generatedAt
            return anchor > cutoff
        }
        let pruned = before - entries.count

        entries.sort { ($0.usageCount, $1.lastUsage ?? $1.generatedAt) > ($1.usageCount, $0.lastUsage ?? $0.generatedAt) }
        if entries.count > topN { entries = Array(entries.prefix(topN)) }

        // memory_summary.md（恒定注入，≤2500 token ≈ 10K 字符截断）
        var sum = "# 记忆摘要\n\n以下是过往会话沉淀的记忆条目。相关时优先利用，不相关时忽略。\n\n"
        for e in entries {
            sum += "- \(e.content) [\(e.id)]\n"
        }
        if entries.isEmpty { sum += "（暂无记忆条目）\n" }
        try? sum.prefix(10_000).write(to: summaryURL, atomically: true, encoding: .utf8)

        // MEMORY.md（人类可读目录）
        var md = "# 记忆目录\n\n| ID | 内容 | 引用 | 最近使用 | 产出 |\n|---|---|---|---|---|\n"
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        for e in entries {
            let c = e.content.replacingOccurrences(of: "|", with: "\\|")
            md += "| \(e.id) | \(c) | \(e.usageCount) | \(e.lastUsage.map { df.string(from: $0) } ?? "—") | \(df.string(from: e.generatedAt)) |\n"
        }
        try? md.write(to: memoryMDURL, atomically: true, encoding: .utf8)

        saveEntries()
        lastPhase2At = Date()
        saveMeta()
        return pruned
    }

    // MARK: Phase1 产出入库

    func insert(summary: String, newEntries: [String], sourceSession: String) {
        lastPhase1At = Date()
        if !summary.isEmpty {
            let surl = Self.memoryDir.appendingPathComponent("rollout_\(sourceSession).md")
            try? summary.write(to: surl, atomically: true, encoding: .utf8)
        }
        let now = Date()
        for c in newEntries where !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries.append(MemoryEntry(id: "m\(Int(now.timeIntervalSince1970 * 1000))_\(entries.count)",
                                       content: c, generatedAt: now, sourceSession: sourceSession))
        }
        saveEntries()
        saveMeta()
    }

    // MARK: 引用闭环（Codex <oai-mem-citation> → usage_count/last_usage 回写）

    func markUsed(ids: [String]) {
        var changed = false
        for (i, e) in entries.enumerated() where ids.contains(e.id) {
            entries[i].usageCount += 1
            entries[i].lastUsage = Date()
            changed = true
        }
        if changed { saveEntries() }
    }

    /// 从 MEMORY.md/summary 提取的 id 模糊匹配（模型引用可能写简称）
    func resolveIDs(_ raw: [String]) -> [String] {
        raw.compactMap { raw in
            let k = raw.trimmingCharacters(in: .whitespaces)
            if entries.contains(where: { $0.id == k }) { return k }
            return entries.first { $0.id.hasPrefix(k) || k.contains($0.id) }?.id
        }
    }

    // MARK: 读路径 fragment（恒定注入；Codex read_path.md 中文适配）

    func summaryFragment() -> String {
        guard !entries.isEmpty else { return "" }
        var sum = try? String(contentsOf: summaryURL, encoding: .utf8)
        if sum == nil || sum!.isEmpty {
            sum = entries.prefix(30).map { "- \($0.content) [\($0.id)]" }.joined(separator: "\n")
        }
        return """

        ## 记忆

        你有既往会话沉淀的记忆（摘要如下）。决策规则：
        - 明显自包含的问题（问时间、简单改写、单行命令）——跳过记忆；
        - 涉及用户偏好、既往决定、重复任务、或与摘要相关的问题——默认利用记忆；
        - 利用某条记忆后，在回复最末尾输出引用块：<qs-mem-cite>记忆ID</qs-mem-cite>（一行，多个 ID 用空格分隔）。

        \(String(sum!.prefix(10_000)))
        """
    }

    /// AGENTS.md 项目指令（用户手写，恒定注入）
    func agentsFragment() -> String {
        guard let s = try? String(contentsOf: Self.agentsMDURL, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        return "\n## AGENTS.md（用户项目指令，必须遵守）\n\n" + String(s.prefix(16_000)) + "\n"
    }

    func deleteEntry(id: String) {
        entries.removeAll { $0.id == id }
        saveEntries()
    }
}
