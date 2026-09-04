import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

// MARK: - 跨线程 console 缓冲（右栏终端面板用）

enum ConsoleHub {
    private static let lock = NSLock()
    private static var _text = ""

    static var text: String {
        lock.withLock { _text }
    }

    static func append(_ s: String) {
        lock.withLock {
            _text += s
            if _text.count > 128_000 {
                _text = String(_text.suffix(64_000))
            }
        }
    }

    static func appendLine(_ s: String) {
        append(s + "\n")
    }

    static func clear() {
        lock.withLock { _text = "" }
    }
}

// MARK: - 根视图（M4.5 完整形态：项目分组左栏 / ctxbar+hero+composer 主区 / 多 tab 右栏）

struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case ready
        case failed(String)
    }

    @StateObject private var agent = AgentSession()
    @StateObject private var exec = ExecutionController()
    @StateObject private var store = SessionStore()
    @StateObject private var settings = SettingsStore.shared
    @State private var phase: Phase = .installing
    @State private var terminalShown: String = ""
    @State private var chatInput: String = ""
    @State private var panel: String? = nil          // settings|memories|tasks|plugins|newproject
    @State private var tabs: [String] = []
    @State private var atb: String? = nil
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private var activeProject: Project? { ProjectStore.project(of: agent.sessionID) }
    private var sessMeta: [String: String] { ProjectStore.sessionMeta(agent.sessionID) }
    private var ctxUsed: Double { CtxUsage.usedPercent(history: agent.llmHistory) }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView(activeID: agent.sessionID,
                            onSelect: { agent.load(sessionID: $0); store.refresh() },
                            onNewChat: { newChat(in: nil) },
                            onNewChatIn: { pid in
                                newChat(in: pid)
                            },
                            onOpenPanel: { panel = $0 },
                            store: store)
                    .frame(width: 252)

                Divider().overlay(Color.black.opacity(0.08))

                mainPane
                    .frame(maxWidth: .infinity)

                Divider().overlay(Color.black.opacity(0.08))

                rightPane
                    .frame(width: 400)
            }

            ToastOverlay().zIndex(40)
            sheetLayer.zIndex(50)
        }
        .background(Color(hex: 0xF6F5F1))
        .task { await run() }
        .onReceive(timer) { _ in
            terminalShown = ConsoleHub.text
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("sessions.changed"))) { _ in
            store.refresh()
        }
    }

    private func newChat(in projectID: String?) {
        agent.startNew(title: "新对话")
        if let pid = projectID {
            ProjectStore.assign(sessionID: agent.sessionID, projectID: pid)
        }
        store.refresh()
    }

    // MARK: 主区（ctxbar + 消息流/hero + composer）

    private var mainPane: some View {
        VStack(spacing: 0) {
            switch phase {
            case .installing:
                bootStatus("正在装配 Alpine rootfs（仅首次）…", icon: "externaldrive.badge.timemachine")
                Spacer()
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Linux 内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                Spacer()
            case .failed(let msg):
                bootStatus("失败：\(msg)", icon: "xmark.octagon.fill", color: .red)
                Spacer()
            case .ready:
                ctxbar
                if agent.messages.isEmpty {
                    ScrollView {
                        emptyHero
                            .padding(.top, 50)
                    }
                } else {
                    chatScroll
                }
                ctxWarn
                ComposerBar(input: $chatInput,
                            policy: $agent.policy,
                            settings: settings,
                            ctxUsed: ctxUsed,
                            activeProject: activeProject,
                            sessionMeta: sessMeta,
                            onSend: sendChat,
                            onAssignProject: { p in
                                ProjectStore.assign(sessionID: agent.sessionID, projectID: p?.id)
                                store.refresh()
                            },
                            onNewProject: { panel = "newproject" },
                            onSetEnv: { v in
                                var m = sessMeta
                                m["loc"] = v
                                ProjectStore.setSessionMeta(agent.sessionID, m)
                                ToastCenter.shared.show(v == "cloud" ? "已切换到云端（mock）" : "已切换到本地", kind: .info)
                            },
                            onSetBranch: { b in
                                var m = sessMeta
                                m["branch"] = b
                                ProjectStore.setSessionMeta(agent.sessionID, m)
                                ToastCenter.shared.show("已切换到分支 \(b)", kind: .info)
                            },
                            onOpenPanel: { panel = $0 },
                            onSlashCommand: handleSlash)
            }
        }
    }

    private func bootStatus(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).font(.footnote)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 24)
    }

    // ctxbar（HTML .ctxbar：项目名 · 会话名 …… 模型 · 推理档）
    private var ctxbar: some View {
        HStack(spacing: 10) {
            Text(activeProject?.name ?? "未分配项目")
                .font(.system(size: 11, design: .monospaced))
            Text("·").foregroundStyle(Color(hex: 0xC9C6BE))
            Text(agent.sessionTitle.isEmpty ? "新对话" : agent.sessionTitle)
                .font(.system(size: 11.5)).lineLimit(1)
            Spacer()
            Text("\(settings.model.isEmpty ? "未配置" : settings.model) · 推理 \(EffortTier.current.label)")
                .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49C))
            Button { panel = "settings" } label: {
                Image(systemName: "slider.horizontal.3").font(.system(size: 13))
                    .foregroundStyle(Color(hex: 0x6E6B64))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(Color(hex: 0x8A8894))
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    // hero 空态（HTML EmptyHero 对齐）
    private var emptyHero: some View {
        VStack(spacing: 0) {
            Group {
                if let p = activeProject {
                    Text("你想让我们在 ") + Text(p.name).accentUnderline() + Text(" 中构建什么？")
                } else {
                    Text("你想让我们构建什么？")
                }
            }
            .font(.system(size: 25, weight: .bold))
            .foregroundStyle(Color(hex: 0x242420))
            .multilineTextAlignment(.center)
            .padding(.bottom, 8)

            Text("描述目标，Agent 会自己规划、执行、验证。")
                .font(.system(size: 13)).foregroundStyle(Color(hex: 0xA8A49C))
                .padding(.bottom, 30)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(MockData.suggestions.indices, id: \.self) { i in
                    let s = MockData.suggestions[i]
                    Button {
                        chatInput = s.fill
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: s.icon)
                                .font(.system(size: 15))
                                .foregroundStyle(Color(hex: 0xE0833C))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(s.b).font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(Color(hex: 0x242420))
                                Text(s.s).font(.system(size: 11.5))
                                    .foregroundStyle(Color(hex: 0xA8A49C))
                                    .multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white)
                        .cornerRadius(13)
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color(hex: 0xE5E2DC)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 490)
        }
        .padding(.horizontal, 32)
    }

    private var chatScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                chatMessages
            }
            .onChange(of: agent.messages.count) { _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
            }
            .onChange(of: agent.isThinking) { _ in
                proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
        }
    }

    private var chatMessages: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(agent.messages) { m in
                messageRow(m).id(m.id)
            }
            if agent.isThinking && agent.messages.last?.role != .think {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Agent 工作中…").font(.footnote).foregroundStyle(Color.secondary)
                }
            }
            Color.clear.frame(height: 8).id("chat-bottom")
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }

    // ctxwarn（HTML 剩余<25% = used>75%）
    @ViewBuilder
    private var ctxWarn: some View {
        if ctxUsed > 75 {
            HStack(spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 12))
                Text(String(format: "上下文即将用尽（已用 %.0f%%）。发送 /compact 压缩会话以继续。", ctxUsed))
                    .font(.system(size: 12))
            }
            .foregroundStyle(Color(hex: 0xB57308))
            .padding(.vertical, 8).padding(.horizontal, 14)
            .background(Color(hex: 0xFFFAF2))
            .cornerRadius(10)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func messageRow(_ m: ChatMessage) -> some View {
        switch m.role {
        case .user:
            HStack(alignment: .top, spacing: 0) {
                Text("›").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.secondary)
                    .frame(width: 15, alignment: .leading)
                Text(m.text)
                    .textSelection(.enabled)
                    .padding(9).padding(.vertical, 1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(9)
            }
        case .agent:
            HStack(alignment: .top, spacing: 0) {
                Text("•").foregroundStyle(Color.secondary).frame(width: 15, alignment: .leading)
                Text(m.text).textSelection(.enabled)
            }
        case .think:
            ThinkRowView(m: m)
        case .approval:
            ApprovalInlineRow(m: m) { agent.resolveApproval($0) }
        case .tool:
            ToolMessageRow(m: m)
        }
    }

    private func sendChat() {
        let t = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        chatInput = ""
        agent.send(t)
    }

    private func handleSlash(_ cmd: String) {
        chatInput = ""
        switch cmd {
        case "/new": newChat(in: nil)
        case "/compact": agent.compactNow()
        case "/review": openTab("review")
        case "/terminal": openTab("term")
        case "/files": openTab("files")
        case "/help":
            ToastCenter.shared.show("/new /compact /model /review /terminal /files /memories /tasks /plugins /permissions /settings", kind: .info, duration: 6)
        default: break
        }
    }

    // MARK: 右栏（多 tab 面板 + 空态）

    private var rightPane: some View {
        VStack(spacing: 0) {
            if tabs.isEmpty {
                rightEmpty
            } else {
                tabHeader
                switch atb {
                case "review": reviewTab
                case "files": filesTab
                default: termTab
                }
            }
        }
        .background(Color(hex: 0xFBFAF7))
    }

    private var tabHeader: some View {
        HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { t in
                HStack(spacing: 5) {
                    Image(systemName: tabIcon(t)).font(.system(size: 10))
                    Text(tabTitle(t)).font(.system(size: 12, weight: atb == t ? .semibold : .regular))
                    Button { closeTab(t) } label: {
                        Image(systemName: "xmark").font(.system(size: 8)).foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .foregroundStyle(atb == t ? Color.primary : Color.secondary)
                .padding(.vertical, 6).padding(.horizontal, 10)
                .background(atb == t ? Color(hex: 0xFBFAF7) : Color.clear)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                .contentShape(Rectangle())
                .onTapGesture { atb = t }
            }
            Menu {
                ForEach(["review", "term", "files"], id: \.self) { t in
                    if !tabs.contains(t) {
                        Button(tabTitle(t)) { openTab(t) }
                    }
                }
            } label: {
                Image(systemName: "plus").font(.system(size: 12))
                    .padding(.vertical, 6).padding(.horizontal, 8)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .background(Color(hex: 0xEFEEE9))
    }

    private func tabIcon(_ t: String) -> String {
        switch t {
        case "review": return "arrow.triangle.pull"
        case "files": return "folder"
        default: return "terminal.fill"
        }
    }

    private func tabTitle(_ t: String) -> String {
        switch t {
        case "review": return "审查"
        case "files": return "文件"
        default: return "终端"
        }
    }

    private func openTab(_ t: String) {
        if !tabs.contains(t) { tabs.append(t) }
        atb = t
    }

    private func closeTab(_ t: String) {
        tabs.removeAll { $0 == t }
        if atb == t { atb = tabs.last }
    }

    private var rightEmpty: some View {
        VStack(spacing: 10) {
            Spacer()
            rightRow("arrow.triangle.pull", "审查", "Ctrl+Shift+G", "review")
            rightRow("terminal", "终端", "Ctrl+`", "term")
            rightRow("safari", "浏览器", "Ctrl+T", "term")
            rightRow("folder", "文件", "Ctrl+P", "files")
            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private func rightRow(_ icon: String, _ label: String, _ key: String, _ tab: String) -> some View {
        Button { openTab(tab) } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(Color(hex: 0x8A8894))
                Text(label).font(.system(size: 12.5)).foregroundStyle(Color(hex: 0x4A4840))
                Spacer()
                Text(key).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color(hex: 0xA8A49C))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.white)
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    // 终端 tab（真输出流 + 手动命令）
    private var termTab: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(terminalShown.isEmpty ? "（终端输出将显示在这里）" : terminalShown)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(terminalShown.isEmpty ? Color.secondary : Color(hex: 0xB8E8C8))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("t-bottom")
                }
                .background(Color(hex: 0x161816))
                .onChange(of: terminalShown) { _ in
                    proxy.scrollTo("t-bottom", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("❯").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color(hex: 0xE0833C))
                TextField(phase == .ready ? "直接执行命令（独立进程）" : "内核启动后可用…", text: $exec.pendingCommand)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .disabled(phase != .ready)
                    .onSubmit { exec.runPending() }
                if exec.isRunning {
                    Button(action: { exec.stop(); ConsoleHub.appendLine("（已请求停止）") }) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(Color.white).padding(7)
                            .background(Color.red).cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: { exec.runPending() }) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(Color.white).padding(7)
                            .background(exec.pendingCommand.isEmpty || phase != .ready ? Color.gray.opacity(0.5) : Color(hex: 0xE0833C))
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(exec.pendingCommand.isEmpty || phase != .ready)
                }
            }
            .padding(10)
        }
    }

    // 审查 tab（真数据：会话内工具操作流）
    private var reviewTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                let toolMsgs = agent.messages.filter { $0.role == .tool }
                if toolMsgs.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.triangle.pull").font(.system(size: 22))
                            .foregroundStyle(Color(hex: 0xC9C6BE))
                        Text("暂无改动").font(.system(size: 13, weight: .semibold))
                        Text("Agent 修改文件后，这里会列出全部变更。")
                            .font(.system(size: 11.5)).foregroundStyle(Color(hex: 0xA8A49C))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 60)
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 12))
                        Text("\(sessMeta["branch"] ?? "main") ⇄ 会话内工具操作")
                            .font(.system(size: 11.5, design: .monospaced))
                        Spacer()
                        Text("\(toolMsgs.count) 次操作").font(.system(size: 11)).foregroundStyle(Color(hex: 0xA8A49C))
                    }
                    .padding(10)
                    .background(Color(hex: 0xF1EFEB))
                    .cornerRadius(8)
                    ForEach(toolMsgs) { m in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Image(systemName: (m.exitCode ?? 0) == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle((m.exitCode ?? 0) == 0 ? Color.green : Color.red)
                                Text(m.text).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                                Spacer()
                                if let ms = m.durationMs {
                                    Text(String(format: "%.1fs", Double(ms) / 1000))
                                        .font(.system(size: 10.5)).foregroundStyle(Color(hex: 0xA8A49C))
                                }
                            }
                            if let out = m.output, !out.isEmpty {
                                Text(out)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(Color(hex: 0x8A8894))
                                    .lineLimit(6)
                            }
                        }
                        .padding(10)
                        .background(Color.white)
                        .cornerRadius(8)
                    }
                }
            }
            .padding(10)
        }
    }

    // 文件 tab（点击 → 终端 cat 预览，真数据）
    private var filesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MockData.workspaceFiles, id: \.self) { f in
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 10)).foregroundStyle(Color.secondary)
                        Text(f).font(.system(size: 12, design: .monospaced)).lineLimit(1)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 8)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        ConsoleHub.appendLine("❯ cat '\(f)' 2>&1 | head -40")
                        exec.run("cat '\(f)' 2>&1 | head -40", timeout: 10, onLine: { _ in }, onDone: { _ in })
                        openTab("term")
                    }
                }
            }
            .padding(10)
        }
    }

    // MARK: 面板弹层接线

    @ViewBuilder
    private var sheetLayer: some View {
        if panel != nil {
            Color.black.opacity(0.3).ignoresSafeArea()
                .onTapGesture { panel = nil }
                .zIndex(49)
            Group {
                switch panel {
                case "settings": AnyView(SettingsSheet(onClose: { panel = nil }))
                case "memories": AnyView(MemoriesSheet(onClose: { panel = nil }))
                case "tasks": AnyView(TasksSheet(onClose: { panel = nil }))
                case "plugins": AnyView(PluginsSheet(onClose: { panel = nil }))
                case "skills": AnyView(SkillsSheet(onClose: { panel = nil }))
                case "newproject": AnyView(CreateProjectSheet(onClose: { panel = nil }, onCreate: { name in
                    _ = ProjectStore.addProject(name: name)
                    store.refresh()
                    ToastCenter.shared.show("项目「\(name)」已创建", kind: .success)
                }))
                default: AnyView(EmptyView())
                }
            }
            .zIndex(51)
        }
    }

    // MARK: 流程

    private func run() async {
        if !FirstRun.isInstalled {
            do { try FirstRun.install() } catch {
                phase = .failed("rootfs 装配失败：\((error as NSError).localizedDescription)")
                return
            }
        }

        ISHKernel.shared.outputCallback = { data in
            if let s = String(data: data, encoding: .utf8) {
                ConsoleHub.append(s)
            }
        }

        phase = .booting

        let bootErr: String? = await Task.detached(priority: .userInitiated) { () -> String? in
            let rc = RootView.bootKernel()
            return rc == 0 ? nil : "boot rc=\(rc)"
        }.value

        if let bootErr {
            phase = .failed(bootErr)
            return
        }

        _ = await Task.detached(priority: .utility) { () -> Int32 in
            let rc = ISHKernel.shared.executeCommand(["/bin/sh", "-l"])
            Thread.sleep(forTimeInterval: 1.0)
            return rc
        }.value

        if !agent.resumeLatest() {
            agent.startNew(title: "新对话")
        }
        store.refresh()
        phase = .ready
    }

    private static func bootKernel() -> Int32 {
        let rc = ISHKernel.shared.boot(withRootPath: FirstRun.rootURL.path)
        if rc != 0 { return rc }
        for _ in 0..<300 {
            if ISHKernel.shared.isBooted { return 0 }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return -99
    }
}

