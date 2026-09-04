import Foundation

// MARK: - 持久 shell（M5 bash-persistent，dsh tool-bash-persistent 语义）
//
// 语义对齐 dsh packages/shell/tool-bash-persistent：
// - 一个常驻交互 shell（boot 后的 /bin/sh -l），Agent 的命令全部注入它执行
// - 每条命令用一次性 nonce 标记包裹（单物理行，eval 展开），输出按标记切片
// - 结束标记携带退出码；超时发 Ctrl-C 返回部分输出
// - stty -echo 抑制回显，避免命令文本混入输出
//
// 与 dsh 的差异（M5 范围内刻意简化）：
// - 超时不 reset 整个 shell（只 Ctrl-C 前台命令，保留持久性）；完整 reset 语义后补
// - 输出源为全局 console 流（outputCallback 分流），非 scrollback 分页读取

@MainActor
final class PersistentShell {
    static let shared = PersistentShell()

    private var initialized = false
    private var pending: PendingRun?

    private struct PendingRun {
        let startMarker: String
        let endMarker: String
        var buffer: String = ""
        let timeout: TimeInterval
        let startedAt = Date()
        let continuation: CheckedContinuation<PersistentShellResult, Never>
    }

    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true
        // 抑制回显（dsh：echo suppression only）
        ISHKernel.shared.sendInputString("stty -echo\n")
    }

    /// console 输出分流入口（RootView 的 outputCallback 喂进来）
    func ingest(_ text: String) {
        guard var run = pending else { return }
        run.buffer += text

        // END 标记出现 → 提取退出码与输出切片
        if let endRange = run.buffer.range(of: run.endMarker) {
            let after = String(run.buffer[endRange.upperBound...])
            let digits = after.prefix { $0.isNumber }
            let exitCode = Int(digits) ?? 0

            let output: String
            if let startRange = run.buffer.range(of: run.startMarker) {
                output = String(run.buffer[startRange.upperBound..<endRange.lowerBound])
            } else {
                output = ""   // START 被截断丢弃（dsh LOST_PREFIX 语义，M5 简化）
            }
            pending = nil
            let ms = Int(Date().timeIntervalSince(run.startedAt) * 1000)
            run.continuation.resume(returning: PersistentShellResult(
                exitCode: exitCode,
                output: trimmed(output),
                timedOut: false,
                durationMs: ms))
        } else {
            pending = run
        }
    }

    /// 在持久 shell 中执行一条命令（cd/export 等状态跨调用保持）
    func run(_ command: String, timeout: TimeInterval) async -> PersistentShellResult {
        ensureInitialized()

        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
        let startMarker = "__QS_PS_START_\(nonce)__"
        let endMarker = "__QS_PS_END_\(nonce)__"

        // dsh wrapCommand：单物理行（避免 PS2 泄漏提示符/标记源文）
        let wrapped = "printf '%s\\n' \(bashQuote(startMarker)); "
            + "eval -- \(bashQuote(command)); "
            + "__qs_status=$?; "
            + "printf '%s%s\\n' \(bashQuote(endMarker)) \"$__qs_status\""

        return await withCheckedContinuation { cont in
            let run = PendingRun(startMarker: startMarker,
                                 endMarker: endMarker,
                                 timeout: timeout,
                                 continuation: cont)
            pending = run
            ISHKernel.shared.sendInputString(wrapped + "\n")

            // 超时看门狗：Ctrl-C 前台命令 + 部分输出（退出码 124 = timeout 惯例）
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { self?.timeoutFired(run) }
            }
        }
    }

    private func timeoutFired(_ run: PendingRun) {
        guard pending === run else { return }   // 已正常完成
        ISHKernel.shared.sendInputString("\u{0003}")   // Ctrl-C 终止前台命令
        pending = nil
        let partial = partialOutput(of: run)
        let ms = Int(Date().timeIntervalSince(run.startedAt) * 1000)
        run.continuation.resume(returning: PersistentShellResult(
            exitCode: 124,
            output: (partial.isEmpty ? "" : partial + "\n")
                + "[命令超时（\(Int(run.timeout))s）——已发送 Ctrl-C，以下为部分输出]",
            timedOut: true,
            durationMs: ms))
    }

    private func partialOutput(of run: PendingRun) -> String {
        guard let startRange = run.buffer.range(of: run.startMarker) else { return "" }
        return trimmed(String(run.buffer[startRange.upperBound...]))
    }

    private func trimmed(_ s: String) -> String {
        var r = s
        while r.hasPrefix("\n") || r.hasPrefix("\r") { r.removeFirst() }
        while r.hasSuffix("\n") || r.hasSuffix("\r") { r.removeLast() }
        return r
    }

    /// dsh quoteForBash：$'...' 引用 + 转义（\\ ' \r \n）
    private func bashQuote(_ value: String) -> String {
        var s = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        // $ 字符在 $'...' 中不需转义，但为防标记被环境变量展开干扰，统一按 dsh 原样即可
        _ = s
        return "$'\(s)'"
    }
}

struct PersistentShellResult {
    let exitCode: Int
    let output: String
    let timedOut: Bool
    let durationMs: Int
}
