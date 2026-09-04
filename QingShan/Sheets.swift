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

    var body: some View {
        SheetShell(title: "记忆", icon: "brain", onClose: onClose) {
            AnyView(
                SheetEmptyState(icon: "brain",
                                title: "暂无记忆条目",
                                detail: "记忆系统将在 M6 交付：Agent 会自动提炼重要事实，\n按主题组织、可查看可编辑，并支持淘汰。")
            )
        }
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
