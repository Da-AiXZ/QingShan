import Foundation
import SwiftUI

// MARK: - 会话消息模型（UI 层，由事件重放或实时追加生成）

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String          // user/agent：正文；tool：命令或工具名
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var running: Bool = false
    var reasoning: String?
    var denied: Bool = false  // 工具被用户拒绝

    enum Role { case user, agent, tool }

    static func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    static func agent(_ t: String) -> ChatMessage { ChatMessage(role: .agent, text: t) }
    static func tool(_ c: String) -> ChatMessage { ChatMessage(role: .tool, text: c) }
}

// MARK: - 工具注册表（M4：run_command / read_file / write_file）

enum ToolRegistry {
    static let runCommand = LLMToolDef(
        name: "run_command",
        description: "在用户的 Alpine Linux 沙箱里执行一条 shell 命令，返回 stdout/stderr（30 秒超时）。读文件用 cat，列目录用 ls。",
        parameters: [
            "type": "object",
            "properties": ["command": ["type": "string", "description": "要执行的 shell 命令"]],
            "required": ["command"],
        ])

    static let readFile = LLMToolDef(
        name: "read_file",
        description: "读取沙箱中一个文本文件的全部内容。",
        parameters: [
            "type": "object",
            "properties": ["path": ["type": "string", "description": "文件绝对路径"]],
            "required": ["path"],
        ])

    static let writeFile = LLMToolDef(
        name: "write_file",
        description: "把文本内容写入沙箱中的一个文件（整文件覆盖）。写入属于写操作，按审批策略可能需要用户确认。",
        parameters: [
            "type": "object",
            "properties": [
                "path": ["type": "string", "description": "文件绝对路径"],
                "content": ["type": "string", "description": "要写入的完整内容"],
            ],
            "required": ["path", "content"],
        ])

    static var all: [LLMToolDef] { [runCommand, readFile, writeFile] }
}

// MARK: - AgentSession：turn/step 循环（流式+审批） + 事件溯源 + resume + auto-compact
//
// 循环语义对齐 dsh core/agent-loop（见「dsh语义对照笔记.md」）。

