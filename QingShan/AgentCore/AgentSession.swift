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

    enum Role { case user, agent, tool }

    static func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    static func agent(_ t: String) -> ChatMessage { ChatMessage(role: .agent, text: t) }
    static func tool(_ c: String) -> ChatMessage { ChatMessage(role: .tool, text: c) }
}

// MARK: - AgentSession：turn/step 循环 + 事件溯源 + resume
//
// 循环语义对齐 dsh core/agent-loop（见「dsh语义对照笔记.md」）：
//   turn/start → [step/start → (user/message | assistant/message | tool/call+tool/result) → step/end]* → turn/end(reason)
// 差异（本地扩展，均已在笔记登记）：FakeLLM 文本协议替代原生 tool-call；maxSteps 护栏。

@MainActor
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var sessionTitle = ""

    private(set) var sessionID = ""
    private var log: SessionLog?
    private let llm: LLMAdapter
    private let toolTimeout: TimeInterval = 30
    private let maxSteps = 5            // 本地扩展护栏（dsh 用 max-tokens + abort 治理）
    private var turnNo = 0

    init(llm: LLMAdapter = FakeLLM()) {
        self.llm = llm
    }

    /// 新会话
    func startNew(title: String) {
        sessionID = "s" + String(Int(Date().timeIntervalSince1970 * 1000))
        log = SessionLog(sessionID: sessionID)
        turnNo = 0
        sessionTitle = title
        messages.removeAll()
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 新会话 \(sessionID)（大脑：\(llm.name)）—")
    }

    /// 恢复最近会话：重放 JSONL 事件重建消息流。返回是否恢复出了内容。
    @discardableResult
    func resumeLatest() -> Bool {
        guard let id = SessionLog.latestSessionID() else { return false }
        let events = SessionLog.replay(sessionID: id)
        // 只认带 session header 的新格式；旧格式文件重放为空则放弃恢复
        guard events.contains(where: { $0.type == SessionEvent.sessionHeaderType }) else { return false }

        sessionID = id
        log = SessionLog(sessionID: id)   // 后续事件继续追加
        messages.removeAll()
        turnNo = events.filter { $0.type == SessionEvent.turnEnd }.count

        for ev in events {
            switch ev.type {
            case SessionEvent.sessionHeaderType:
                if let t = ev.data.id { sessionTitle = t }
            case SessionEvent.userMessage:
                if let t = ev.data.text { messages.append(.user(t)) }
            case SessionEvent.assistantMessage:
                if let t = ev.data.text { messages.append(.agent(t)) }
            case SessionEvent.toolCall:
                if let c = ev.data.command { messages.append(.tool(c)) }
            case SessionEvent.toolResult:
                if messages.last?.role == .tool {
                    messages[messages.count - 1].output = ev.data.output
                    messages[messages.count - 1].exitCode = ev.data.exitCode.flatMap(Int.init)
                    messages[messages.count - 1].durationMs = ev.data.durationMs
                }
            default:
                break   // turn/start、step/*、turn/end 只用于溯源，不进消息流
            }
        }
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 已恢复会话 \(id)（\(messages.count) 条消息）—")
        return !messages.isEmpty
    }

    /// 用户发消息 → 启动一个 turn
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking else { return }
        messages.append(.user(t))
        log?.append(SessionEvent.userMessage, .init(text: t))
        if sessionTitle.isEmpty || sessionTitle == "新会话" {
            sessionTitle = String(t.prefix(16))
        }
        Task { await runTurn(userText: t) }
    }

    /// turn/step 循环（dsh 对齐）：
    /// turn/start → [step/start → 一步 → step/end]* → turn/end(reason)
    private func runTurn(userText: String) async {
        isThinking = true
        defer { isThinking = false }

        turnNo += 1
        log?.append(SessionEvent.turnStart, .init(turn: turnNo))

        var reason = "completed"
        var toolOutput: String?
        var stepNo = 0

        while stepNo < maxSteps {
            stepNo += 1
            log?.append(SessionEvent.stepStart, .init(turn: turnNo, step: stepNo))

            let resp = llm.respond(turn: userText, toolOutput: toolOutput)

            switch resp {
            case .say(let text):
                // assistant/message（M3 流式时前置 assistant/chunk 事件）
                log?.append(SessionEvent.assistantMessage, .init(turn: turnNo, step: stepNo, text: text))
                messages.append(.agent(text))
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))

            case .callTool(let command):
                log?.append(SessionEvent.toolCall, .init(turn: turnNo, step: stepNo, command: command))
                messages.append(ChatMessage.tool(command))
                messages[messages.count - 1].running = true

                let (code, ms, out) = await execTool(command)

                messages[messages.count - 1].output = out
                messages[messages.count - 1].exitCode = Int(code)
                messages[messages.count - 1].durationMs = ms
                messages[messages.count - 1].running = false
                log?.append(SessionEvent.toolResult, .init(turn: turnNo, step: stepNo,
                                                           exitCode: Int(code), durationMs: ms,
                                                           output: String(out.prefix(4000))))
                log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo))
                toolOutput = out.isEmpty ? "（命令无输出，退出码 \(code)）" : out
                continue
            }
            return
        }

        reason = "max-steps"   // 本地扩展 reason（dsh 原生集合外）
        messages.append(.agent("（步数护栏触发：\(maxSteps) 步未收敛，turn 终止。）"))
        log?.append(SessionEvent.turnEnd, .init(turn: turnNo, reason: reason))
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
