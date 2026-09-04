import SwiftUI

// MARK: - 力度档位与模型（HTML EFFORTS/MODELS 对齐）

enum EffortTier: String, CaseIterable {
    case low, medium, high, xhigh, max

    var label: String {
        switch self {
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "极高"
        case .max: return "极限"
        }
    }
    var hint: String {
        switch self {
        case .low: return "最快速、最省 token"
        case .medium: return "默认档位"
        case .high: return "更充分的推理"
        case .xhigh: return "深度推理，耗时增加"
        case .max: return "不设限的推理深度"
        }
    }
    var color: Color {
        switch self {
        case .low: return Color(hex: 0x8A8894)
        case .medium: return Color(hex: 0x5B8DEF)
        case .high: return Color(hex: 0x5B8DEF)
        case .xhigh: return Color(hex: 0x7C3AED)
        case .max: return Color(hex: 0xA855C8)
        }
    }

    static var current: EffortTier {
        EffortTier(rawValue: UserDefaults.standard.string(forKey: "llm.effort") ?? "") ?? .medium
    }
    static func set(_ t: EffortTier) {
        UserDefaults.standard.set(t.rawValue, forKey: "llm.effort")
        NotificationCenter.default.post(name: Notification.Name("effort.changed"), object: nil)
    }
}

// MARK: - 上下文用量估算（真实：基于 llmHistory 字符量）

enum CtxUsage {
    static let windowTokens: Double = 8_000   // compact 阈值即窗口估算
    static func usedPercent(history: [LLMMessage]) -> Double {
        let chars = history.reduce(0) { $0 + ($1.content?.count ?? 0) + 8 }
        let tokens = Double(chars) / 2.0
        return min(100, tokens / windowTokens * 100)
    }
}

// MARK: - 统一浮层壳（HTML .pop 对齐：白卡+阴影+minWidth）

struct PopShell<Content: View>: View {
    var minWidth: CGFloat = 300
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .frame(minWidth: minWidth, alignment: .leading)
            .background(Color.white)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.16), radius: 18)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.06)))
    }
}

struct PopHeader: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
    }
}

struct PopOption: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var selected: Bool = false
    var trailing: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14))
                    .foregroundStyle(Color(hex: 0x6E6B64))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color(hex: 0x242420))
                    if let s = subtitle {
                        Text(s).font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                    }
                }
                Spacer()
                if let t = trailing {
                    Text(t).font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(hex: 0xA8A49C))
                }
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(hex: 0xE0833C))
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - chip（HTML .chip 对齐）

struct ChipView: View {
    let text: String
    var icon: String? = nil
    var iconColor: Color = Color(hex: 0x6E6B64)
    var trailingChevron: Bool = true

    var body: some View {
        HStack(spacing: 5) {
            if let ic = icon {
                Image(systemName: ic).font(.system(size: 11)).foregroundStyle(iconColor)
            }
            Text(text).font(.system(size: 12)).lineLimit(1)
            if trailingChevron {
                Image(systemName: "chevron.down").font(.system(size: 9))
                    .foregroundStyle(Color(hex: 0xA8A49C))
            }
        }
        .foregroundStyle(Color(hex: 0x4A4840))
        .padding(.vertical, 5).padding(.horizontal, 9)
        .background(Color.black.opacity(0.045))
        .cornerRadius(8)
    }
}

// MARK: - CtxRing（HTML 17x17 环形 SVG 对齐）

struct CtxRingView: View {
    let used: Double   // 0-100
    var body: some View {
        let col: Color = used >= 90 ? Color.red : used >= 70 ? Color(hex: 0xE6A23C) : Color(hex: 0x8A8894)
        ZStack {
            Circle().stroke(Color(hex: 0xE5E2DC), lineWidth: 2.6)
            Circle()
                .trim(from: 0, to: used / 100)
                .stroke(col, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - CtxPop（上下文用量弹层：百分比+分段条+压缩入口）

struct CtxPopView: View {
    let used: Double
    let onCompact: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("上下文用量").font(.system(size: 12.5, weight: .bold))
                Spacer()
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.1f%%", used))
                    .font(.system(size: 21, weight: .bold))
                Text(String(format: "已使用 %.1fK / %.1fK", used / 100 * CtxUsage.windowTokens / 1000, CtxUsage.windowTokens / 1000))
                    .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0xECEAE5))
                    Capsule().fill(used >= 90 ? Color.red : used >= 70 ? Color(hex: 0xE6A23C) : Color(hex: 0xE0833C))
                        .frame(width: g.size.width * used / 100)
                }
            }
            .frame(height: 6)
            if used >= 60 {
                Button(action: onCompact) {
                    HStack {
                        Image(systemName: "arrow.triangle.compress")
                        Text("立即压缩会话上下文")
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.vertical, 7).padding(.horizontal, 10)
                    .background(Color(hex: 0xFFFAF2))
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 300)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.16), radius: 18)
    }
}