@MainActor
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var sessionTitle = ""
    @Published var policy: ApprovalPolicy {
        didSet { UserDefaults.standard.set(policy.rawValue, forKey: "approval.policy") }
    }
    @Published var pendingApproval: ApprovalRequest?

    private(set) var sessionID = ""
    private var log: SessionLog?
    private let toolTimeout: TimeInterval = 30
    private let maxSteps = 12
    private let compactThresholdTokens = 8_000
    private var turnNo = 0
    private var allowedTools: Set<String> = []   // 会话级"始终允许"记忆
    private var approvalCont: CheckedContinuation<ApprovalDecision, Never>?

    /// LLM 历史（与 UI messages 平行；OpenAI 协议形态）
    var llmHistory: [LLMMessage] = []

    static let systemPrompt = """
        你是青山（QingShan），运行在用户 iPad 上的本地 AI Agent。
        环境：你的命令在设备内置的 Alpine Linux (aarch64) 沙箱中以 root 身份执行，输出会原样返回给你。
        工具：run_command —— 执行一条 shell 命令。需要了解系统状态时主动使用它，不要凭空猜测。
        要求：回复用简体中文；命令输出会原样返回给你；简洁直接，不编造输出。
        """

    init() {
        policy = ApprovalPolicy(rawValue: UserDefaults.standard.string(forKey: "approval.policy") ?? "") ?? .riskyOnly
    }

    // MARK: 会话生命周期

    func startNew(title: String) {
        sessionID = "s" + String(Int(Date().timeIntervalSince1970 * 1000))
        log = SessionLog(sessionID: sessionID)
        turnNo = 0
        sessionTitle = title
        messages.removeAll()
        allowedTools.removeAll()
        llmHistory = [.init(role: .system, content: Self.systemPrompt)]
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 新会话 \(sessionID)（大脑：\(brainName())）—")
    }

    /// 加载指定会话（重放事件重建消息流 + LLM 历史）
    @discardableResult
    func load(sessionID id: String) -> Bool {
        let events = SessionLog.replay(sessionID: id)
        guard events.contains(where: { $0.type == SessionEvent.sessionHeaderType }) else { return false }

        sessionID = id
        log = SessionLog(sessionID: id)
        messages.removeAll()
        llmHistory = [.init(role: .system, content: Self.systemPrompt)]
        turnNo = 0
        allowedTools.removeAll()

        var lastToolCallId: String?
        for ev in events {
            switch ev.type {
            case SessionEvent.userMessage:
                if let t = ev.data.text {
                    messages.append(.user(t))
                    llmHistory.append(.init(role: .user, content: t))
                }
            case SessionEvent.assistantMessage:
                if let json = ev.data.toolCallsJSON,
                   let data = json.data(using: .utf8),
                   let calls = try? JSONDecoder().decode([LLMToolCall].self, from: data) {
                    llmHistory.append(.init(role: .assistant, content: ev.data.text, toolCalls: calls))
                    if let t = ev.data.text, !t.isEmpty {
                        var m = ChatMessage.agent(t)
                        m.reasoning = ev.data.reasoning
                        messages.append(m)
                    }
                } else {
                    var m = ChatMessage.agent(ev.data.text ?? "")
                    m.reasoning = ev.data.reasoning
                    messages.append(m)
                    llmHistory.append(.init(role: .assistant, content: ev.data.text ?? ""))
                }
            case SessionEvent.toolCall:
                lastToolCallId = ev.data.id
                messages.append(.tool(ev.data.command ?? ev.data.name ?? "?"))
            case SessionEvent.toolResult:
                if messages.last?.role == .tool {
                    messages[messages.count - 1].output = ev.data.output
                    messages[messages.count - 1].exitCode = ev.data.exitCode.flatMap(Int.init)
                    messages[messages.count - 1].durationMs = ev.data.durationMs
                }
                llmHistory.append(.init(role: .tool, content: ev.data.output,
                                        toolCallId: lastToolCallId))
                lastToolCallId = nil
            case "compact":
                if let sum = ev.data.text {
                    llmHistory = compactedHistory(summary: sum)
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

    /// 恢复最近的会话
    @discardableResult
    func resumeLatest() -> Bool {
        guard let id = SessionLog.latestSessionID() else { return false }
        return load(sessionID: id)
    }

    // MARK: 用户发消息

    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking, pendingApproval == nil else { return }
        messages.append(.user(t))
        llmHistory.append(.init(role: .user, content: t))
        log?.append(SessionEvent.userMessage, .init(text: t))
        Task { await runTurn(userText: t) }
    }

    // MARK: turn/step 循环（流式 + 审批 + 工具）

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

            messages.append(.agent(""))
            var full = ""
            var reasoningAcc = ""
            var toolCalls: [LLMToolCall] = []
            var streamError: String?

            // LLM 调用（限流/服务器错误自动退避重试，对齐 dsh llm-retry：最多 3 次）
            var attempt = 0
            retryLoop: while true {
                attempt += 1
                var hadDelta = false
                do {
                    let adapter = makeAdapter()
                    let stream = adapter.stream(messages: llmHistory, tools: ToolRegistry.all)
                    for try await ev in stream {
                        switch ev {
                        case .reasoningDelta(let d):
                            reasoningAcc += d
                            messages[messages.count - 1].reasoning = reasoningAcc
                        case .textDelta(let d):
                            hadDelta = true
                            full += d
                            messages[messages.count - 1].text = full
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
                    let desc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                    let retryable = attempt < 3 && full.isEmpty && !hadDelta
                        && (desc.contains("429") || desc.contains("500") || desc.contains("502")
                            || desc.contains("503") || desc.contains("rate_limit") || desc.contains("Rate"))
                    if retryable {
                        let secs = 2 * attempt * attempt
                        ConsoleHub.appendLine("⚠ LLM 调用受限，\(secs)s 后自动重试（第 \(attempt)/3 次）…")
                        ToastCenter.shared.show("模型调用受限，\(secs)s 后自动重试（\(attempt)/3）", kind: .warn)
                        try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                        continue retryLoop
                    }
                    streamError = desc
                    reason = "error"
                }
                break
            }

            let callsJSON = (try? JSONEncoder().encode(toolCalls)).flatMap { String(data: $0, encoding: .utf8) }
            messages[messages.count - 1].reasoning = reasoningAcc.isEmpty ? nil : reasoningAcc
            log?.append(SessionEvent.assistantMessage, .init(turn: turnNo, step: stepNo,
                                                             text: full,
                                                             toolCallsJSON: toolCalls.isEmpty ? nil : callsJSON,
                                                             reasoning: reasoningAcc.isEmpty ? nil : String(reasoningAcc.prefix(6000))))

            if let streamError {
                messages[messages.count - 1].text = full.isEmpty
                    ? "（LLM 调用失败：\(streamError)）"
                    : full + "\n\n（流中断：\(streamError)）"
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
                ToastCenter.shared.show("模型调用失败", kind: .error)
                return
            }

            guard !toolCalls.isEmpty else {
                if full.isEmpty && reasoningAcc.isEmpty { messages.removeLast() }
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
                return
            }

            llmHistory.append(.init(role: .assistant, content: full.isEmpty ? nil : full, toolCalls: toolCalls))
            if full.isEmpty { messages.removeLast() }

            // 执行本轮全部工具调用（含审批）
            for call in toolCalls {
                let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]

                guard ToolRegistry.def(named: call.name) != nil else {
                    let out = "未知工具：\(call.name)"
                    messages.append(.agent(out))
                    log?.append(.agentMessage(text: out))
                    llmHistory.append(.init(role: .tool, content: out, toolCallId: call.id))
                    continue
                }

                let command = toolCommand(call: call, args: args)
                let needsApproval = !allowedTools.contains(call.name)
                    && ApprovalService.needsApproval(command: command, policy: policy)

                if needsApproval {
                    let req = ApprovalRequest(toolName: call.name, command: command,
                                              reason: ApprovalService.reason(command: command, policy: policy))
                    pendingApproval = req
                    ToastCenter.shared.show("Agent 请求批准：\(command.prefix(40))", kind: .warn, duration: 5)
                    let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
                        self.approvalCont = cont
                    }
                    pendingApproval = nil
                    log?.append("approval/decision", .init(text: decision.rawValue, command: command))

                    switch decision {
                    case .deny:
                        messages.append(.tool(command))
                        messages[messages.count - 1].output = "（用户拒绝执行）"
                        messages[messages.count - 1].denied = true
                        llmHistory.append(.init(role: .tool, content: "用户拒绝执行该命令。请改用其他方案或向用户说明。", toolCallId: call.id))
                        log?.append(SessionEvent.toolResult, .init(turn: turnNo, step: stepNo,
                                                                   id: call.id, exitCode: -1,
                                                                   output: "（用户拒绝执行）"))
                        continue
                    case .allowOnce:
                        break
                    case .allowAlways:
                        allowedTools.insert(call.name)
                    }
                }

                log?.append(SessionEvent.toolCall, .init(turn: turnNo, step: stepNo,
                                                         id: call.id, command: command))
                messages.append(ChatMessage.tool(command))
                messages[messages.count - 1].running = true

                let (code, ms, out) = await execToolCall(name: call.name, args: args)

                messages[messages.count - 1].output = out
                messages[messages.count - 1].exitCode = Int(code)
                messages[messages.count - 1].durationMs = ms
                messages[messages.count - 1].running = false

                log?.append(SessionEvent.toolResult, .init(turn: turnNo, step: stepNo,
                                                           id: call.id, exitCode: Int(code), durationMs: ms,
                                                           output: String(out.prefix(6000))))
                llmHistory.append(.init(role: .tool, content: out.isEmpty ? "（无输出）" : out, toolCallId: call.id))
            }

            log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
            // 工具结果已入历史 → 下一步（模型消化结果）
        }

        reason = "max-steps"
        messages.append(.agent("（步数护栏触发：\(maxSteps) 步未收敛，turn 终止。）"))
        log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
    }

    /// 工具调用的展示命令（读/写文件合成可读命令形态）
    private func toolCommand(call: LLMToolCall, args: [String: Any]) -> String {
        switch call.name {
        case "read_file":
            let p = args["path"] as? String ?? "?"
            return "cat \(p)"
        case "write_file":
            let p = args["path"] as? String ?? "?"
            let n = (args["content"] as? String)?.count ?? 0
            return "write \(p)（\(n) 字符）"
        default:
            return args["command"] as? String ?? call.name
        }
    }

    /// 工具执行分发
    private func execToolCall(name: String, args: [String: Any]) async -> (Int32, Int, String) {
        let command: String
        switch name {
        case "read_file":
            let p = (args["path"] as? String ?? "").replacingOccurrences(of: "'", with: "")
            command = "cat '\(p)' 2>&1"
        case "write_file":
            let p = (args["path"] as? String ?? "/tmp/qingshan-out").replacingOccurrences(of: "'", with: "")
            let content = args["content"] as? String ?? ""
            command = "mkdir -p \"$(dirname '\(p)')\" && cat > '\(p)' <<'QSEOF'\n\(content)\nQSEOF\necho written: \(content.count) chars"
        default:
            command = args["command"] as? String ?? "true"
        }
        return await execShell(command)
    }

    private func execShell(_ command: String) async -> (Int32, Int, String) {
        let timeout = toolTimeout
        return await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let r = ISHShellExecutor.executeCommandSync(command, timeout: timeout, lineCallback: nil)
                let out = [r.output, r.errorOutput].filter { !$0.isEmpty }.joined(separator: "\n")
                cont.resume(returning: (r.exitCode, Int(r.duration * 1000), out))
            }
        }
    }

    // MARK: 审批

    func resolveApproval(_ decision: ApprovalDecision) {
        approvalCont?.resume(returning: decision)
        approvalCont = nil
    }

    // MARK: auto-compact

    private func maybeCompact() async {
        let est = llmHistory.reduce(0) { $0 + ($1.content?.count ?? 0) + 8 } / 2
        guard est > compactThresholdTokens else { return }

        var sumMessages = llmHistory
        sumMessages.append(.init(role: .user, content: "请把以上对话压缩成一份交接摘要：保留用户的目标与偏好、已完成的关键操作与结果、未完成事项。直接输出摘要正文，不要客套。"))
        var sum = ""
        do {
            let stream = makeAdapter().stream(messages: sumMessages, tools: [])
            for try await ev in stream {
                if case .textDelta(let d) = ev { sum += d }
                if case .done(let t, _, _, _, _) = ev { sum = t }
            }
        } catch {
            return
        }
        llmHistory = compactedHistory(summary: sum)
        log?.append("compact", .init(text: sum))
        messages.append(.agent("〔上下文已自动压缩：约 \(est) tokens → 摘要 \(sum.count) 字，对话继续〕"))
        ToastCenter.shared.show("上下文已自动压缩，对话继续", kind: .success)
    }

    private func compactedHistory(summary: String) -> [LLMMessage] {
        [
            .init(role: .system, content: Self.systemPrompt),
            .init(role: .user, content: "此前对话的交接摘要：\n\(summary)"),
            .init(role: .assistant, content: "收到，我已了解此前上下文，继续。"),
        ]
    }

    // MARK: 适配器

    private func makeAdapter() -> LLMAdapter {
        let st = SettingsStore.shared
        return st.hasKey ? DeepSeekAdapter(settings: st) : FakeLLM()
    }

    func brainName() -> String {
        let st = SettingsStore.shared
        return st.hasKey ? "DeepSeek · \(st.model)" : "FakeBrain（未配置 API Key）"
    }
}
