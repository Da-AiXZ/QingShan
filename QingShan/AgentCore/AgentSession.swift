import Foundation
import SwiftUI

// MARK: - 会话消息模型（UI 层，由事件重放或实时追加生成）

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String          // user/agent：正文；tool：命令
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var running: Bool = false
    var reasoning: String?

    enum Role { case user, agent, tool }

    static func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    static func agent(_ t: String) -> ChatMessage { ChatMessage(role: .agent, text: t) }
    static func tool(_ c: String) -> ChatMessage { ChatMessage(role: .tool, text: c) }
}

// MARK: - AgentSession：turn/step 循环（流式 + 真模型） + 事件溯源 + resume + auto-compact
//
// 循环语义对齐 dsh core/agent-loop（见「dsh语义对照笔记.md」）：
//   turn/start → [step/start → assistant/chunk* → assistant/message → tool/call+tool/result → step/end]* → turn/end(reason)
// M3 对齐进展：assistant/chunk ✓（流式入日志）；中断落 interrupted message ✓；
// 原生 function calling ✓（DeepSeek tools）。maxSteps 为本地护栏（dsh 用 max-tokens+abort）。

@MainActor
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var sessionTitle = ""

    private(set) var sessionID = ""
    private var log: SessionLog?
    private let toolTimeout: TimeInterval = 30
    private let maxSteps = 12
    private let compactThresholdTokens = 8_000   // 估算阈值（演示友好；正式版可调）
    private var turnNo = 0

    /// LLM 历史（与 UI messages 平行；OpenAI 协议形态）
    var llmHistory: [LLMMessage] = []

    static let systemPrompt = """
        你是青山（QingShan），运行在用户 iPad 上的本地 AI Agent。
        环境：你的命令在设备内置的 Alpine Linux (aarch64) 沙箱中以 root 身份执行，输出会原样返回给你。
        工具：run_command —— 执行一条 shell 命令。需要了解系统状态时主动使用它，不要凭空猜测。
        要求：回复用简体中文；简洁直接；不编造命令输出；多步任务先说计划再逐步执行。
        """

    init(llm: LLMAdapter? = nil) {
        _ = llm // 兼容旧签名；实际 adapter 每 turn 按 SettingsStore 构建
    }

    // MARK: 会话生命周期

    func startNew(title: String) {
        sessionID = "s" + String(Int(Date().timeIntervalSince1970 * 1000))
        log = SessionLog(sessionID: sessionID)
        turnNo = 0
        sessionTitle = title
        messages.removeAll()
        llmHistory = [.init(role: .system, content: Self.systemPrompt)]
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 新会话 \(sessionID)（大脑：\(brainName())）—")
    }

    /// 恢复最近会话：重放 JSONL 事件重建消息流 + LLM 历史。返回是否恢复出了内容。
    @discardableResult
    func resumeLatest() -> Bool {
        guard let id = SessionLog.latestSessionID() else { return false }
        let events = SessionLog.replay(sessionID: id)
        guard events.contains(where: { $0.type == SessionEvent.sessionHeaderType }) else { return false }

        sessionID = id
        log = SessionLog(sessionID: id)
        messages.removeAll()
        llmHistory = [.init(role: .system, content: Self.systemPrompt)]
        turnNo = 0

        var lastToolCallId: String?
        var lastToolCallName: String?

        for ev in events {
            switch ev.type {
            case SessionEvent.userMessage:
                if let t = ev.data.text {
                    messages.append(.user(t))
                    llmHistory.append(.init(role: .user, content: t))
                }
            case SessionEvent.assistantMessage:
                // 带 toolCallsJSON 的 assistant 消息 = 发起工具调用的一步
                if let json = ev.data.toolCallsJSON,
                   let data = json.data(using: .utf8),
                   let calls = try? JSONDecoder().decode([LLMToolCall].self, from: data) {
                    llmHistory.append(.init(role: .assistant, content: ev.data.text, toolCalls: calls))
                    if let t = ev.data.text, !t.isEmpty {
                        // 少见：工具调用同时带文本，也上屏
                        messages.append(.agent(t))
                    }
                } else if let t = ev.data.text {
                    messages.append(.agent(t))
                    llmHistory.append(.init(role: .assistant, content: t))
                }
            case SessionEvent.toolCall:
                lastToolCallId = ev.data.id
                lastToolCallName = ev.data.command
                messages.append(.tool(ev.data.command ?? lastToolCallName ?? "?"))
            case SessionEvent.toolResult:
                if messages.last?.role == .tool {
                    messages[messages.count - 1].output = ev.data.output
                    messages[messages.count - 1].exitCode = ev.data.exitCode.flatMap(Int.init)
                    messages[messages.count - 1].durationMs = ev.data.durationMs
                }
                llmHistory.append(.init(role: .tool,
                                        content: ev.data.output,
                                        toolCallId: lastToolCallId))
                lastToolCallId = nil
            case "compact":
                // 上下文压缩点：LLM 历史重置为摘要形态（消息流不受影响）
                if let sum = ev.data.text {
                    llmHistory = [
                        .init(role: .system, content: Self.systemPrompt),
                        .init(role: .user, content: "此前对话的交接摘要：\n\(sum)"),
                        .init(role: .assistant, content: "收到，我已了解此前上下文，继续。"),
                    ]
                }
            case SessionEvent.turnEnd:
                turnNo = max(turnNo, ev.data.turn ?? 0)
            default:
                break
            }
        }
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 已恢复会话 \(id)（\(messages.count) 条消息）—")
        return !messages.isEmpty
    }

    // MARK: 用户发消息

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking else { return }
        messages.append(.user(t))
        llmHistory.append(.init(role: .user, content: t))
        log?.append(SessionEvent.userMessage, .init(text: t))
        if sessionTitle.isEmpty || sessionTitle == "新会话" {
            sessionTitle = String(t.prefix(16))
        }
        Task { await runTurn(userText: t) }
    }

    // MARK: turn/step 循环（流式）

    private func runTurn(userText: String) async {
        isThinking = true
        defer { isThinking = false }

        await maybeCompact()

        turnNo += 1
        log?.append(SessionEvent.turnStart, .init(turn: turnNo))

        var reason = "completed"
        var stepNo = 0

        while stepNo < maxSteps {
            stepNo += 1
            log?.append(SessionEvent.stepStart, .init(turn: turnNo, step: stepNo))

            // assistant 流式占位行（含思考区）
            messages.append(.agent(""))
            var full = ""
            var reasoningAcc = ""
            var toolCalls: [LLMToolCall] = []
            var streamError: String?

            do {
                let adapter = makeAdapter()
                let stream = adapter.stream(messages: llmHistory, tools: [Self.runCommandTool])
                for try await ev in stream {
                    switch ev {
                    case .reasoningDelta(let d):
                        // 思考增量：实时上屏（dim 区），整块入 assistant/message 日志
                        reasoningAcc += d
                        messages[messages.count - 1].reasoning = reasoningAcc
                    case .textDelta(let d):
                        full += d
                        messages[messages.count - 1].text = full
                        // dsh：assistant/chunk 逐块入日志
                        log?.append(SessionEvent.assistantChunk, .init(turn: turnNo, step: stepNo, text: d))
                    case .done(let text, let calls, let fr, _, _):
                        if full.isEmpty, !text.isEmpty {
                            full = text
                            messages[messages.count - 1].text = text
                        }
                        toolCalls = calls
                        if fr == "length" { reason = "max-tokens" }
                    }
                }
            } catch {
                streamError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                reason = "error"
            }

            // 中断/完成都落 assistant/message（含思考块；中断即 dsh 的 interrupted 语义）
            let callsJSON = (try? JSONEncoder().encode(toolCalls)).flatMap { String(data: $0, encoding: .utf8) }
            messages[messages.count - 1].reasoning = reasoningAcc.isEmpty ? nil : reasoningAcc
            log?.append(SessionEvent.assistantMessage, .init(turn: turnNo, step: stepNo,
                                                             text: full,
                                                             toolCallsJSON: toolCalls.isEmpty ? nil : callsJSON,
                                                             reasoning: reasoningAcc.isEmpty ? nil : String(reasoningAcc.prefix(6000)))))

            if let streamError {
                messages[messages.count - 1].text = full.isEmpty
                    ? "（LLM 调用失败：\(streamError)）"
                    : full + "\n\n（流中断：\(streamError)）"
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
                return
            }

            // 无工具调用 → turn 正常结束（纯思考步骤保留思考区展示）
            guard !toolCalls.isEmpty else {
                if full.isEmpty && reasoningAcc.isEmpty { messages.removeLast() }   // 真空响应不占行
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
                return
            }

            // 历史追加 assistant(tool_calls)
            llmHistory.append(.init(role: .assistant, content: full.isEmpty ? nil : full, toolCalls: toolCalls))
            if full.isEmpty { messages.removeLast() }    // 纯工具调用步骤不占消息行（思考随下步回收）

            // 执行工具（M3 只暴露 run_command）
            for call in toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any]
                let cmd = args?["command"] as? String ?? ""

                log?.append(SessionEvent.toolCall, .init(turn: turnNo, step: stepNo,
                                                         id: call.id, command: cmd.isEmpty ? call.name : cmd))
                messages.append(ChatMessage.tool(cmd.isEmpty ? call.name : cmd))
                messages[messages.count - 1].running = true

                let (code, ms, out) = await execTool(cmd.isEmpty ? "echo （未知工具调用）" : cmd)

                messages[messages.count - 1].output = out
                messages[messages.count - 1].exitCode = Int(code)
                messages[messages.count - 1].durationMs = ms
                messages[messages.count - 1].running = false

                log?.append(SessionEvent.toolResult, .init(turn: turnNo, step: stepNo,
                                                           id: call.id,
                                                           exitCode: Int(code), durationMs: ms,
                                                           output: String(out.prefix(6000))))
                // OpenAI 协议：每个工具调用一条 tool 结果消息
                llmHistory.append(.init(role: .tool, content: out.isEmpty ? "（无输出）" : out,
                                        toolCallId: call.id))
            }

            log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
            // 工具结果已入历史 → 下一步（模型消化结果）
        }

        reason = "max-steps"
        messages.append(.agent("（步数护栏触发：\(maxSteps) 步未收敛，turn 终止。）"))
        log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
    }

    // MARK: auto-compact（简化版：字符估算 + 单次摘要）

    private func maybeCompact() async {
        let est = llmHistory.reduce(0) { $0 + ($1.content?.count ?? 0) + 8 } / 2
        guard est > compactThresholdTokens else { return }

        var sumMessages = llmHistory
        sumMessages.append(.init(role: .user, content: "请把以上对话压缩成一份交接摘要：保留用户的目标与偏好、已完成的关键操作与结果、未完成事项。直接输出摘要正文，不要客套。"))
        var sum = ""
        let adapter = makeAdapter()
        do {
            let stream = adapter.stream(messages: sumMessages, tools: [])
            for try await ev in stream {
                if case .textDelta(let d) = ev { sum += d }
                if case .done(let t, _, _, _, _) = ev { sum = t }
            }
        } catch {
            return   // 压缩失败不阻塞对话
        }
        llmHistory = [
            .init(role: .system, content: Self.systemPrompt),
            .init(role: .user, content: "此前对话的交接摘要：\n\(sum)"),
            .init(role: .assistant, content: "收到，我已了解此前上下文，继续。"),
        ]
        log?.append("compact", .init(text: sum))
        messages.append(.agent("〔上下文已自动压缩：约 \(est) tokens → 摘要 \(sum.count) 字，对话继续〕"))
    }

    // MARK: 工具与适配器

    static let runCommandTool = LLMToolDef(
        name: "run_command",
        description: "在用户的 Alpine Linux 沙箱里执行一条 shell 命令，返回 stdout/stderr（30 秒超时）。",
        parameters: [
            "type": "object",
            "properties": [
                "command": ["type": "string", "description": "要执行的 shell 命令"]
            ],
            "required": ["command"],
        ])

    private func makeAdapter() -> LLMAdapter {
        let st = SettingsStore.shared
        return st.hasKey ? DeepSeekAdapter(settings: st) : FakeLLM()
    }

    private func brainName() -> String {
        let st = SettingsStore.shared
        return st.hasKey ? "DeepSeek · \(st.model)" : "FakeBrain（未配置 API Key）"
    }

    /// 工具执行：走 ISHShellExecutor 同步接口（阻塞 detached 线程，不占主线程）
    private func execTool(_ command: String) async -> (Int32, Int, String) {
        let timeout = toolTimeout
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ISHShellExecutor.executeCommandSync(command,
                                                            timeout: timeout,
                                                            lineCallback: nil)
                let out = [r.output, r.errorOutput]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                cont.resume(returning: (r.exitCode, Int(r.duration * 1000), out))
            }
        }
    }
}
