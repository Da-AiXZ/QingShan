import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}

// MARK: - 跨线程 console 缓冲

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

// MARK: - 根视图（M1：主区状态 + 右栏终端面板）

struct RootView: View {
    enum Phase: Equatable {
        case installing
        case booting
        case ready
        case failed(String)
    }

    @StateObject private var exec = ExecutionController()
    @State private var phase: Phase = .installing
    @State private var shown: String = ""
    @State private var input: String = ""
    @State private var timeoutIdx = 0                    // 0:30s 1:120s 2:不限
    private let timeouts: [Double?] = [30, 120, nil]
    private let timer = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    private let examples: [(String, String)] = [
        ("流式输出", "ping -c 5 1.1.1.1"),
        ("本地流式", "for i in 1 2 3 4 5; do echo tick $i; sleep 1; done"),
        ("超时演示", "sleep 600"),
        ("快速回显", "echo hello && uname -a"),
    ]

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
            shown = ConsoleHub.text
        }
    }

    private var terminalWidth: CGFloat { 430 }

    // MARK: 主区

    private var mainPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("青山")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("M1 · 执行桥 —— 命令在右侧终端面板执行").font(.subheadline).foregroundStyle(Color.secondary)
            }

            switch phase {
            case .installing:
                statusRow("externaldrive.badge.timemachine", "正在装配 Alpine rootfs（仅首次）…")
            case .booting:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Linux 内核启动中…").font(.footnote).foregroundStyle(Color.secondary)
                }
            case .ready:
                statusRow("checkmark.seal.fill", "Linux 就绪（Alpine aarch64）—— 右侧终端可输入命令")
            case .failed(let msg):
                statusRow("xmark.octagon.fill", "失败：\(msg)")
            }

            if phase == .ready {
                VStack(alignment: .leading, spacing: 8) {
                    Text("示例命令（点击直接执行）").font(.footnote).foregroundStyle(Color.secondary)
                    ForEach(examples, id: \.0) { item in
                        Button {
                            input = item.1
                            runCurrent()
                        } label: {
                            HStack {
                                Text(item.0).font(.footnote).fontWeight(.medium)
                                Spacer()
                                Text(item.1).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.secondary)
                            }
                            .padding(.vertical, 9).padding(.horizontal, 12)
                            .background(Color.white)
                            .cornerRadius(9)
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.black.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .disabled(exec.isRunning)
                    }
                }
            }

            Spacer()
        }
        .padding(24)
    }

    private func statusRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
            Text(text).font(.footnote)
        }
        .foregroundStyle(Color.secondary)
    }

    // MARK: 右栏终端面板

    private var terminalPanel: some View {
        VStack(spacing: 0) {
            // tab 条（M1 单 tab；后续里程碑在此追加 审查/文件 等）
            HStack(spacing: 2) {
                tabLabel("终端", icon: "terminal.fill", active: true)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .background(Color(hex: 0xEFEEE9))

            consoleView

            Divider()

            // 输入行
            HStack(spacing: 8) {
                Text("❯").font(.system(size: 14, weight: .bold, design: .monospaced)).foregroundStyle(Color.accentColor)
                TextField(phase == .ready ? "输入命令，Enter 执行" : "内核启动后可用…", text: $input)
                    .font(.system(size: 13, design: .monospaced))
                    .textFieldStyle(.plain)
                    .disabled(phase != .ready)
                    .onSubmit(runCurrent)
                if exec.isRunning {
                    Button(action: { exec.stop(); ConsoleHub.appendLine("（已请求停止）") }) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(Color.white)
                            .padding(7)
                            .background(Color.red)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .help("停止当前命令")
                } else {
                    Button(action: runCurrent) {
                        Image(systemName: "play.fill")
                            .foregroundStyle(Color.white)
                            .padding(7)
                            .background(input.trimmingCharacters(in: .whitespaces).isEmpty || phase != .ready ? Color.gray.opacity(0.5) : Color.accentColor)
                            .cornerRadius(7)
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || phase != .ready)
                }
            }
            .padding(10)
            .background(Color(hex: 0xFBFAF7))

            Divider()

            // 状态行 + 超时选择
            HStack(spacing: 10) {
                Text(exec.statusLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                Spacer()
                Picker("", selection: $timeoutIdx) {
                    Text("30s").tag(0)
                    Text("120s").tag(1)
                    Text("不限").tag(2)
                }
                .pickerStyle(.segmented)
                .controlSize(.mini)
                .frame(width: 150)
                .disabled(exec.isRunning)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(hex: 0xF1F0EB))
        }
        .background(Color(hex: 0xFBFAF7))
    }

    private func tabLabel(_ text: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 12, weight: active ? .semibold : .regular))
        }
        .foregroundStyle(active ? Color.primary : Color.secondary)
        .padding(.vertical, 6).padding(.horizontal, 12)
        .background(active ? Color(hex: 0xFBFAF7) : Color.clear)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
    }

    private var consoleView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(shown.isEmpty ? "（终端输出将显示在这里）" : shown)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(shown.isEmpty ? Color.secondary : Color(hex: 0xB8E8C8))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(Color(hex: 0x161816))
            .onChange(of: shown) { _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom") }
            }
        }
    }

    // MARK: 动作

    private func runCurrent() {
        let cmd = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, phase == .ready, !exec.isRunning else { return }
        input = ""
        ConsoleHub.appendLine("\u{1F539} \(cmd)")
        exec.run(cmd,
                 timeout: timeouts[timeoutIdx],
                 onLine: { line in ConsoleHub.append(line + "\n") },
                 onDone: { msg in ConsoleHub.appendLine("— " + msg) })
    }

    // MARK: boot 流程（沿用 M0.2）

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

        // 起常驻交互 shell（PID1 的会话；M1 的执行命令走独立进程，与此并存）
        _ = await Task.detached(priority: .utility) { () -> Int32 in
            let rc = ISHKernel.shared.executeCommand(["/bin/sh", "-l"])
            Thread.sleep(forTimeInterval: 1.0)
            return rc
        }.value

        ConsoleHub.appendLine("— 青山 M1 · 执行桥就绪：在下方输入命令，或点击左侧示例 —")
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
