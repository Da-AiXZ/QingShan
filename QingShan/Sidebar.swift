import SwiftUI

// MARK: - 项目模型（HTML PROJECTS 对齐）

struct Project: Identifiable, Equatable, Codable {
    let id: String
    var name: String
    var colorHex: UInt32
    var pinned: Bool
    var git: Bool
}

// MARK: - 项目/会话归属 持久化存储

enum ProjectStore {
    static let KEY = "sess.project.map"
    static let PKEY = "projects.v1"

    static var projects: [Project] {
        get {
            guard let d = UserDefaults.standard.data(forKey: PKEY),
                  let ps = try? JSONDecoder().decode([Project].self, from: d) else { return [] }
            return ps
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: PKEY) }
    }

    static func project(of sessionID: String) -> Project? {
        let map = UserDefaults.standard.dictionary(forKey: KEY) as? [String: String] ?? [:]
        guard let pid = map[sessionID] else { return nil }
        return projects.first { $0.id == pid }
    }

    static func assign(sessionID: String, projectID: String?) {
        var map = UserDefaults.standard.dictionary(forKey: KEY) as? [String: String] ?? [:]
        if let pid = projectID { map[sessionID] = pid } else { map.removeValue(forKey: sessionID) }
        UserDefaults.standard.set(map, forKey: KEY)
    }

    /// 会话级 mock 元数据（环境/分支）
    static func sessionMeta(_ sessionID: String) -> [String: String] {
        UserDefaults.standard.dictionary(forKey: "sess.meta.\(sessionID)") as? [String: String] ?? [:]
    }
    static func setSessionMeta(_ sessionID: String, _ meta: [String: String]) {
        UserDefaults.standard.set(meta, forKey: "sess.meta.\(sessionID)")
    }

    @discardableResult
    static func togglePin(_ pid: String) -> Bool {
        var ps = projects
        guard let i = ps.firstIndex(where: { $0.id == pid }) else { return false }
        ps[i].pinned.toggle()
        projects = ps
        return ps[i].pinned
    }

    @discardableResult
    static func addProject(name: String) -> Project {
        let palette: [UInt32] = [0xE0833C, 0x5B8DEF, 0x2F9E6E, 0x8E5BD9, 0xD95B8D]
        let p = Project(id: "p\(Int(Date().timeIntervalSince1970))", name: name,
                        colorHex: palette[abs(name.hashValue) % palette.count], pinned: false, git: false)
        var ps = projects
        ps.append(p)
        projects = ps
        return p
    }
}

// MARK: - 会话行模型（左栏用）

struct SessRowItem: Identifiable {
    let id: String
    let title: String
    var running: Bool = false
}

// MARK: - 建议卡文案（hero 功能数据，非假状态）

enum MockData {
    static let suggestions: [(icon: String, b: String, s: String, fill: String)] = [
        ("magnifyingglass", "探索并理解代码", "梳理模块结构与关键调用链", "帮我梳理项目的模块结构和关键调用链"),
        ("bolt", "构建新功能", "从需求到可运行代码", "给项目加一个实用的新功能"),
        ("wrench", "重构代码", "迁移到更现代的方案", "把项目里的旧式日志迁移到统一日志系统"),
        ("exclamationmark.triangle", "修复问题", "定位并修掉 bug", "帮我定位并修复一个偶发问题"),
    ]

    /// 分支列表：main（真实默认）+ 用户创建（持久化）。无 git 仓库前只有 main。
    static var branches: [String] {
        var b = UserDefaults.standard.stringArray(forKey: "branches.user") ?? []
        b.insert("main", at: 0)
        return b
    }
    static func addBranch(_ name: String) {
        var b = UserDefaults.standard.stringArray(forKey: "branches.user") ?? []
        if !b.contains(name) { b.append(name) }
        UserDefaults.standard.set(b, forKey: "branches.user")
    }

    /// 沙箱真实文件列表（RootView ready 后 ls 一次缓存）
    static var sandboxFiles: [String] = []
}

// MARK: - 完整左栏（HTML Sidebar 对齐：搜索/项目分组/pin/重命名/展开/badge）

struct SidebarView: View {
    let activeID: String
    let onSelect: (String) -> Void
    let onNewChat: () -> Void
    let onNewChatIn: (String) -> Void
    let onOpenPanel: (String) -> Void
    var onCollapse: (() -> Void)? = nil

    @State private var query = ""
    @State private var openProjs: [String: Bool] = [:]
    @State private var showAll: [String: Bool] = [:]
    @State private var renamingID: String?
    @State private var renameVal = ""
    @State private var tick = 0
    @ObservedObject var store: SessionStore