// MARK: - 力度滑块（HTML EffortSlider 对齐：渐变填充+刻度+拖拽）

struct EffortSliderView: View {
    @Binding var tier: EffortTier
    @State private var dragW: CGFloat = 0

    private var idx: Int { EffortTier.allCases.firstIndex(of: tier) ?? 1 }
    private var pct: CGFloat { CGFloat(idx) / CGFloat(EffortTier.allCases.count - 1) }

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(hex: 0xE5E2DC)).frame(height: 6)
                Capsule().fill(tier.color).frame(width: max(10, pct * w), height: 6)
                ForEach(0..<EffortTier.allCases.count, id: \.self) { i in
                    Circle()
                        .fill(Color.white)
                        .frame(width: 3.5, height: 3.5)
                        .offset(x: w * CGFloat(i) / CGFloat(EffortTier.allCases.count - 1) - 2)
                }
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .shadow(color: .black.opacity(0.22), radius: 3)
                    .offset(x: pct * w - 7.5)
            }
            .frame(width: w)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let ratio = min(1, max(0, v.location.x / w))
                let i = Int(round(ratio * CGFloat(EffortTier.allCases.count - 1)))
                tier = EffortTier.allCases[i]
            })
        }
        .frame(height: 18)
    }
}

// MARK: - 模型+力度合并浮层（HTML ModelEffortPop 对齐：滑块态⇄列表态）

struct ModelEffortPopView: View {
    @Binding var tier: EffortTier
    @ObservedObject var settings: SettingsStore
    let onByok: () -> Void
    @State private var mode = "slider"

    var body: some View {
        if mode == "list" {
            PopShell(minWidth: 260) {
                PopHeader(text: "模型")
                PopOption(icon: "cpu", title: settings.model.isEmpty ? "未配置模型" : settings.model,
                          subtitle: "当前 BYOK 模型", selected: true) {
                    mode = "slider"
                }
                Divider().overlay(Color.black.opacity(0.06))
                PopOption(icon: "key", title: "BYOK 自定义模型",
                          subtitle: "在设置里配置 baseURL / API Key / 模型名") {
                    onByok()
                }
                .padding(.bottom, 6)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text(settings.model.isEmpty ? "未配置模型" : settings.model)
                        .font(.system(size: 12.5, weight: .bold))
                        .contentShape(Rectangle())
                        .onTapGesture { mode = "list" }
                    Text(tier.label).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(tier.color)
                    Image(systemName: "chevron.right").font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0xA8A49C))
                }
                EffortSliderView(tier: $tier)
                Text("\(tier.hint) · 拖动滑块即调档")
                    .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                if tier == .xhigh || tier == .max {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text("高档位显著增加 token 消耗与耗时。").font(.system(size: 11))
                    }
                    .foregroundStyle(Color(hex: 0xB57308))
                }
            }
            .padding(12)
            .frame(width: 250)
            .background(Color.white)
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.16), radius: 18)
        }
    }
}

// MARK: - 分支弹层（HTML BranchPop 对齐：搜索+列表+创建）

struct BranchPopView: View {
    let current: String
    let onPick: (String) -> Void
    @State private var q = ""
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xA8A49C))
                TextField("搜索分支", text: $q).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color(hex: 0xECEAE5))
            .cornerRadius(7)
            .padding(.horizontal, 8).padding(.top, 8)

            PopHeader(text: "分支")
            ForEach(MockData.branches.filter { $0.localizedCaseInsensitiveContains(q) }, id: \.self) { b in
                PopOption(icon: "arrow.triangle.branch", title: b, selected: b == current) {
                    onPick(b)
                }
            }
            Divider().overlay(Color.black.opacity(0.06))
            if creating {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0xA8A49C))
                    TextField("feature/新分支名", text: $name, onCommit: {
                        if !name.trimmingCharacters(in: .whitespaces).isEmpty {
                            onPick(name.trimmingCharacters(in: .whitespaces))
                        }
                    })
                    .textFieldStyle(.plain).font(.system(size: 12))
                }
                .padding(8)
            } else {
                PopOption(icon: "plus", title: "创建并检出新分支…") { creating = true }
            }
        }
        .padding(.bottom, 6)
        .frame(width: 280)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.16), radius: 18)
    }
}

