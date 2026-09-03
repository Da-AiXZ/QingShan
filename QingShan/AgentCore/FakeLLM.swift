import Foundation

/// M2 的脚本化假大脑，适配 M3 的流式协议（保留：无 Key 时也能玩 + 验收对照基线）。
final class FakeLLM: LLMAdapter {
    let name = "FakeBrain · 脚本化（无真智能）"

    func stream(messages: [LLMMessage], tools: [LLMToolDef]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                let lastUser = messages.last(where: { $0.role == .user })?.content ?? ""
                // 已有工具结果回喂 → 总结收尾
                let lastTool = messages.last(where: { $0.role == .tool })?.content

                let text: String
                let toolCalls: [LLMToolCall]

                if let toolOut = lastTool {
                    let lines = toolOut.split(separator: "\n").map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    let head = lines.prefix(3).joined(separator: " ｜ ")
                    text = "执行完毕。要点：\(head)\(lines.count > 3 ? "\n（共 \(lines.count) 行输出）" : "")"
                    toolCalls = []
                } else if lastUser.contains("演示") || lastUser.contains("uname") || lastUser.contains("系统") {
                    toolCalls = [LLMToolCall(id: "call_fake_1", name: "run_command",
                                             arguments: #"{"command":"uname -a && df -h / && cat /etc/alpine-release"}"#)]
                    text = ""
                } else if lastUser.contains("时间") || lastUser.contains("日期") {
                    toolCalls = [LLMToolCall(id: "call_fake_1", name: "run_command",
                                             arguments: #"{"command":"date '+%Y-%m-%d %H:%M:%S'"}"#)]
                    text = ""
                } else {
                    text = "（假大脑）收到：「\(lastUser)」。当前无 API Key——在设置里填入 DeepSeek Key 后我才有真智能。也可以继续玩我的固定剧本：「跑个演示」「现在时间」。"
                    toolCalls = []
                }

                if !text.isEmpty { continuation.yield(.textDelta(text)) }
                continuation.yield(.done(text: text, toolCalls: toolCalls,
                                         finishReason: toolCalls.isEmpty ? "stop" : "tool_calls",
                                         promptTokens: 0, completionTokens: 0))
                continuation.finish()
            }
        }
    }
}
