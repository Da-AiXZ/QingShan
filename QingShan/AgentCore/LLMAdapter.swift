import Foundation

// MARK: - LLM 适配器协议（M3 接真模型；M2 用 FakeLLM）
//
// 语义对齐 dsh：Agent 循环每一步向 LLM 要"下一个动作"——
// 要么纯文本回复（turn 结束），要么发起一次工具调用（结果回喂后继续）。

enum AgentResponse {
    /// 纯文本回复，turn 结束
    case say(text: String)
    /// 发起一次工具调用（结果会作为 toolOutput 回喂 respond）
    case callTool(command: String)
}

protocol LLMAdapter {
    var name: String { get }
    /// turn = 用户本轮输入；toolOutput = 上一次工具调用的输出（首轮为 nil）
    func respond(turn: String, toolOutput: String?) -> AgentResponse
}

// MARK: - FakeLLM：脚本化假大脑（M2 干跑专用，排除网络/模型变量）

final class FakeLLM: LLMAdapter {
    let name = "FakeBrain · 脚本化（M2）"

    func respond(turn: String, toolOutput: String?) -> AgentResponse {
        // 工具结果回来 → 总结收尾（第二段剧本）
        if let out = toolOutput {
            let lines = out.split(separator: "\n").map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let head = lines.prefix(3).joined(separator: " ｜ ")
            let tail = lines.count > 3 ? "（共 \(lines.count) 行输出）" : ""
            return .say(text: "执行完毕。要点：\(head)\(tail.isEmpty ? "" : "\n" + tail)")
        }

        let t = turn.lowercased()

        if t.contains("演示") || t.contains("uname") || t.contains("系统") || t.contains("环境") {
            return .callTool(command: "uname -a && df -h / && cat /etc/alpine-release")
        }
        if t.contains("时间") || t.contains("日期") || t.contains("date") {
            return .callTool(command: "date '+%Y-%m-%d %H:%M:%S %Z'")
        }
        if t.contains("文件") || t.contains("目录") || t.contains("看看") || t.contains("ls") {
            return .callTool(command: "ls -la /root && echo --- && ls /")
        }
        if t.contains("磁盘") || t.contains("空间") || t.contains("df") {
            return .callTool(command: "df -h /")
        }
        if t.contains("你好") || t.contains("hello") || t.contains("hi") || t.contains("在吗") {
            return .say(text: "你好！我是青山的 Agent 大脑（M2 干跑模式：脚本化假 LLM，没有真智能）。\n试试对我说：跑个演示 / 现在时间 / 看看文件 / 磁盘空间。")
        }
        return .say(text: "（假大脑）收到：「\(turn)」。\nM2 阶段我只会剧本里的几招——对我说「跑个演示」「现在时间」「看看文件」，可以看到我真的调用 Linux 命令并把结果总结给你。")
    }
}
