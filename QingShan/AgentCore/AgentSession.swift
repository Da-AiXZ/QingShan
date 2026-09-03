import Foundation
import SwiftUI

// MARK: - 会话消息模型（UI 层，由事件重放或实时追加生成）

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    var text: String          // user/agent：正文；tool：命令
    var output: String?       // tool 输出
    var exitCode: Int?
    var durationMs: Int?
    var running: Bool = false

    enum Role { case user, agent, tool }

    static func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, text: t) }
    static func agent(_ t: String) -> ChatMessage { ChatMessage(role: .agent, text: t) }
    static func tool(_ c: String) -> ChatMessage { ChatMessage(role: .tool, text: c) }
}

// MARK: - AgentSession：turn/step 循环 + 事件溯源 + resume

@MainActor
final class AgentSession: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isThinking = false
    @Published var sessionTitle = ""

    private(set) var sessionID = ""
    private var log: SessionLog?
    private let llm: LLMAdapter
    private let toolTimeout: TimeInterval = 30

    init(llm: LLMAdapter = FakeLLM()) {
        self.llm = llm
    }

    /// 新会话
    func startNew(title: String) {
        sessionID = "s" + String(Int(Date().timeIntervalSince1970 * 1000))
        log = SessionLog(sessionID: sessionID)
        log?.append(.sessionStart(title: title))
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
        guard !events.isEmpty else { return false }

        sessionID = id
        log = SessionLog(sessionID: id)   // 后续事件继续追加到同一文件
        messages.removeAll()

        for ev in events {
            switch ev.kind {
            case .sessionStart(let title):
                sessionTitle = title
            case .userMessage(let t):
                messages.append(.user(t))
            case .agentMessage(let t):
                messages.append(.agent(t))
            case .toolStart(let c):
                var m = ChatMessage.tool(c)
                m.running = false        // 重放时不还原执行中状态（已结束）
                messages.append(m)
            case .toolResult(_, let code, let ms, let out):
                if messages.last?.role == .tool {
                    messages[messages.count - 1].output = out
                    messages[messages.count - 1].exitCode = Int(code)
                    messages[messages.count - 1].durationMs = ms
                }
            case .note(let t):
                messages.append(.agent(t))
            }
        }
        ConsoleHub.clear()
        ConsoleHub.appendLine("— 已恢复会话 \(id)（\(messages.count) 条消息）—")
        return true
    }

    /// 用户发消息 → 启动一个 turn
    func send(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !isThinking else { return }
        messages.append(.user(t))
        log?.append(.userMessage(text: t))
        if sessionTitle.isEmpty || sessionTitle == "新会话" {
            sessionTitle = String(t.prefix(16))
        }
        Task { await runTurn(userText: t) }
    }

    /// turn/step 循环：LLM 每步要么回文本（结束），要么调工具（结果回喂继续）
    private func runTurn(userText: String) async {
        isThinking = true
        defer { isThinking = false }

        var toolOutput: String?
        var steps = 0
        let maxSteps = 5   // M2 干跑护栏：假大脑最多 5 步

        while steps < maxSteps {
            steps += 1
            let resp = llm.respond(turn: userText, toolOutput: toolOutput)

            switch resp {
            case .say(let text):
                messages.append(.agent(text))
                log?.append(.agentMessage(text: text))
                return

            case .callTool(let command):
                messages.append(ChatMessage.tool(command))
                messages[messages.count - 1].running = true
                log?.append(.toolStart(command: command))

                let (code, ms, out) = await execTool(command)

                if !messages.isEmpty {
                    messages[messages.count - 1].output = out
                    messages[messages.count - 1].exitCode = Int(code)
                    messages[messages.count - 1].durationMs = ms
                    messages[messages.count - 1].running = false
                }
                log?.append(.toolResult(command: command,
                                        exitCode: Int(code),
                                        durationMs: ms,
                                        output: String(out.prefix(4000))))
                toolOutput = out.isEmpty ? "（命令无输出，退出码 \(code)）" : out
            }
        }
        messages.append(.agent("（步数护栏触发：\(maxSteps) 步未收敛，turn 终止。）"))
        log?.append(.agentMessage(text: "步数护栏触发"))
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