// MARK: - 项目切换弹层（HTML composer 项目 chip 弹层对齐）

struct ProjectPopView: View {
    let activeProjectID: String?
    let onPick: (Project) -> Void
    let onNewProject: () -> Void
    let onDetach: () -> Void
    @State private var q = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0xA8A49C))
                TextField("搜索项目", text: $q).textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .background(Color(hex: 0xECEAE5))
            .cornerRadius(7)
            .padding(.horizontal, 8).padding(.top, 8)

            ForEach(ProjectStore.projects.filter { $0.name.localizedCaseInsensitiveContains(q) }) { p in
                PopOption(icon: "folder", title: p.name,
                          subtitle: p.git ? "已连接 Git 仓库" : "本地项目",
                          selected: p.id == activeProjectID) {
                    onPick(p)
                }
            }
            Divider().overlay(Color.black.opacity(0.06))
            PopOption(icon: "plus", title: "新建项目", subtitle: "选择一个文件夹作为项目源") { onNewProject() }
            PopOption(icon: "xmark.circle", title: "不在项目中工作", subtitle: "会话与项目解除关联") { onDetach() }
        }
        .padding(.bottom, 6)
        .frame(width: 320)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.16), radius: 18)
    }
}

// MARK: - 环境弹层（HTML EnvPop 对齐：本地/工作树/Web/云端）

struct EnvPopView: View {
    let current: String   // local | cloud
    let onPick: (String) -> Void

    var body: some View {
        PopShell(minWidth: 300) {
            PopHeader(text: "工作环境")
            PopOption(icon: "desktopcomputer", title: "本地",
                      subtitle: "在此设备沙箱中读写执行", selected: current != "cloud") { onPick("local") }
            PopOption(icon: "arrow.triangle.branch", title: "新建本地工作树",
                      subtitle: "基于当前分支创建独立工作目录") { onPick("worktree") }
            PopOption(icon: "safari", title: "关联 Agent Web",
                      subtitle: "在浏览器中继续这个会话") { onPick("web") }
            PopOption(icon: "cloud", title: "云端",
                      subtitle: "在云端沙箱中执行任务", selected: current == "cloud") { onPick("cloud") }
        }
        .padding(.bottom, 6)
    }
}

// MARK: - 策略弹层（HTML policy pop 对齐：三档联动完全访问）

struct PolicyPopView: View {
    @Binding var policy: ApprovalPolicy
    let onClose: () -> Void

    private func row(_ p: ApprovalPolicy, icon: String, title: String, sub: String) -> some View {
        PopOption(icon: icon, title: title, subtitle: sub, selected: policy == p) {
            policy = p
            onClose()
        }
    }

    var body: some View {
        PopShell(minWidth: 300) {
            PopHeader(text: "审批策略")
            row(.askAlways, icon: "hand.raised", title: "请求批准",
                sub: "所有工具操作都需要确认")
            row(.riskyOnly, icon: "exclamationmark.triangle", title: "危险才问",
                sub: "写操作等危险命令需要确认")
            row(.never, icon: "bolt", title: "完全访问权限",
                sub: "不再请求批准（谨慎使用）")
        }
        .padding(.bottom, 6)
    }
}

// MARK: - slash / @ 弹窗（composer 内联 mention-menu 对齐）

struct MentionItem: Identifiable {
    let id = UUID()
    let cmd: String
    let desc: String
    let action: () -> Void
}

struct MentionMenuView: View {
    let items: [MentionItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("无匹配")
                    .font(.system(size: 12)).foregroundStyle(Color(hex: 0xA8A49C))
                    .padding(.horizontal, 12).padding(.vertical, 10)
            } else {
                ForEach(items) { it in
                    Button(action: it.action) {
                        HStack(spacing: 8) {
                            Text(it.cmd).font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(Color(hex: 0x242420))
                            Text(it.desc).font(.system(size: 11.5))
                                .foregroundStyle(Color(hex: 0xA8A49C)).lineLimit(1)
                            Spacer()
                        }
                        .padding(.vertical, 7).padding(.horizontal, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: 380)
        .background(Color.white)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.18), radius: 16)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.06)))
    }
}

