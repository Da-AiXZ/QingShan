import SwiftUI

// MARK: - 统一弹层壳（遮罩 + 白卡 + 标题行）

struct SheetShell: View {
    let title: String
    let icon: String
    let onClose: () -> Void
    @ViewBuilder let content: () -> AnyView
    var width: CGFloat = 520

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.secondary)
                    Text(title).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button { onClose() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17)).foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        content()
                    }
                    .padding(16)
                }
            }
            .frame(width: width, height: 520)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.22), radius: 24)
        }
    }
}

// MARK: - 通用小部件

struct ToggleSw: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        ZStack {
            Capsule().fill(on ? Color.green : Color(hex: 0xD5D3C9)).frame(width: 38, height: 23)
            Circle().fill(Color.white).frame(width: 19, height: 19)
                .offset(x: on ? 8 : -8)
        }
        .onTapGesture { action() }
    }
}

struct SettingRow: View {
    let icon: String
    let title: String
    let detail: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Color.secondary)
            }
            Spacer()
            trailing
        }
        .padding(.vertical, 6)
    }
}

// MARK: - 记忆弹层


// MARK: - 诚实空态（功能未交付前不展示假数据）

struct SheetEmptyState: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 26))
                .foregroundStyle(Color(hex: 0xC9C6BE))
            Text(title).font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color(hex: 0x4A4840))
            Text(detail).font(.system(size: 11.5))
                .foregroundStyle(Color(hex: 0xA8A49C))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
    }
}

struct MemoriesSheet: View {
    let onClose: () -> Void
    @ObservedObject private var mem = MemoryStore.shared
    @State private var agentsDraft = ""
    @State private var editingAgents = false
    @State private var pipelineRunning = false
    @State private var tick = 0

    var body: some View {
        SheetShell(title: "记忆", icon: "brain", onClose: onClose) {
            AnyView(content)
        }
        .onAppear { agentsDraft = (try? String(contentsOf: MemoryStore.agentsMDURL, encoding: .utf8)) ?? "" }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                // 统计卡
                HStack(spacing: 8) {
                    statCard("\(mem.entries.count)", "记忆条目")
                    statCard("\(mem.entries.filter { ($0.usageCount) > 0 }.count)", "被引用过")
                    statCard(pipelineRunning ? "…" : (mem.lastPhase1At == nil ? "—" : "✓"), "提取管线")
                }
                .frame(maxWidth: .infinity)

                // AGENTS.md
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("AGENTS.md · 项目指令（每次会话恒定注入）", systemImage: "book")
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Button(editingAgents ? "完成" : "编辑") {
                            if editingAgents {
                                try? agentsDraft.write(to: MemoryStore.agentsMDURL, atomically: true, encoding: .utf8)
                                ToastCenter.shared.show("AGENTS.md 已保存，新会话生效", kind: .success)
                            }
                            editingAgents.toggle()
                        }
                        .font(.system(size: 12)).buttonStyle(.plain)
                        .foregroundStyle(Color(hex: 0xE0833C))
                    }
                    if editingAgents {
                        TextEditor(text: $agentsDraft)
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(height: 140)
                            .padding(6)
                            .background(Color.black.opacity(0.04))
                            .cornerRadius(8)
                    } else if agentsDraft.isEmpty {
                        Text("（未设置。写在这里的指令会注入每次会话，例如「回复保持简短」「我是 iOS 开发者」）")
                            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                    } else {
                        Text(agentsDraft)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                    }
                }
                .padding(12)
                .background(Color(hex: 0xFBFaF7))
                .cornerRadius(10)

                // 条目列表
                HStack {
                    Text("记忆条目（21 天未引用自动淘汰）")
                        .font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button {
                        pipelineRunning = true
                        Task {
                            await MemoryPipeline.shared.kick(force: true)
                            pipelineRunning = false
                            tick += 1
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if pipelineRunning { ProgressView().controlSize(.mini) }
                            Text("立即整理").font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color(hex: 0xE0833C))
                    .disabled(pipelineRunning)
                }
                if mem.entries.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "brain").font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0xC9C6BE))
                        Text("暂无记忆条目")
                            .font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Color(hex: 0x4A4840))
                        Text("和 Agent 聊几轮有内容的天，退到后台时它会自动提炼可复用的记忆。")
                            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 26)
                } else {
                    ForEach(mem.entries) { e in
                        HStack(alignment: .top, spacing: 8) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(e.content).font(.system(size: 12))
                                HStack(spacing: 10) {
                                    Text(e.id).font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Color(hex: 0xA8A49C))
                                    Text("引用 \(e.usageCount)")
                                        .font(.system(size: 10)).foregroundStyle(Color(hex: 0x8A8894))
                                    if let lu = e.lastUsage {
                                        Text("最近 \(lu.formatted(.relative(presentation: .named))))")
                                            .font(.system(size: 10)).foregroundStyle(Color(hex: 0xA8A49C))
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                mem.deleteEntry(id: e.id)
                                tick += 1
                            } label: {
                                Image(systemName: "trash").font(.system(size: 10))
                                    .foregroundStyle(Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color(hex: 0xFBFaF7))
                        .cornerRadius(10)
                    }
                }
            }
            .padding(14)
            .id(tick)
        }
    }

    private func statCard(_ v: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(v).font(.system(size: 17, weight: .bold))
            Text(label).font(.system(size: 10.5)).foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(hex: 0xF1EFEB))
        .cornerRadius(10)
    }
}

