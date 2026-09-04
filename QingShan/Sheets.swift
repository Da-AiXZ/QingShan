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

struct MemoriesSheetData {
    static let quota = "1,240 / 4,000"
    static let items: [(String, Int, String, Int)] = [
        ("日志统一走 LoggerFacade 门面，禁止在业务代码直接调用 os.Logger", 8, "2 天前", 19),
        ("网络层错误统一映射为 ReaderError，UI 层不吞错、只展示", 5, "5 天前", 9),
        ("界面文案使用简体中文，Agent 术语保留英文原味", 3, "12 天前", 4),
        ("提交信息遵循 Conventional Commits，scope 用模块名", 1, "20 天前", 1),
    ]
    static let agentsMD = """
    # AGENTS.md — KimiReader
    - 架构：SwiftUI + TCA，模块化 SPM 包
    - 日志：一律使用 LoggerFacade（见 Docs/Logging.md）
    - 测试：改动 Core 模块必须跑 xcodebuild test
    - 禁止改动 Pods/ 与 DerivedData/
    """
}

struct MemoriesSheet: View {
    let onClose: () -> Void

    var body: some View {
        SheetShell(title: "记忆", icon: "brain", onClose: onClose) {
            AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        statCard("1,240 / 4,000", "摘要 token 配额", .primary)
                        statCard("12", "记忆条目", .primary)
                        statCard("5", "近期被引用", .primary)
                        statCard("2", "即将淘汰", Color(hex: 0xD97706))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Label("AGENTS.md · 项目指令（每次对话恒定注入）", systemImage: "book")
                            .font(.system(size: 12, weight: .semibold))
                        Text(MemoriesSheetData.agentsMD)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.secondary)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xF6F5F0))
                    .cornerRadius(10)

                    ForEach(Array(MemoriesSheetData.items.enumerated()), id: \.offset) { _, m in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(m.0).font(.system(size: 12.5))
                            HStack(spacing: 12) {
                                Text("被引用 \(m.1) 次").font(.caption2).foregroundStyle(Color.secondary)
                                Text("上次使用 \(m.2)").font(.caption2).foregroundStyle(Color.secondary)
                                Spacer()
                                Text("\(m.3) 天后淘汰")
                                    .font(.caption2)
                                    .foregroundStyle(m.3 <= 4 ? Color.red : m.3 <= 9 ? Color(hex: 0xD97706) : Color.green)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.black.opacity(0.06))
                                    Capsule().fill(Color(hex: m.3 <= 4 ? 0xB3403A : m.3 <= 9 ? 0xD97706 : 0x2F7D4F))
                                        .frame(width: geo.size.width * CGFloat(m.3) / 21.0)
                                }
                            }
                            .frame(height: 4)
                        }
                        .padding(10)
                        .background(Color(hex: 0xFBFaf7))
                        .cornerRadius(10)
                    }
                }
            )
        }
    }

    private func statCard(_ v: String, _ l: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.system(size: 13, weight: .semibold)).foregroundStyle(c)
            Text(l).font(.system(size: 10)).foregroundStyle(Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(hex: 0xF6F5F0))
        .cornerRadius(9)
    }
}

// MARK: - 任务队列弹层

struct TasksSheet: View {
    let onClose: () -> Void
    private let tasks: [(String, String, String)] = [
        ("每晚 02:00 跑全量单元测试", "cron · 0 2 * * *", "运行中"),
        ("每周一汇总依赖更新并开 PR", "cron · 0 9 * * 1", "运行中"),
        ("日志迁移剩余文件收尾", "一次性 · 今天 15:30", "排队"),
        ("清理 30 天前的构建产物", "cron · 0 4 * * 0", "已暂停"),
    ]

    var body: some View {
        SheetShell(title: "任务队列与定时任务", icon: "clock", onClose: onClose) {
            AnyView(
                VStack(spacing: 8) {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { _, t in
                        HStack(spacing: 10) {
                            Image(systemName: t.2 == "已暂停" ? "archivebox" : "clock")
                                .font(.system(size: 14)).foregroundStyle(Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.0).font(.system(size: 12.5, weight: .medium))
                                Text(t.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Text(t.2).font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(t.2 == "运行中" ? Color.green.opacity(0.15) : Color.black.opacity(0.06))
                                .foregroundStyle(t.2 == "运行中" ? Color.green : Color.secondary)
                                .cornerRadius(6)
                        }
                        .padding(10)
                        .background(Color(hex: 0xFBFaF7))
                        .cornerRadius(10)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "bolt").font(.system(size: 11))
                        Text("定时任务在设备接入电源且闲置时执行。").font(.caption2)
                    }
                    .foregroundStyle(Color.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            )
        }
    }
}

// MARK: - 插件弹层

struct PluginsSheet: View {
    let onClose: () -> Void
    @State private var plugins: [(String, String, Bool)] = [
        ("git-mcp", "仓库读写、历史与 blame 检索", true),
        ("xcodebuild-mcp", "构建、测试、签名与设备部署", true),
        ("web-fetch", "联网抓取文档与 release notes", true),
        ("fs-watcher", "监听工作区文件变更并增量索引", false),
        ("sqlite-mcp", "查询本地 CoreData 快照", false),
    ]

    var body: some View {
        SheetShell(title: "插件 · MCP", icon: "puzzlepiece.fill", onClose: onClose) {
            AnyView(
                VStack(spacing: 8) {
                    ForEach(Array(plugins.enumerated()), id: \.offset) { i, p in
                        HStack(spacing: 10) {
                            Image(systemName: "puzzlepiece.fill")
                                .font(.system(size: 14)).foregroundStyle(Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.0).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                Text(p.1).font(.system(size: 11)).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            ToggleSw(on: p.2) { plugins[i].2.toggle() }
                        }
                        .padding(10)
                        .background(Color(hex: 0xFBFaF7))
                        .cornerRadius(10)
                    }
                    Button {
                        ToastCenter.shared.show("添加 MCP 服务器在 M7 交付", kind: .info)
                    } label: {
                        Label("添加 MCP 服务器", systemImage: "plus")
                            .font(.footnote)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            )
        }
    }
}

// MARK: - 技能弹层

struct SkillsSheet: View {
    let onClose: () -> Void
    private let skills: [(String, String)] = [
        ("swift-refactor", "Swift 代码迁移与现代化改写"),
        ("xcode-build", "构建诊断与警告清理"),
        ("code-review", "逐行审查 diff 并给出风险意见"),
        ("doc-writer", "为模块补全文档与使用示例"),
    ]

    var body: some View {
        SheetShell(title: "技能", icon: "bolt.fill", onClose: onClose) {
            AnyView(
                VStack(spacing: 8) {
                    ForEach(skills, id: \.0) { s in
                        HStack(spacing: 10) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 13)).foregroundStyle(Color(hex: 0xD97706))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.0).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                Text(s.1).font(.system(size: 11)).foregroundStyle(Color.secondary)
                            }
                            Spacer()
                            Text("已安装").font(.caption2)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.green.opacity(0.14)).foregroundStyle(Color.green)
                                .cornerRadius(6)
                        }
                        .padding(10)
                        .background(Color(hex: 0xFBFaF7))
                        .cornerRadius(10)
                    }
                }
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