// MARK: - Composer 总成（HTML composer 对齐：胶囊行+输入+comp-bar）

struct ComposerBar: View {
    @Binding var input: String
    @Binding var policy: ApprovalPolicy
    @ObservedObject var settings: SettingsStore
    let ctxUsed: Double
    let activeProject: Project?
    let sessionMeta: [String: String]
    let onSend: () -> Void
    let onAssignProject: (Project?) -> Void
    let onNewProject: () -> Void
    let onSetEnv: (String) -> Void
    let onSetBranch: (String) -> Void
    let onOpenPanel: (String) -> Void
    let onSlashCommand: (String) -> Void

    @State private var pop: String? = nil   // proj|work|branch|addmenu|policy|ctxring|me
    @State private var tier: EffortTier = EffortTier.current

    private var envName: String { sessionMeta["loc"] == "cloud" ? "云端" : "本地" }
    private var branch: String { sessionMeta["branch"] ?? "main" }

    private var slashItems: [MentionItem] {
        [
            MentionItem(cmd: "/new", desc: "开始新对话") { onSlashCommand("/new") },
            MentionItem(cmd: "/compact", desc: "压缩会话上下文") { onSlashCommand("/compact") },
            MentionItem(cmd: "/model", desc: "选择模型与推理力度") { pop = "me" },
            MentionItem(cmd: "/memories", desc: "查看记忆") { onOpenPanel("memories") },
            MentionItem(cmd: "/tasks", desc: "查看任务队列") { onOpenPanel("tasks") },
            MentionItem(cmd: "/plugins", desc: "管理插件 MCP") { onOpenPanel("plugins") },
            MentionItem(cmd: "/permissions", desc: "审批策略") { pop = "policy" },
            MentionItem(cmd: "/review", desc: "打开审查面板") { onSlashCommand("/review") },
            MentionItem(cmd: "/terminal", desc: "打开终端面板") { onSlashCommand("/terminal") },
            MentionItem(cmd: "/files", desc: "打开文件面板") { onSlashCommand("/files") },
            MentionItem(cmd: "/settings", desc: "打开设置") { onOpenPanel("settings") },
            MentionItem(cmd: "/help", desc: "可用命令一览") { onSlashCommand("/help") },
        ]
    }