// MARK: - hero 项目名橙色下划线

extension Text {
    func accentUnderline() -> Text {
        self.underline(true, color: Color(hex: 0xE0833C))
    }
}

// MARK: - Think 行（spinner Thinking → 折叠摘要 + 点击展开全文）

struct ThinkRowView: View {
    let m: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { if !m.running { expanded.toggle() } }) {
                HStack(spacing: 7) {
                    if m.running {
                        Text("⠋").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.secondary)
                        Text("Thinking").font(.system(size: 12.5, weight: .semibold))
                        Text("· 正在整理思路…").font(.system(size: 12)).foregroundStyle(Color.secondary)
                    } else {
                        Image(systemName: "brain").font(.system(size: 11)).foregroundStyle(Color.secondary)
                        Text("Think").font(.system(size: 12.5, weight: .semibold))
                        Text("· \(m.summary.isEmpty ? String(m.text.prefix(60)) : m.summary)")
                            .font(.system(size: 12)).foregroundStyle(Color.secondary).lineLimit(1)
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10)).foregroundStyle(Color.secondary)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded, !m.running, !m.text.isEmpty {
                Text(m.text)
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(Color.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.04))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - 审批内联卡（消息流内，HTML MsgApproval 形态）

struct ApprovalInlineRow: View {
    let m: ChatMessage
    let onDecide: (ApprovalDecision) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if m.decision == nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 13))
                            .foregroundStyle(Color(hex: 0xB57308))
                        Text("Agent 想执行命令").font(.system(size: 13, weight: .semibold))
                    }
                    Text(m.output ?? "")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.05))
                        .cornerRadius(7)
                        .textSelection(.enabled)
                    Text(m.reasonText).font(.caption).foregroundStyle(Color.secondary)
                    HStack(spacing: 8) {
                        Button { onDecide(.allowOnce) } label: {
                            Text("允许一次")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.white)
                                .padding(.vertical, 6).padding(.horizontal, 12)
                                .background(Color(hex: 0x242422))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        Button { onDecide(.allowAlways) } label: {
                            Text("始终允许此类")
                                .font(.system(size: 12))
                                .padding(.vertical, 6).padding(.horizontal, 12)
                                .background(Color.black.opacity(0.06))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        Button { onDecide(.deny) } label: {
                            Text("拒绝")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.red)
                                .padding(.vertical, 6).padding(.horizontal, 12)
                                .background(Color.red.opacity(0.08))
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .frame(maxWidth: 640, alignment: .leading)
                .background(Color(hex: 0xFFFAF2))
                .cornerRadius(12)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(hex: 0xECD9BD)))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: m.decision == "deny" ? "xmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(m.decision == "deny" ? Color.red : Color.green)
                    Text(m.decision == "deny" ? "denied" : "approved")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(m.output ?? "")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Color.secondary).lineLimit(1)
                    Text(m.decision == "once" ? "this time" : m.decision == "always" ? "every time this session" : "")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 工具消息行（单行 + 点开展开输出）

struct ToolMessageRow: View {
    let m: ChatMessage
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { expanded.toggle() }) {
                HStack(spacing: 7) {
                    if m.running {
                        Text("⠋").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.secondary)
                    } else if m.denied {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                    } else {
                        Image(systemName: (m.exitCode ?? 0) == 0 ? "circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle((m.exitCode ?? 0) == 0 ? Color.green : Color.red)
                    }
                    Text(m.running ? "Running" : m.denied ? "Denied" : "Ran")
                        .font(.system(size: 12.5, weight: .semibold))
                    Text(m.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                    if let ms = m.durationMs, !m.running {
                        Text("· \(String(format: "%.1f", Double(ms) / 1000))s")
                            .font(.system(size: 11)).foregroundStyle(Color.secondary)
                    }
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10)).foregroundStyle(Color.secondary)
                }
            }
            .buttonStyle(.plain)

            if expanded, let out = m.output, !out.isEmpty {
                Text(out)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.05))
                    .cornerRadius(8)
                    .textSelection(.enabled)
            }
        }
    }
}
