import Foundation

/// M1 执行桥控制器：一次性命令执行 · 流式输出 · 停止 · 超时治理。
/// 底座 = ISHShellExecutor（管道版：become_new_init_child + 双 reader 线程 + exit 通知）。
/// 输出自动写入 ConsoleHub（右栏终端面板轮询显示）。
final class ExecutionController: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "就绪"
    @Published var pendingCommand = ""
    @Published var timeoutIdx = 0                 // 0:30s 1:120s 2:不限

    private var timeouts: [Double?] = [30, 120, nil]
    private var currentPid: Int32 = 0
    private var timeoutWork: DispatchWorkItem?
    private let guestSIGKILL: Int32 = 9           // kernel/signal.h: SIGKILL_

    func runPending() {
        let cmd = pendingCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty, !isRunning else { return }
        pendingCommand = ""
        ConsoleHub.appendLine("\u{1F539} \(cmd)")
        run(cmd, timeout: timeouts[timeoutIdx])
    }

    /// 立即停止当前命令（SIGKILL 直发）
    func stop() {
        killCurrent()
    }

    // MARK: 私有执行路径

    private func run(_ command: String, timeout: TimeInterval?) {
        guard !isRunning else {
            ConsoleHub.appendLine("（已有命令在运行——先停止或等它结束）")
            return
        }
        isRunning = true
        statusLine = "运行中…"

        if let timeout, timeout > 0 {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning, self.currentPid > 0 else { return }
                ConsoleHub.appendLine("⏱ 超时（\(Int(timeout))s）—— 发送 SIGKILL")
                self.killCurrent()
            }
            timeoutWork = w
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: w)
        }

        let pid = ISHShellExecutor.executeCommand(command, lineCallback: { line, isErr in
            ConsoleHub.append((isErr ? "⃠ " : "") + line + "\n")
        }, completion: { [weak self] result in
            guard let self else { return }
            self.timeoutWork?.cancel()
            self.timeoutWork = nil
            self.currentPid = 0
            self.isRunning = false

            let dur = String(format: "%.1fs", result.duration)
            let msg: String
            switch result.error {
            case .none:
                msg = result.exitCode == 0 ? "完成 · \(dur)" : "退出码 \(result.exitCode) · \(dur)"
            case .timeout:
                msg = "超时终止（进程已杀，无泄漏）· \(dur)"
            case .cancelled:
                msg = "已停止 · \(dur)"
            default:
                msg = "执行器错误 \(result.error.rawValue) · \(dur)"
            }
            self.statusLine = msg
            ConsoleHub.appendLine("— " + msg)
        })

        if pid < 0 {
            timeoutWork?.cancel()
            timeoutWork = nil
            currentPid = 0
            isRunning = false
            statusLine = "启动失败 rc=\(pid)"
            ConsoleHub.appendLine("— " + statusLine)
        } else {
            currentPid = pid
            statusLine = "运行中… pid=\(pid)"
        }
    }

    private func killCurrent() {
        guard currentPid > 0 else { return }
        ISHShellExecutor.killProcess(currentPid, withSignal: guestSIGKILL)
    }
}