    var body: some View {
        VStack(spacing: 0) {
            // side-hd
            HStack(spacing: 8) {
                if let onCollapse {
                    Button(action: onCollapse) {
                        Image(systemName: "sidebar.leading").font(.system(size: 14))
                            .foregroundStyle(Color(hex: 0x6E6B64))
                    }
                    .buttonStyle(.plain)
                }
                Text("Agent")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(hex: 0x242420))
                Spacer()
                Button(action: onNewChat) {
                    Image(systemName: "square.and.pencil").font(.system(size: 14))
                        .foregroundStyle(Color(hex: 0x6E6B64))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 6)

            // searchbox
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12))
                    .foregroundStyle(Color(hex: 0xA8A49C))
                TextField("搜索会话", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                if !query.isEmpty {
                    Button(action: { query = "" }) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                            .foregroundStyle(Color(hex: 0xA8A49C))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6).padding(.horizontal, 9)
            .background(Color(hex: 0xECEAE5))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            // side-scroll
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    let projects = ProjectStore.projects
                    let pinned = projects.filter { $0.pinned }
                    let rest = projects.filter { !$0.pinned }

                    if !pinned.isEmpty {
                        grpLabel("置顶")
                        ForEach(pinned) { p in
                            projectSection(p)
                        }
                    }
                    grpLabelWithAdd("项目") { onOpenPanel("newproject") }
                    if rest.isEmpty && pinned.isEmpty {
                        Text("暂无项目，点右上 + 新建")
                            .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49C))
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    ForEach(rest) { p in
                        projectSection(p)
                    }
                }
                .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)

            // side-ft
            VStack(spacing: 1) {
                ftItem("clock", "任务队列", nil, "tasks")
                ftItem("puzzlepiece", "插件 MCP", nil, "plugins")
                ftItem("brain", "记忆", nil, "memories")
                ftItem("slider.horizontal.3", "设置", nil, "settings")
            }
            .padding(.vertical, 6)
            .background(Color(hex: 0xEFEEE9))
        }
        .background(Color(hex: 0xEFEEE9))
    }

    private func grpLabel(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    private func grpLabelWithAdd(_ t: String, add: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            Text(t).font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
            Spacer()
            Button(action: add) {
                Image(systemName: "plus").font(.system(size: 10)).foregroundStyle(Color(hex: 0x8A8894))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 4)
    }

    @ViewBuilder
    private func projectSection(_ p: Project) -> some View {
        let _ = tick
        let allSess = store.sessions.filter { ProjectStore.project(of: $0.id)?.id == p.id }
        let list: [SessRowItem] = {
            let base = allSess.map { SessRowItem(id: $0.id, title: $0.title) }
            return query.isEmpty ? base : base.filter { $0.title.lowercased().contains(query.lowercased()) }
        }()
        let open = query.isEmpty ? (openProjs[p.id] ?? true) : !list.isEmpty
        let expanded = showAll[p.id] ?? false
        let shown = expanded ? list : Array(list.prefix(4))

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: open ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(Color(hex: 0xB9B5AD))
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: p.colorHex))
                    Text(String(p.name.prefix(1)))
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(Color.white)
                }
                .frame(width: 15, height: 15)
                Text(p.name).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color(hex: 0x3A3833))
                Text("\(allSess.count)")
                    .font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xA8A49C))
                Spacer()
                Button {
                    _ = ProjectStore.togglePin(p.id)
                    tick += 1
                } label: {
                    Image(systemName: p.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(p.pinned ? Color(hex: 0xE0833C) : Color(hex: 0xA8A49C))
                }
                .buttonStyle(.plain)
                Button { onNewChatIn(p.id) } label: {
                    Image(systemName: "plus").font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                }
                .buttonStyle(.plain)
            }
            .padding(.vertical, 5).padding(.horizontal, 8)
            .contentShape(Rectangle())
            .onTapGesture { openProjs[p.id] = !open }

            if open {
                ForEach(shown) { s in
                    sessRow(s)
                }
                if !expanded && list.count > 4 {
                    Text("展开显示（还有 \(list.count - 4) 个）")
                        .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0x8A8894))
                        .padding(.vertical, 5).padding(.leading, 25)
                        .contentShape(Rectangle())
                        .onTapGesture { showAll[p.id] = true }
                }
                if !query.isEmpty && list.isEmpty {
                    Text("无匹配会话")
                        .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49C))
                        .padding(.vertical, 5).padding(.leading, 25)
                }
            }
        }
    }

    private func sessRow(_ s: SessRowItem) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(s.id == activeID ? Color(hex: 0xE0833C) : Color.clear)
                .frame(width: 6, height: 6)
            if renamingID == s.id {
                TextField("", text: $renameVal, onCommit: { commitRename(s.id) })
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
            } else {
                Text(s.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(s.id == activeID ? Color(hex: 0x242420) : Color(hex: 0x6E6B64))
                    .lineLimit(1)
                Spacer()
                Button {
                    renamingID = s.id
                    renameVal = s.title
                } label: {
                    Image(systemName: "pencil").font(.system(size: 9))
                        .foregroundStyle(Color(hex: 0xA8A49C).opacity(0.9))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .padding(.leading, 17)
        .background(s.id == activeID ? Color.white.opacity(0.9) : Color.clear)
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if renamingID == s.id { commitRename(s.id) } else { onSelect(s.id) }
        }
    }

    private func commitRename(_ sid: String) {
        let t = renameVal.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { store.rename(sessionID: sid, title: t) }
        renamingID = nil
    }

    private func ftItem(_ icon: String, _ label: String, _ badge: String?, _ panel: String) -> some View {
        Button { onOpenPanel(panel) } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 13))
                Text(label).font(.system(size: 12.5))
                Spacer()
                if let b = badge {
                    Text(b).font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xA8A49C))
                }
            }
            .foregroundStyle(Color(hex: 0x6E6B64))
            .padding(.vertical, 6).padding(.horizontal, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
