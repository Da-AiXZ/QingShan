import Foundation

// MARK: - DeepSeek 流式适配器（OpenAI 兼容 chat/completions + 原生 function calling）
//
// 语义对齐 dsh packages/llm/llm-deepseek（translate.ts + sse.ts，见「dsh语义对照笔记.md」第三节）：
//   - SSE 逐事件解析，[DONE] 哨兵结束；EOF 未收到 [DONE] = STREAM_CLOSED 错误
//   - delta 三类增量：reasoning_content（思考）/ content（正文）/ tool_calls（按 index 拼接）
//   - finish_reason：stop / tool_calls / length
//   - usage 可挂在 finish chunk 或独立尾 chunk，取最新

struct DeepSeekError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class DeepSeekAdapter: LLMAdapter {
    let name: String

    private let baseURL: String
    private let apiKey: String
    private let model: String

    @MainActor init(settings: SettingsStore) {
        self.name = "DeepSeek · \(settings.model)"
        self.baseURL = settings.baseURL.trimmingCharacters(in: .whitespaces)
        self.apiKey = settings.apiKey.trimmingCharacters(in: .whitespaces)
        self.model = settings.model.trimmingCharacters(in: .whitespaces)
    }

    func stream(messages: [LLMMessage], tools: [LLMToolDef]) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await streamOnce(messages: messages, tools: tools) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(messages: [LLMMessage], tools: [LLMToolDef],
                            yield: @escaping (LLMStreamEvent) -> Void) async throws {
        let base = baseURL.trimmingCharacters(in: .whitespaces)
        let urlStr = base.hasSuffix("/") ? base + "chat/completions" : base + "/chat/completions"
        guard let url = URL(string: urlStr) else {
            throw DeepSeekError(message: "baseURL 无效：\(base)")
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120

        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { m -> [String: Any] in
                var o: [String: Any] = ["role": m.role.rawValue]
                if let c = m.content { o["content"] = c }
                if let tc = m.toolCalls {
                    o["tool_calls"] = tc.map { call in
                        [
                            "id": call.id,
                            "type": "function",
                            "function": ["name": call.name, "arguments": call.arguments],
                        ]
                    }
                }
                if let id = m.toolCallId { o["tool_call_id"] = id }
                return o
            },
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if !tools.isEmpty {
            body["tools"] = tools.map { $0.wireJSON }
        }
        // 推理力度档位真实生效：medium（默认）不发送，非默认档传 reasoning_effort
        let tier = EffortTier.current
        if tier != .medium {
            body["reasoning_effort"] = tier == .xhigh ? "high" : tier.rawValue
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var bodyData = Data()
            for try await b in bytes { bodyData.append(b); if bodyData.count > 4096 { break } }
            throw DeepSeekError(message: "HTTP \(http.statusCode)：\(String(data: bodyData.prefix(600), encoding: .utf8) ?? "")")
        }

        // ---- SSE 解析（行级：data: 前缀；空行分帧简化；[DONE] 哨兵） ----
        var pending = Data()
        var fullText = ""
        var finishReason = ""
        var promptTokens = 0
        var completionTokens = 0
        // tool_calls 按 index 拼接（dsh translate.ts 的 toolBlocks Map 语义）
        var toolOrder: [Int] = []
        var toolBlocks: [Int: (id: String, name: String, arguments: String)] = [:]
        var sawDone = false

        for try await byteChunk in bytes.lines {
            let line = byteChunk
            if line.hasPrefix("data:") {
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload.isEmpty { continue }
                if payload == "[DONE]" { sawDone = true; break }
                guard let chunkData = payload.data(using: .utf8),
                      let chunk = try? JSONSerialization.jsonObject(with: chunkData) as? [String: Any] else {
                    throw DeepSeekError(message: "SSE 载荷解析失败：\(payload.prefix(120))")
                }

                if let usage = chunk["usage"] as? [String: Any] {
                    promptTokens = usage["prompt_tokens"] as? Int ?? promptTokens
                    completionTokens = usage["completion_tokens"] as? Int ?? completionTokens
                }

                guard let choices = chunk["choices"] as? [[String: Any]] else { continue }
                for choice in choices {
                    let delta = choice["delta"] as? [String: Any] ?? [:]

                    // reasoning_content（DeepSeek 思考模式）
                    if let r = delta["reasoning_content"] as? String, !r.isEmpty {
                        yield(.reasoningDelta(r))
                    }

                    // 正文增量
                    if let c = delta["content"] as? String, !c.isEmpty {
                        fullText += c
                        yield(.textDelta(c))
                    }

                    // 工具调用增量（按 index 拼接 id/name/arguments）
                    if let calls = delta["tool_calls"] as? [[String: Any]] {
                        for call in calls {
                            let idx = call["index"] as? Int ?? 0
                            if toolBlocks[idx] == nil {
                                toolBlocks[idx] = ("", "", "")
                                toolOrder.append(idx)
                            }
                            var blk = toolBlocks[idx]!
                            if let id = call["id"] as? String, !id.isEmpty, blk.id.isEmpty { blk.id = id }
                            if let fn = call["function"] as? [String: Any] {
                                if let n = fn["name"] as? String, !n.isEmpty, blk.name.isEmpty { blk.name = n }
                                if let a = fn["arguments"] as? String { blk.arguments += a }
                            }
                            toolBlocks[idx] = blk
                        }
                    }

                    if let fr = choice["finish_reason"] as? String, !fr.isEmpty {
                        finishReason = fr
                    }
                }
            }
            pending = Data()
        }
        _ = pending

        guard sawDone else {
            throw DeepSeekError(message: "SSE 流在 [DONE] 之前结束（响应被截断，不可信）")
        }

        let orderedCalls = toolOrder.map { idx in
            LLMToolCall(id: toolBlocks[idx]!.id.isEmpty ? "call_\(idx)" : toolBlocks[idx]!.id,
                        name: toolBlocks[idx]!.name,
                        arguments: toolBlocks[idx]!.arguments.isEmpty ? "{}" : toolBlocks[idx]!.arguments)
        }
        yield(.done(text: fullText, toolCalls: orderedCalls,
                    finishReason: finishReason, promptTokens: promptTokens, completionTokens: completionTokens))
    }
}