// MARK: - 任务队列弹层

struct TasksSheet: View {
    let onClose: () -> Void

    var body: some View {
        SheetShell(title: "任务队列与定时任务", icon: "clock", onClose: onClose) {
            AnyView(
                SheetEmptyState(icon: "clock",
                                title: "暂无任务",
                                detail: "任务队列与定时任务将在 M7 交付：\n可安排 cron 定时任务与一次性任务。")
            )
        }
    }
}

// MARK: - 插件弹层

struct PluginsSheet: View {
    let onClose: () -> Void

    var body: some View {
        SheetShell(title: "插件 · MCP", icon: "puzzlepiece.fill", onClose: onClose) {
            AnyView(
                SheetEmptyState(icon: "puzzlepiece",
                                title: "暂无插件",
                                detail: "MCP 插件将在 M7 交付（架构已预留模块接口）：\n届时可添加 MCP 服务器扩展 Agent 能力。")
            )
        }
    }
}

// MARK: - 技能弹层

struct SkillsSheet: View {
    let onClose: () -> Void

    var body: some View {
        SheetShell(title: "技能", icon: "bolt.fill", onClose: onClose) {
            AnyView(
                SheetEmptyState(icon: "bolt",
                                title: "暂无技能",
                                detail: "技能系统将在 M7 交付：\n可安装领域技能包增强 Agent 的专业能力。")
            )
        }
    }
}

// MARK: - 新建项目弹层

struct CreateProjectSheet: View {
    let onClose: () -> Void
    let onCreate: (String) -> Void
    @State private var name = ""
    @State private var src: String?
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
                .onTapGesture { onClose() }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.gearshape")
                        .foregroundStyle(Color.secondary)
                    Text("创建项目").font(.system(size: 15, weight: .semibold))
                }
                TextField("项目名称", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .padding(10)
                    .background(Color(hex: 0xF4F3EE))
                    .cornerRadius(9)
                    .focused($focused)
                Text("源文件夹").font(.system(size: 11.5)).foregroundStyle(Color.secondary)
                if let src {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                        Text(src).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                        Button { self.src = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(Color(hex: 0xF4F3EE))
                    .cornerRadius(9)
                } else {
                    Button {
                        src = "/Users/demo/Projects/\(name.isEmpty ? "NewProject" : name)"
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 18)).foregroundStyle(Color(hex: 0xC9C6BE))
                            Text("添加 Agent 可读取和编辑的文件夹")
                                .font(.footnote).foregroundStyle(Color.secondary)
                            Spacer()
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity)
                        .background(Color(hex: 0xF4F3EE))
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                }
                HStack {
                    Spacer()
                    Button("取消") { onClose() }
                    Button {
                        onCreate(name.trimmingCharacters(in: .whitespaces))
                    } label: {
                        Label("创建项目", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xD97706))
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 6)
            }
            .padding(18)
            .frame(width: 480)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.22), radius: 24)
        }
        .onAppear { focused = true }
    }
}
