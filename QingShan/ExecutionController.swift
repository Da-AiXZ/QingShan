import Foundation

/// M1 执行桥控制器：一次性命令执行 · 流式输出 · 停止 · 超时治理。
/// 底座 = ISHShellExecutor（管道版：become_new_init_child + 双 reader 线程 + exit 通知）。
/// 治理语义（架构 §6.2/6.4/6.5 的 M1 子集）：
///   - stop() 立即杀 guest 进程（信号直发，不走任何可能死锁的队列）
///   - 超时到期 → SIGKILL → completion 经 exit 通知触发 → 状态复位，可继续跑新命令（无泄漏验证点）
/// 完整 ExecCoordinator（并发上限/进程组追杀/claimResume 单次化）在后续里程碑按需演进。
final class ExecutionController: ObservableObject {
    @Published var isRunning = false
    @Published var statusLine = "就绪"

    private var currentPid: Int32 = 0
    private var timeoutWork: DispatchWorkItem?
    private let guestSIGKILL: Int32 = 9   // kernel/signal.h: SIGKILL_

    var isReadyToRun: Bool { !isRunning }

    /// 执行一条命令。onLine 流式回调（已保证主线程）；onDone 完成时主线程回调一次。
    func run(_ command: String,
             timeout: TimeInterval?,
             onLine: @escaping (String) -> Void,
             onDone: @escaping (String) -> Void) {
        guard !isRunning else {
            onDone("已有命令在运行——先点停止或等它结束")
            return
        }
        isRunning = true
        statusLine = "运行中…"

        // 超时治理：到期杀进程；completion 由 exit 通知收尾
        if let timeout, timeout > 0 {
            let w = DispatchWorkItem { [weak self] in
                guard let self, self.isRunning, self.currentPid > 0 else { return }
                ConsoleHub.append("\n⏱ 超时（\(Int(timeout))s）—— 发送 SIGKILL\n")
                self.killCurrent()
            }
            timeoutWork = w
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: w)
        }

        let pid = ISHShellExecutor.executeCommand(command, lineCallback: { line, isErr in
            onLine((isErr ? "⃠ " : "") + line)
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
            onDone(msg)
        })

        if pid < 0 {
            timeoutWork?.cancel()
            timeoutWork = nil
            currentPid = 0
            isRunning = false
            statusLine = "启动失败 rc=\(pid)"
            onDone(statusLine)
        } else {
            currentPid = pid
            statusLine = "运行中… pid=\(pid)"
        }
    }

    /// 立即停止当前命令（SIGKILL 直发）
    func stop() {
        killCurrent()
    }

    private func killCurrent() {
        guard currentPid > 0 else { return }
        ISHShellExecutor.killProcess(currentPid, withSignal: guestSIGKILL)
    }
}
