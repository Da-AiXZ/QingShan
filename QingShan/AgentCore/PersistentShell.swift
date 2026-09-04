import Foundation

// MARK: - 持久 shell（M5 bash-persistent，dsh tool-bash-persistent 语义）
//
// 语义：常驻 shell（boot 后的 /bin/sh -l）+ cd/export 状态跨调用保持。
//
// 输出捕获采用【文件协议】而非流解析（iSH PTY 流的换行/回显行为不可靠，
// 真机验收曾出现标记同行/退出码丢失/首字符回显）：
//   eval 'CMD' >/tmp/.qs_o 2>&1; echo $? >/tmp/.qs_r; touch /tmp/.qs_done; cat /tmp/.qs_o
// Swift 侧轮询 /tmp/.qs_done（guest /tmp = host Documents/root/data/tmp），
// 然后直接读 .qs_r（退出码）与 .qs_o（输出）——不受回显/换行/标记影响。
// cat 把输出回显到终端面板（ConsoleHub 可见，与 HTML 形态一致）。

@MainActor
final class PersistentShell {
    static let shared = PersistentShell()

    private var initialized = false

    // guest / = host Documents/root/data（fakefs 布局，终端 mount 输出已证实）
    private var outURL: URL { FirstRun.rootURL.appendingPathComponent("data/tmp/.qs_o") }
    private var rcURL: URL { FirstRun.rootURL.appendingPathComponent("data/tmp/.qs_r") }
    private var doneURL: URL { FirstRun.rootURL.appendingPathComponent("data/tmp/.qs_done") }

    private var readyConfirmed = false

    private func ensureInitialized() {
        guard !initialized else { return }
        initialized = true
        // 抑制回显（命令文本不再出现在终端流；文件协议下非必需但保持终端干净）
        ISHKernel.shared.sendInputString("stty -echo\n")
    }

    /// 首条命令的就绪探测：注入后 3s 仍无 done 文件则重发（最多 2 次），
    /// 防 boot 后交互 shell 尚未就绪时命令被吞导致整轮超时。
    private func reinjectIfNeeded(_ wrapped: String, startedAt: Date, tries: inout Int) {
        guard !readyConfirmed, Date().timeIntervalSince(startedAt) > 3, tries < 2 else { return }
        tries += 1
        ISHKernel.shared.sendInputString(wrapped + "\n")
    }

    /// 在持久 shell 中执行一条命令（cd/export 等状态跨调用保持）
    func run(_ command: String, timeout: TimeInterval) async -> PersistentShellResult {
        ensureInitialized()
        let fm = FileManager.default
        for u in [outURL, rcURL, doneURL] { try? fm.removeItem(at: u) }

        // POSIX 单引号转义：' -> '\''
        let escaped = command.replacingOccurrences(of: "'", with: "'\\''")
        let wrapped = "eval '\(escaped)' >/tmp/.qs_o 2>&1; "
            + "echo $? >/tmp/.qs_r; touch /tmp/.qs_done; cat /tmp/.qs_o"
        ISHKernel.shared.sendInputString(wrapped + "\n")

        let startedAt = Date()
        var reinjectTries = 0
        // 轮询完成文件（60ms；iSH fakefs 是宿主真实文件，读它是本地 IO）
        while Date().timeIntervalSince(startedAt) < timeout {
            try? await Task.sleep(nanoseconds: 60_000_000)
            if fm.fileExists(atPath: doneURL.path) {
                readyConfirmed = true
            } else {
                reinjectIfNeeded(wrapped, startedAt: startedAt, tries: &reinjectTries)
                continue
            }
            let exit = Int(String(data: fm.contents(atPath: rcURL.path) ?? Data(),
                                  encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? -1
            let output = String(data: fm.contents(atPath: outURL.path) ?? Data(),
                                encoding: .utf8) ?? ""
            try? fm.removeItem(at: doneURL)
            let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
            return PersistentShellResult(exitCode: exit, output: trimmed(output),
                                         timedOut: false, durationMs: ms)
        }

        // 超时：Ctrl-C 前台命令，尽力读部分输出（退出码 124 = timeout 惯例）
        ISHKernel.shared.sendInputString("\u{0003}")
        try? await Task.sleep(nanoseconds: 400_000_000)
        let partial = String(data: fm.contents(atPath: outURL.path) ?? Data(),
                             encoding: .utf8) ?? ""
        for u in [outURL, rcURL, doneURL] { try? fm.removeItem(at: u) }
        let ms = Int(Date().timeIntervalSince(startedAt) * 1000)
        return PersistentShellResult(
            exitCode: 124,
            output: (trimmed(partial).isEmpty ? "" : trimmed(partial) + "\n")
                + "[命令超时（\(Int(timeout))s）——已发送 Ctrl-C，以上为部分输出]",
            timedOut: true, durationMs: ms)
    }

    private func trimmed(_ s: String) -> String {
        var r = s
        while r.hasPrefix("\n") || r.hasPrefix("\r") { r.removeFirst() }
        while r.hasSuffix("\n") || r.hasSuffix("\r") { r.removeLast() }
        return r
    }
}

struct PersistentShellResult {
    let exitCode: Int
    let output: String
    let timedOut: Bool
    let durationMs: Int
}
