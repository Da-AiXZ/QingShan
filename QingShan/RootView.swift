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

// MARK: - 根视图（M2：主区=Agent 会话，右栏=终端面板）

struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case ready
        case failed(String)
    }

    @StateObject private var agent = AgentSession()
    @StateObject private var exec = ExecutionController()
    @StateObject private var settings = SettingsStore.shared
    @State private var phase: Phase = .installing
    @State private var terminalShown: String = ""
    @State private var chatInput: String = ""
    @State private var showSettings = false
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            mainPane
                .frame(maxWidth: .infinity)

            Divider().overlay(Color.black.opacity(0.08))

            terminalPanel
                .frame(width: terminalWidth)
        }
        .background(Color(hex: 0xF6F5F1))
        .task { await run() }
        .onReceive(timer) { _ in
            terminalShown = ConsoleHub.text
        }
        .overlay {
            if showSettings {
                SettingsSheet(onClose: { showSettings = false })
            }
        }
    }

    private var terminalWidth: CGFloat { 420 }

    // MARK: 主区（Agent 会话）

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("青山")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("M3 · 真模型对话（大脑=DeepSeek BYOK）")
                    .font(.caption).foregroundStyle(Color.secondary)
                Spacer()
                Circle()
                    .fill(settings.hasKey ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(settings.hasKey ? "真大脑" : "假大脑·未配 Key")
                    .font(.caption2).foregroundStyle(Color.secondary)
                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15))
                }
                .buttonStyle(.plain)
                if phase == .ready {
                    Button {
                        agent.startNew(title: "新会话")
                    } label: {
                        Label("新会话", systemImage: "plus")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 10)

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
                                Text("大脑是脚本化假 LLM（M2 干跑）——验证会话记录与恢复机制。\n试试说：「跑个演示」「现在时间」「看看文件」。")
                                    .font(.subheadline).foregroundStyle(Color.secondary)
                            }
                            .padding(.vertical, 40)
                        }
                        ForEach(agent.messages.filter { !($0.role == .agent && $0.text.isEmpty) }) { m in
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
                Button(action: sendChat) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(chatInput.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.4) : Color.accentColor)
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
                Text(m.text).textSelection(.enabled)
            }
        case .tool:
            ToolMessageRow(m: m)
        }
    }

    // MARK: 右栏终端面板（M1 交付，保持不变）

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

        // 常驻交互 shell（右栏手敲用）
        _ = await Task.detached(priority: .utility) { () -> Int32 in
            let rc = ISHKernel.shared.executeCommand(["/bin/sh", "-l"])
            Thread.sleep(forTimeInterval: 1.0)
            return rc
        }.value

        // M2 核心：恢复最近会话（杀 App 重进不丢）；没有则开新会话
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
                    } else {
                        Image(systemName: (m.exitCode ?? 0) == 0 ? "circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle((m.exitCode ?? 0) == 0 ? Color.green : Color.red)
                    }
                    Text(m.running ? "Running" : "Ran")
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
