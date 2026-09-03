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

// MARK: - Toast：顶部居中悬浮提示，自动淡出（用户指定形态）

struct Toast: Identifiable, Equatable {
    enum Kind { case info, warn, error, success }
    let id = UUID()
    let text: String
    let kind: Kind
}

@MainActor
final class ToastCenter: ObservableObject {
    static let shared = ToastCenter()
    @Published var toasts: [Toast] = []

    func show(_ text: String, kind: Toast.Kind = .info, duration: TimeInterval = 3.5) {
        let t = Toast(text: text, kind: kind)
        withAnimation(.easeOut(duration: 0.2)) { toasts.append(t) }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            withAnimation(.easeIn(duration: 0.5)) {
                self?.toasts.removeAll { $0.id == t.id }
            }
        }
    }
}

struct ToastOverlay: View {
    @ObservedObject var center = ToastCenter.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(center.toasts) { t in
                HStack(spacing: 8) {
                    Image(systemName: icon(t.kind))
                    Text(t.text).font(.footnote).lineLimit(3)
                }
                .foregroundStyle(Color.white)
                .padding(.vertical, 9).padding(.horizontal, 14)
                .background(bg(t.kind))
                .cornerRadius(10)
                .shadow(color: .black.opacity(0.25), radius: 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }

    private func icon(_ k: Toast.Kind) -> String {
        switch k {
        case .info: return "info.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .success: return "checkmark.seal.fill"
        }
    }

    private func bg(_ k: Toast.Kind) -> Color {
        switch k {
        case .info: return Color(hex: 0x3A3A38).opacity(0.94)
        case .warn: return Color(hex: 0xB57308).opacity(0.96)
        case .error: return Color(hex: 0xB3403A).opacity(0.96)
        case .success: return Color(hex: 0x2F7D4F).opacity(0.96)
        }
    }
}

// MARK: - 根视图（M4 完整三栏：左导航 / 主会话 / 右终端 + 审批卡 + Toast）

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
    @State private var showSettings = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 252)

                Divider().overlay(Color.black.opacity(0.08))

                mainPane
                    .frame(maxWidth: .infinity)

                Divider().overlay(Color.black.opacity(0.08))

                terminalPanel
                    .frame(width: 420)
            }

            ToastOverlay()
                .zIndex(40)

            if let req = agent.pendingApproval {
                ApprovalCardView(req: req) { agent.resolveApproval($0) }
                    .zIndex(45)
            }

            if showSettings {
                Color.black.opacity(0.35).ignoresSafeArea().zIndex(49)
                    .onTapGesture { showSettings = false }
                SettingsSheet(onClose: { showSettings = false })
                    .zIndex(50)
            }
        }
        .background(Color(hex: 0xF6F5F1))
        .task { await run() }
        .onReceive(timer) { _ in
            terminalShown = ConsoleHub.text
        }
    }

    // MARK: 左栏（会话导航）

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("青山")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Spacer()
                Button {
                    agent.startNew(title: "新会话")
                    store.refresh()
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Text("会话")
                        .font(.caption2).foregroundStyle(Color.secondary)
                        .padding(.horizontal, 10).padding(.top, 4)
                    ForEach(store.sessions) { s in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(agent.sessionID == s.id && phase == .ready ? Color.accentColor : Color.secondary.opacity(0.5))
                                .frame(width: 6, height: 6)
                            Text(s.title)
                                .font(.system(size: 12.5))
                                .lineLimit(1)
                            Spacer()
                            if agent.sessionID == s.id {
                                Button {
                                    store.deleteSession(id: s.id)
                                    if agent.sessionID == s.id {
                                        agent.startNew(title: "新会话")
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 7).padding(.horizontal, 10)
                        .background(agent.sessionID == s.id ? Color.white : Color.clear)
                        .cornerRadius(8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard agent.sessionID != s.id else { return }
                            agent.load(sessionID: s.id)
                        }
                    }
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            Divider()
            sideEntry("list.bullet", "任务队列") { ToastCenter.shared.show("任务队列在 M7 交付", kind: .info) }
            sideEntry("puzzlepiece.fill", "插件") { ToastCenter.shared.show("插件在 M7 交付", kind: .info) }
            sideEntry("brain", "记忆") { ToastCenter.shared.show("记忆系统在 M6 交付", kind: .info) }
        }
        .background(Color(hex: 0xEFEEE9))
        .onAppear { store.refresh() }
        .onChange(of: phase) { _ in store.refresh() }
    }

    private func sideEntry(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12))
                Text(label).font(.footnote)
                Spacer()
            }
            .foregroundStyle(Color.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
        }
        .buttonStyle(.plain)
    }

    // MARK: 主区（会话视图）

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle()
                    .fill(settings.hasKey ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(settings.hasKey ? "真大脑 · \(settings.model)" : "假大脑 · 未配 Key")
                    .font(.caption).foregroundStyle(Color.secondary)
                Spacer()
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            switch phase {
            case .installing:
                bootStatus("正在装配 Alpine rootfs（仅首次）…", icon: "externaldrive.badge.timemachine")
                Spacer()
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Linux 内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
                }
                .padding(.horizontal, 20)
                Spacer()
            case .failed(let msg):
                bootStatus("失败：\(msg)", icon: "xmark.octagon.fill", color: .red)
                Spacer()
            case .ready:
                chatPane
            }
        }
    }

    private func bootStatus(_ text: String, icon: String, color: Color = .secondary) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).font(.footnote)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 20)
    }

    // MARK: 会话视图（Codex 式消息流）

    private var chatPane: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if agent.messages.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("青山 Agent 已就绪").font(.headline)
                                Text("对 Agent 说什么都行；它会用 run_command 工具在 Linux 沙箱里执行命令。\n试试：「检查一下工作环境」「帮我写一个 hello.py」「磁盘还剩多少空间」。")
                                    .font(.subheadline).foregroundStyle(Color.secondary)
                            }
                            .padding(.vertical, 40)
                        }
                        ForEach(agent.messages) { m in
                            messageRow(m).id(m.id)
                        }
                        if agent.isThinking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Agent 工作中…").font(.footnote).foregroundStyle(Color.secondary)
                            }
                        }
                        Color.clear.frame(height: 8).id("chat-bottom")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                }
                .onChange(of: agent.messages.count) { _ in
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                }
                .onChange(of: agent.isThinking) { _ in
                    proxy.scrollTo("chat-bottom", anchor: .bottom)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text("❯").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color.accentColor)
                TextField("对 Agent 说什么…（Enter 发送）", text: $chatInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .onSubmit(sendChat)
                    .disabled(agent.pendingApproval != nil)
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || agent.isThinking ? Color.gray.opacity(0.4) : Color.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(chatInput.trimmingCharacters(in: .whitespaces).isEmpty || agent.isThinking)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
                VStack(alignment: .leading, spacing: 6) {
                    if let r = m.reasoning, !r.isEmpty {
                        Text("Thinking").font(.caption2).foregroundStyle(Color.secondary)
                        Text(r)
                            .font(.system(size: 12.5))
                            .italic()
                            .foregroundStyle(Color.secondary)
                            .textSelection(.enabled)
                    }
                    if !m.text.isEmpty {
                        Text(m.text).textSelection(.enabled)
                    }
                }
            }
        case .tool:
            ToolMessageRow(m: m)
        }
    }

    // MARK: 右栏终端面板（M1 交付，保留）

    private var terminalPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill").font(.system(size: 10))
                    Text("终端").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color.primary)
                .padding(.vertical, 6).padding(.horizontal, 12)
                .background(Color(hex: 0xFBFAF7))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .background(Color(hex: 0xEFEEE9))

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
                Text("❯").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color.accentColor)
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
                            .background(exec.pendingCommand.isEmpty || phase != .ready ? Color.gray.opacity(0.5) : Color.accentColor)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(exec.pendingCommand.isEmpty || phase != .ready)
                }
            }
            .padding(10)
            .background(Color(hex: 0xFBFAF7))

            Divider()

            HStack(spacing: 10) {
                Text(exec.statusLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondary).lineLimit(1)
                Spacer()
                Picker("", selection: $exec.timeoutIdx) {
                    Text("30s").tag(0)
                    Text("120s").tag(1)
                    Text("不限").tag(2)
                }
                .pickerStyle(.segmented).controlSize(.mini).frame(width: 150)
                .disabled(exec.isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(hex: 0xF1F0EB))
        }
        .background(Color(hex: 0xFBFAF7))
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

        // M2 语义：杀 App 重进自动恢复最近会话
        if !agent.resumeLatest() {
            agent.startNew(title: "新会话")
        }
        phase = .ready
    }

    private func sendChat() {
        let t = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        chatInput = ""
        agent.send(t)
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

// MARK: - 工具消息行（Codex 式单行 + 点开展开输出）

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

// MARK: - 审批卡（Agent 挂起等待用户决定）

struct ApprovalCardView: View {
    let req: ApprovalRequest
    let onDecide: (ApprovalDecision) -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "shield.lefthalf.filled")
                        .foregroundStyle(Color(hex: 0xB57308))
                    Text("Agent 想执行命令").font(.system(size: 15, weight: .semibold))
                }
                Text(req.reason).font(.footnote).foregroundStyle(Color.secondary)

                Text(req.command)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.06))
                    .cornerRadius(8)
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button {
                        onDecide(.allowOnce)
                    } label: {
                        Text("允许一次").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color(hex: 0xD97706))
                    Button {
                        onDecide(.allowAlways)
                    } label: {
                        Text("始终允许").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button {
                        onDecide(.deny)
                    } label: {
                        Text("拒绝").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.top, 2)
            }
            .padding(18)
            .frame(width: 470)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.22), radius: 24)
        }
    }
}