    private var atItems: [MentionItem] {
        MockData.workspaceFiles
            .filter { input.hasPrefix("@") && $0.lowercased().contains(String(input.dropFirst()).lowercased()) }
            .prefix(8)
            .map { f in MentionItem(cmd: "@\(f)", desc: "引用文件") {
                input = "@\(f) "
            } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // slash / @ 菜单（HTML mention-menu：显示在输入区顶部）
            if input.hasPrefix("/") {
                let q = String(input.dropFirst()).lowercased()
                MentionMenuView(items: slashItems.filter { q.isEmpty || $0.cmd.contains(q) })
                    .padding(.bottom, 8)
            } else if input.hasPrefix("@") {
                MentionMenuView(items: Array(atItems))
                    .padding(.bottom, 8)
            }

            // 胶囊行
            HStack(spacing: 6) {
                chipWithPop(kind: "proj") {
                    if let p = activeProject {
                        HStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3.5).fill(Color(hex: p.colorHex))
                                Text(String(p.name.prefix(1)))
                                    .font(.system(size: 8, weight: .bold)).foregroundStyle(Color.white)
                            }
                            .frame(width: 12, height: 12)
                            Text(p.name)
                        }
                    } else {
                        HStack(spacing: 5) {
                            Image(systemName: "xmark.circle").font(.system(size: 11))
                            Text("未分配项目")
                        }
                    }
                }
                if activeProject?.git == true {
                    chipWithPop(kind: "work") {
                        HStack(spacing: 5) {
                            Image(systemName: envName == "云端" ? "cloud" : "desktopcomputer").font(.system(size: 11))
                            Text(envName)
                        }
                    }
                    chipWithPop(kind: "branch") {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                            Text(branch)
                        }
                    }
                }
                Spacer()
            }
            .padding(.bottom, 6)

            // 输入框
            TextField("派活给 Agent —— Enter 发送；/ 命令，@ 引用文件", text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...6)
                .padding(.bottom, 6)
                .onSubmit { onSend() }

            // comp-bar
            HStack(spacing: 4) {
                chipWithPop(kind: "addmenu", chevron: false) {
                    Image(systemName: "plus").font(.system(size: 13))
                }
                chipWithPop(kind: "policy") {
                    HStack(spacing: 5) {
                        Image(systemName: policyIcon).font(.system(size: 12))
                        Text(policyLabel)
                    }
                }
                Spacer()
                chipWithPop(kind: "ctxring", chevron: false) {
                    CtxRingView(used: ctxUsed)
                }
                chipWithPop(kind: "me") {
                    HStack(spacing: 5) {
                        Image(systemName: "cpu").font(.system(size: 12))
                        Text(settings.model.isEmpty ? "选择模型" : settings.model)
                        Text(tier.label).font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tier.color)
                    }
                }
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 28, height: 28)
                        .background(input.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color(hex: 0xC9C6BE) : Color(hex: 0x242422))
                        .cornerRadius(9)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(10)
        .background(Color(hex: 0xF1EFEB))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(pop != nil ? Color(hex: 0xDDD9D2) : Color.clear)
        )
        // ---- 弹层 ----
        .overlay(alignment: .bottomLeading) {
            if pop == "proj" {
                ProjectPopView(activeProjectID: activeProject?.id,
                               onPick: { onAssignProject($0); pop = nil },
                               onNewProject: { onNewProject(); pop = nil },
                               onDetach: { onAssignProject(nil); pop = nil })
                    .offset(y: -8)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if pop == "work" {
                EnvPopView(current: envName == "云端" ? "cloud" : "local") { v in
                    onSetEnv(v)
                    pop = nil
                }
                .offset(y: -8)
                .zIndex(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if pop == "branch" {
                BranchPopView(current: branch) { b in
                    onSetBranch(b)
                    pop = nil
                }
                .offset(y: -8)
                .zIndex(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if pop == "policy" {
                PolicyPopView(policy: $policy) { pop = nil }
                    .offset(y: -8)
                    .zIndex(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if pop == "me" {
                ModelEffortPopView(tier: $tier, settings: settings, onByok: {
                    pop = nil
                    onOpenPanel("settings")
                })
                .offset(x: 4, y: -8)
                .zIndex(10)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if pop == "ctxring" {
                CtxPopView(used: ctxUsed) {
                    onSlashCommand("/compact")
                    pop = nil
                }
                .offset(x: 4, y: -8)
                .zIndex(10)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if pop == "addmenu" {
                PopShell(minWidth: 330) {
                    PopHeader(text: "添加")
                    PopOption(icon: "at", title: "文件和文件夹", subtitle: "引用工作区中的文件") {
                        input = "@"
                        pop = nil
                    }
                    PopOption(icon: "folder", title: "在项目中使用 Work", subtitle: "为新聊天选择项目") {
                        pop = "proj"
                    }
                    PopOption(icon: "rectangle.stack", title: "目标", subtitle: "设置要持续追求的目标") {
                        ToastCenter.shared.show("目标功能在 M7 交付", kind: .info)
                        pop = nil
                    }
                    PopOption(icon: "book", title: "计划模式", subtitle: "先规划，确认后再执行") {
                        ToastCenter.shared.show("计划模式在 M7 交付", kind: .info)
                        pop = nil
                    }
                }
                .padding(.bottom, 8)
                .offset(y: -8)
                .zIndex(10)
            }
        }
        .onChange(of: tier) { t in
            EffortTier.set(t)
        }
        .animation(.easeOut(duration: 0.12), value: pop)
    }

    private var policyLabel: String {
        switch policy {
        case .askAlways: return "请求批准"
        case .riskyOnly: return "危险才问"
        case .never: return "完全访问"
        }
    }
    private var policyIcon: String {
        switch policy {
        case .askAlways: return "hand.raised"
        case .riskyOnly: return "exclamationmark.triangle"
        case .never: return "bolt"
        }
    }

    @ViewBuilder
    private func chipWithPop<Content: View>(kind: String, chevron: Bool = true,
                                            @ViewBuilder content: () -> Content) -> some View {
        Button { pop = (pop == kind) ? nil : kind } label: {
            HStack(spacing: 5) {
                content()
                if chevron {
                    Image(systemName: "chevron.down").font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0xA8A49C))
                }
            }
            .foregroundStyle(Color(hex: 0x4A4840))
            .padding(.vertical, 5).padding(.horizontal, 9)
            .background(pop == kind ? Color.black.opacity(0.08) : Color.black.opacity(0.045))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}
