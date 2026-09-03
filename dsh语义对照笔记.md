# dsh 语义对照笔记（QingShan · M3-M7 动工前必读）

> 来源：dsh 0.1.2-alpha.5（本地 `repos/deepseek-harness/deepseek-harness-master`，2026-09-04 快照）。
> 规矩（用户拍板）：**每个新模块动工前先读本笔记对应章节 + dsh 源码再写**，不凭印象。
> 本笔记 = 校准轮产出，随里程碑增量更新。

## 一、Agent 循环（对照 `packages/core/agent-loop/src/agent.ts`）

### dsh 真实结构（ReactLoopAgent）

```
kick(): while (await turn()) {}            ← driver：队列还有 pending 就继续开 turn
turn():                                     ← 一轮 = 一次用户触发的完整活动
  session.append('turn/start', {turn})
  loop: preStep(claim inbox 消息) → step(start)
  finally: session.append('turn/end', {turn, reason})   ← reason 必填
step():                                     ← 一步 = 一次 LLM 调用及其工具消化
  while(true):
    buildRequest（含 request/header、request/context 事件）
    LLM 流式：每个 chunk → session.append('assistant/chunk', {turn,step,chunk})
    组装完成 → session.append('assistant/message', {turn,step,message})
    无 tool-call → return completed
    有 tool-call → executeToolCalls → 结果作为 context 消息 splice 进 next-step inbox → return null（继续下一步）
```

### 必须遵守的语义

1. **事件行结构** = `{type: '<name>', data: {...}}`（type + data 两段）；首行是 session header
   （`{type:'session', version, id, createdAt, cwd?, delegationDepth}`）。
2. **事件名是 kebab 斜杠风格**：`turn/start`、`step/start`、`step/end`、`user/message`、
   `assistant/chunk`、`assistant/message`、`turn/end`、`request/header`、`request/context`、
   `agent/inbox/spliced`、`tool/call`。
3. **turn/end 必带 reason**：`completed | max-tokens | aborted | blocked | error`。
   max-tokens 是粘性的：一旦某 step 撞上限，后续正常完成的 step 不得把 turn 结果降级。
4. **中断语义**：流式中断时，已收到的块也要落一条 `assistant/message (interrupted:true)`，
   replay 才有效（否则杀进程丢半截回复）。
5. **工具调用是 LLM 原生 tool-call block**（message.content 里 filter type==='tool-call'），
   **不是文本协议**。M3 接 DeepSeek 必须用原生 function calling。
6. **工具结果回喂**：`createToolResultMessage` 包成 context 消息 splice 进 next-step inbox；
   abort 时给未启动的调用补合成错误结果（保证 replay 完整）。
7. **并发**：工具分 exclusive（barrier）与 parallel（有界滚动池）两种执行模式；
   结果与上下文按模型顺序提交。
8. dsh **没有 maxSteps 步数护栏**（用 max-tokens + abort 治理）。青山保留 maxSteps 作为
   M2 简化护栏，注释标注为本地扩展。

### 青山 M2 实现的偏差（本轮校准结论）

| # | dsh 语义 | M2 现状 | 处置 |
|---|---|---|---|
| 1 | 行结构 `{type,data}` + 首行 header | `{kind:{...}}` 无 header | ✅ 已改（SessionLog v2） |
| 2 | step/start / step/end 边界事件 | 无 step 概念 | ✅ 已加（每次 LLM 响应 = 一个 step） |
| 3 | turn/end 带 reason | 只记 turnBoundary | ✅ 已改（completed/error） |
| 4 | 工具事件名 tool/call | toolStart/toolResult 自创名 | ✅ 已改（tool/call + tool/result） |
| 5 | assistant/chunk 流式入日志 | 无（假大脑无流式） | ⏳ M3 接流式时加 |
| 6 | 原生 tool-call block | 文本协议（FakeLLM 自定义） | ⏳ M3 DeepSeek 原生 function calling |
| 7 | 中断时 interrupted message | 无 | ⏳ M3 流式中断时加 |
| 8 | max-tokens 粘性 | 无 | ⏳ M3+ |

## 二、会话持久化（对照 `session/session-persistence-jsonl/src/{format,storage}.ts`）

1. **文件布局**：每会话一个文件，SessionId 先 sanitize（防路径穿越）再作文件名；
   后缀 `.jsonl`（明文）或 `.jsonl.zstd`（压缩，M2 用明文即可）。
2. **首行 = header**：`{type:'session', version:0, id, createdAt, delegationDepth:0, ...}`。
3. **每行 = 一条事件**：`{type, data, seq}`（seq 单调递增；dsh 用它做 chunk→message 的
   sourceEventSeqs 引用）。青山加 seq 字段。
4. **截断修复（crash 半行）**：读取时最后一行 JSON 解析失败 → 丢弃该残行
   （写入按整行 append，crash 只可能留半行）。青山 replay 已按行 decode 失败跳过 ✓。
5. 旧格式（M2 首版：`{ts, kind:{...}}` 无 header）不再支持——旧测试会话文件删除即可。

## 三、LLM 适配（对照 `packages/llm`，M3 动工前精读）

- `respond(turn, toolOutput)` 的两段式假接口要升级为 **dsh 式**：
  `stream(request) → chunks → blocks（text/tool-call）`，工具调用以 block 形式返回。
- request/header 事件：provider/model/config 变化时落日志（reason: initial/change/series）。
- 错误结构化：LlmError（code + failure），request-error 瀑布决定 retry 与否。
- DeepSeek 对接：OpenAI 兼容 chat completions + 原生 function calling；
  baseURL 可配置（BYOK）。

## 四、其他模块备忘（后续里程碑动工前补充对应章节）

- compaction（M3 auto-compact 用）：读 `packages/compaction` 后补
- tools（M4）：读 `packages/core/tools` + `shell` 后补
- session-turn-outline / session-title（M4+ UI 用）
- subagent / skill / todo / jobs（M7）：读对应包后补
