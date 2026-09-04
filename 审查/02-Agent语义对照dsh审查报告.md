# 02 · Agent 语义对照 dsh 审查报告

- 审计对象：青山（SwiftUI + iSH ARM64）AgentCore 实现
- 基准：dsh（DeepSeek 官开源 harness，TypeScript monorepo）
- 审计方法：逐个通读 dsh 基准文件提炼语义 → 到青山源码中找实现证据（逐行核对，禁凭印象）
- 判定分级：✅ 语义完整 / ⚠️ 简化或部分 / ❌ 未实现
- 日期：2026-09-05

## 基准文件（dsh，均已通读）

| 文件 | 审计关注点 |
|---|---|
| packages/core/agent-loop/src/agent.ts | turn/step 循环、inbox 四通道、中断、max-tokens 粘性 |
| packages/core/agent-loop/src/tool-calls.ts | 工具调度、并行池、abort 合成结果 |
| packages/core/agent/src/inbox.ts | next-turn / next-step 双列表、claim/splice |
| packages/session/session-persistence-jsonl/src/format.ts | JSONL 行格式、header、torn-tail、seq 连续性 |
| packages/session/session-persistence-jsonl/src/storage.ts | 单写者、write-behind、torn-tail 修复 |
| packages/shell/tool-bash-persistent/src/index.ts | 标记包裹、scrollback、超时 reset、串行队列、shell 退出处理 |
| packages/shell/shell/src/types.ts、index.ts | 执行器 seam 语义 |
| packages/llm/llm-deepseek/src/adapter.ts、sse.ts、translate.ts | SSE、delta 翻译、finish_reason、usage |

## 被审文件（青山，均已通读）

AgentSession.swift · SessionLog.swift · PersistentShell.swift · DeepSeekAdapter.swift · LLMTypes.swift · FakeLLM.swift · ExecutionController.swift · Approval.swift

---

## 总统计

| 判定 | 条数 |
|---|---|
| ✅ 语义完整 | 12 |
| ⚠️ 简化或部分 | 14 |
| ❌ 未实现 | 8 |
| 合计 | 34 |

（含 1 个 ❌ 级实现缺陷：resume 后 seq 重置，见 3.5-①）

---

## 1. turn/step 生命周期

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| turn 依次追加 `turn/start` → N×(`step/start`…`step/end`) → `turn/end{reason}`；事件顺序是投影契约 | agent.ts:264,288,301,328 | 事件序列完全一致：turnStart→循环内 stepStart/stepEnd→turnEnd(reason) | AgentSession.swift:235,242,321-322,329-330,406,411 | ✅ | — |
| turn/end reason 枚举：completed / max-tokens / aborted{cause} / error{failure} / blocked | agent.ts:277,284,299,313,318-323 | 有 completed / max-tokens / error / max-steps（自有）；**无 aborted、无 blocked**，且 reason 是裸字符串非结构化对象 | AgentSession.swift:237,286,301,409,411；搜索 aborted/blocked 无结果 | ⚠️ | 单机无 dispose 语义，aborted 缺失影响小；但 reason 非结构化，未来 UI 按 reason 分类（如"已中断"徽标）需改 |
| max-tokens 粘性：任一 step 命中 length 后，后续 completed step 不得把 turn 结局降级 | agent.ts:294-299（两处注释明确 sticky） | 变量 `reason` 跨 step 不重置，`length` 赋值后保留——粘性**碰巧成立**；但 max-tokens 后若仍有 tool calls 会**继续执行**，dsh 则在无 next-step 输入时直接终止 turn | AgentSession.swift:237,286（无重置点）；对照 agent.ts:308 | ⚠️ | 语义偏差：dsh 视 length 为"输出被截断，本轮该停了"；青山继续跑工具可能基于截断的 JSON 参数产生坏调用 |
| step 循环边界：turnEnds 已定且 nextStep 无输入 → 跳出；有 steer 输入则续 step | agent.ts:304-309 | 循环条件只有 `stepNo < maxSteps` 与"无 toolCalls 则收尾"；无 step 边界输入概念 | AgentSession.swift:240,327-332 | ⚠️ | 归入 inbox 缺失（见 §2） |
| pre-step 瀑布（agent/pre-step 决策、context 注入、reject→blocked） | agent.ts:234-252 | 无对应扩展点（单机 App 不需要插件瀑布） | 搜索 pre-step/waterfall 无结果 | ⚠️ | 架构简化，可接受；但系统提示注入靠 `llmHistory[0]` 每轮重写（AgentSession.swift:215-217），与 dsh 的 assemble 语义等效但不可追溯 |
| 步数护栏 | dsh agent.ts 无 max-steps（由上层 goal 包管） | maxSteps=12，触发后 reason="max-steps" 并提示用户 | AgentSession.swift:90,409-411 | 青山自有 | 不算偏差，列入 §6 |

## 2. inbox 通道（send / followup / steer / inject）

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| 双队列 `next-turn` / `next-step`，可持久化（agent/inbox/spliced 事件）、claim/replay-once | inbox.ts:26,43-55,71-78；types.ts:29,58-65 | **完全不存在**。`send()` 直接 `guard !isThinking` 拒收 | AgentSession.swift:211（`!isThinking, pendingApproval == nil`）；全项目搜索 inbox/steer/followup/inject 无结果 | ❌ | 影响：turn 运行中用户无法插话/追问/追加输入，只能等 turn 结束或自己取消重来；iPad 交互下"边跑边补一句"是高频诉求。这是青山与 dsh 宣称差距最大的架构项之一 |
| followup=next-turn 唤醒 / steer=next-step 唤醒 / inject=next-step 不唤醒 | agent.ts:131-141 | 无 | 无 | ❌ | 同上 |
| abort 后唤醒消息重分类到 next-turn（wakingAfterAbort） | agent.ts:122-129 | 无 | 无 | ❌ | 同上 |

## 3. 中断与工具调用协议

### 3.1 中断语义

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| cancel(cause)：清 inbox + abort 当前 phase，turn/end reason=aborted | agent.ts:143-149,311-314 | AgentSession 无任何 cancel/interrupt 方法；turn 一旦启动只能跑完或出错 | AgentSession.swift 全文；搜索 cancel/abort/interrupt 无结果 | ❌ | 用户无法中途打断一个失控的 turn（如死循环 `yes`）——只能等 30s 工具超时或 12 步护栏。可用性问题，建议 P1 |
| 流中断时把已收到的块落盘为 `assistant/message{interrupted:true}` + usage，保 replay 一致 | agent.ts:372-388 | 流错误时 partial 文本确实随 assistantMessage 事件落盘（AgentSession.swift:312-315），但**无 interrupted 标志**，且 partial **不回喂 llmHistory**（UI 有、上下文无） | AgentSession.swift:312-324（错误路径 return 前未 append llmHistory） | ⚠️ | replay 后 UI 与上下文可能分叉；好在错误后 turn 终止、下次用户输入重开 turn，实际风险低 |
| abort 时未派发的 tool call 记录合成错误结果（"tool call aborted before dispatch"）保 replay 合法 | tool-calls.ts:96-99,238-260 | 无 abort，故无对应；但 deny 时合成了"用户拒绝执行"工具结果，形态同源 | AgentSession.swift:371-379 | ⚠️ | deny 路径语义正确；缺的是 abort 维度本身 |

### 3.2 工具调用协议

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| 原生 tool-call：assistant 消息携带 toolCalls，结果以 `tool` 角色 + tool_call_id 回喂 | tool-calls.ts:277-289；dsh-llm createToolResultMessage | 一致：assistant{content,toolCalls} → tool{content,toolCallId}，序列化格式同 OpenAI wire | LLMTypes.swift:7-22；DeepSeekAdapter.swift:65-75；AgentSession.swift:334,403 | ✅ | — |
| `tool/call` 与 `tool/result` 成对落盘，result 引用 call 的 seq（sourceEventSeqs） | tool-calls.ts:263-289 | 成对落盘 ✅，但无 sourceEventSeqs 溯源 | AgentSession.swift:388-402；SessionLog.swift:52-53 | ⚠️ | 溯源缺失影响 UI 重放时把结果挂回调用卡（现在靠 lastToolCallId 邻近配对，AgentSession.swift:174-185），事件交错时可能配错 |
| 未知工具：照常记录 call+合成错误结果，replay 保持协议合法 | tool-calls.ts:250-260 | **未知工具只回喂 tool 消息，落盘的是 `agent/message` 事件而非 tool/call+tool/result** | AgentSession.swift:341-347 | ❌ | resume 后：assistant 事件带 toolCallsJSON（含未知调用），但日志里无对应 tool/result → 重建的 llmHistory 出现"有 tool_calls 无 tool 结果"，DeepSeek API 会 400。**P0** |
| 并行/屏障调度：parallel 池（maxParallelToolCalls 滚动窗口）+ exclusive 屏障，结果按模型序提交 | tool-calls.ts:85-102,122-247 | 严格串行 for 循环执行 | AgentSession.swift:338 | ⚠️ | 结果顺序天然等于模型序，正确性无损；损失的是并行读文件等场景的延迟。单机可接受的简化，建议在注释/文档里明确"maxParallel=1" |
| 参数解析失败保留原文（parseArguments: JSON.parse 失败→raw text） | tool-calls.ts:104-111 | JSONSerialization 失败→空字典 `[:]`，原文丢弃 | AgentSession.swift:339 | ⚠️ | 坏参数静默变空参，模型得不到"你发的 JSON 坏了"的反馈，可能重复失败 |
| 空 arguments 归一为 `{}` | tool-calls.ts:107 | DeepSeekAdapter 已把空串归一为 "{}"（DeepSeekAdapter.swift:173） | DeepSeekAdapter.swift:173 | ✅ | — |

## 4. SessionLog（持久化格式与崩溃恢复）

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| 行结构 `{seq,type,data}`，首行 `type:"session"` header（version/id/createdAt） | format.ts:46-57,66-89 | 行结构一致，header 字段子集（version/id/createdAt/title） | SessionLog.swift:3-9,58-61 | ✅ | 子集可接受；dsh 的 parentSession/seedLength/delegationDepth 为 fork/subagent 场景，青山无此概念 |
| seq 严格连续（assertContiguous；scan 期 seq gap 即 corrupt） | storage.ts:268；format.ts:441-452 | 新会话 OK（nextSeq 自增）；**但 resume 是灾难：`load()` 后 `SessionLog(sessionID:)` 未从已有事件恢复 nextSeq/headerWritten，下次 append 会再写一条 `{seq:0,session}` header 并把 seq 从 1 重排** | SessionLog.swift:66-112（nextSeq 初始 0；append 只看 headerWritten）；AgentSession.swift:139（load 不调 start 也不恢复游标） | ❌ | **P0 实现缺陷**：任何"恢复会话后继续聊"都会产生重复 seq、第二份 header，replay 与未来任何 seq 索引全部失真。修复：load 时 replay 计算下一 seq 并置 headerWritten=true |
| 崩溃半行（torn tail）：scan 记 committedBytes，下次 append 先 truncate 再重写恢复事件 | format.ts:413-454；storage.ts:273-282 | replay 时静默丢弃解析失败行（等效"读取侧容错"）；**但写入侧无截断修复**——残行留在文件里，且因为 seq 重置 bug，新写入行会叠在残行后 | SessionLog.swift:144-145,166-173（无 truncate 逻辑） | ⚠️ | 读取侧等效、写入侧缺失；叠加 §4-② 后实际恢复质量差。P1 |
| 压缩：可选 zstd（`.jsonl.zstd`），读侧 layout-blind | format.ts:29-39 | 纯明文 JSONL，无压缩 | SessionLog.swift:82 | ⚠️ | 单机会话量级下可接受；记录为已知差异 |
| 单写者/写后缓冲/flush 屏障（storage.ts 全篇） | storage.ts:81-309 | 同步 DispatchQueue 串行写，每行直接落盘（比 dsh 200ms 批量更强） | SessionLog.swift:69,100-112 | ✅ | 同步串行 + 每行 flush，持久性反而更好；性能在 iSH 上未见瓶颈 |
| 事件类型全集：turn/start、step/start、step/end、user/message、assistant/chunk、assistant/message、tool/call、tool/result、turn/end、request/header、request/context、agent/inbox/spliced | agent.ts:264-328,508-531；types.ts:58 | 有前 9 种 ✅；**缺 request/header、request/context、agent/inbox/spliced**；另有自有 agent/message、compact | SessionLog.swift:45-56 | ⚠️ | 缺 request/header 意味着换模型/换参数后 resume 无法得知当时用的什么配置（审计性缺失）；inbox 事件随 inbox 一起缺 |
| assistant/chunk 记录全部流增量（含 reasoning、tool-call delta），message 事件以 sourceEventSeqs 引用 chunk | agent.ts:362-371,426 | 只落 **textDelta** chunk；reasoning 不落 chunk（最终整体存进 assistantMessage.reasoning，截断 6000 字符）；无溯源 | AgentSession.swift:278（仅 textDelta）；315（reasoning prefix(6000)） | ⚠️ | reasoning 超 6000 字符被截断 → 长思考 resume 后上下文里思考块不完整（对后续推理影响小，但与"事件溯源无损"目标有差距） |
| append-only 不可变日志 | storage.ts:264-288 | `rewriteHeaderTitle` 会整体重写文件改 header title | SessionLog.swift:147-164 | ⚠️ | 青山自有功能（重命名会话），但破坏 append-only 原则；掉电时可丢失整个日志。建议 title 移到独立 meta 文件 |
| resume：反向/全量扫描事件重建状态，turn 计数连续（max(turn, ev.turn)） | inbox.ts:32-39（构造即重放）；agent.ts:101 | `load()` 全量重放重建 messages + llmHistory + turnNo ✅ | AgentSession.swift:134-199 | ✅ | 重放逻辑本身正确（受 §4-② 写入侧 bug 连累） |

## 5. 持久 shell（tool-bash-persistent 对照）

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| 持久 shell：cwd/env 跨调用保持 | index.ts:24（工具描述） | ✅ 核心语义达成：常驻 `/bin/sh -l`，eval 包裹 | PersistentShell.swift:5,43-52 | ✅ | — |
| 唯一 UUID 标记包裹命令，从 scrollback 抠出输出与退出码 | index.ts:61-103 | **文件协议**：`eval 'CMD' >/tmp/.qs_o 2>&1; echo $? >/tmp/.qs_r; touch /tmp/.qs_done; cat /tmp/.qs_o`，Swift 轮询 done 文件后直读结果文件 | PersistentShell.swift:7-12,50-51 | ⚠️ | 目标等效、机制不同（注释已说明 iSH PTY 流不可靠的实测原因，属合理工程取舍）。代价：输出经 guest 文件系统落盘（大输出两份 IO）、无 scrollback 概念（不需要）、`/tmp` 被模型可见可写（理论可伪造退出码——低风险，iSH 单用户 root） |
| 超时 → reset 整个 shell（下条命令全新环境）+ 明确告知模型 | index.ts:16-17,338-351 | 超时 → 发 Ctrl-C 杀前台命令，**shell 保留状态**，返回 exitCode=124 + 部分输出 + 中文说明 | PersistentShell.swift:76-88 | ⚠️ | 语义分歧：dsh 认为超时后 shell 状态不可信（可能卡在交互子进程/坏 cwd），选择 reset；青山保留状态。若命令已把终端搞乱（stty 篡改、交互程序残留），后续命令会连环失败且无自愈。建议至少提供"超时后 reset"选项 |
| shell 退出自愈：检测 exited 状态 → 报告 `[shell exited: code N]` + reset + 提示下条全新 | index.ts:196-217,309-317,360-364 | **无任何检测**：shell 若 exit（用户在终端面板敲 exit / 崩溃），后续命令注入后无人消费，只能等满 30s 超时；首条命令有 3 秒内 2 次重发的就绪探测，但仅限 readyConfirmed 之前 | PersistentShell.swift:36-40,57-74；搜索 exited/自愈 无结果 | ❌ | P1：真实使用中 shell 意外退出后 Agent 表现为"每条命令都超时"，完全不可用且无提示 |
| 同 owner 串行队列（前一条完成才发下一条） | index.ts:387-399 | AgentSession 的工具循环本身串行 ✅；但 PersistentShell 无自身队列，若未来有并发调用方会交错写入 PTY | PersistentShell.swift:43（无队列字段） | ⚠️ | 当前唯一调用方是串行循环，风险潜伏；加个 in-flight 守卫即可 |
| echo 抑制（stty -echo） | index.ts:266-271 | ✅ 同样的 stty -echo 初始化 | PersistentShell.swift:31 | ✅ | — |
| 输出截断上限（maxOutputChars 默认 16000 + `<response clipped>` 提示） | index.ts:15,54-59,447 | **无上限**：模型拿到完整输出（只有日志侧截 6000 存档）；上下文按字符数估算压缩 | PersistentShell.swift:68-73；AgentSession.swift:403（llmHistory 收全量）、485 | ❌ | P1：`cat` 一个大文件 / `dmesg` 可瞬间把上下文打爆，压缩阈值 8000 "tokens" 事后才兜底。dsh 的截断+提示语义直接保护上下文 |
| 前台子进程读 stdin 的 mid-flight 检测（stdin_read waitReason → 提前返回部分输出） | index.ts:369-375 | 无（靠 30s 超时兜底） | PersistentShell.swift:57 | ⚠️ | 交互式命令（python REPL 等）必然吃满超时；可接受但应写进工具描述告诫模型 |
| 命令默认时限 | index.ts:446（300s） | 30s（toolTimeout 常量） | AgentSession.swift:89 | ⚠️ | 30s 对构建/安装类命令偏短；好在有 UI 层 ExecutionController 120s 档，但 Agent 工具路径固定 30s |

## 6. LLM 适配（DeepSeekAdapter 对照）

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| SSE 分帧：严格 spec（空行终止、跨 chunk 拼接、UTF-8/CRLF/BOM） | sse.ts:28-40 | 简化行级解析（bytes.lines + `data:` 前缀），跨行事件/多 data: 行不支持；残留未用的 pending 变量 | DeepSeekAdapter.swift:97-113,162-164 | ⚠️ | DeepSeek/OpenAI 兼容端点实际总是单行 data，工程上够用；SSE 载荷 JSON 解析失败会 throw ✅（对应 MALFORMED_RESPONSE） |
| `[DONE]` 哨兵；EOF 未收 [DONE] → STREAM_CLOSED（响应不可信） | sse.ts:18,39 | ✅ sawDone 守卫，缺 [DONE] 即 throw（文案直译了 dsh 语义） | DeepSeekAdapter.swift:106,166-168 | ✅ | 错误未带稳定 code，AgentSession 重试判定靠字符串匹配（见 §6-⑧），建议加 code |
| 三类 delta：reasoning_content（空串不开块）/ content / tool_calls（按 index 拼接） | translate.ts:111-205 | ✅ 全部实现；tool_call identity 仅在为空时接受（等效 acceptIdentity）；reasoning 空串不产出事件 | DeepSeekAdapter.swift:128-155；LLMTypes.swift:42-48 | ✅ | — |
| finish_reason 映射：stop/tool_calls/length→max-tokens；**未知值→error finish**（content_filter 等） | translate.ts:32-44 | 只处理三种已知值；未知值 finishReason 存了但 AgentSession 仅判 `== "length"`，其余一律当 completed | DeepSeekAdapter.swift:157-159；AgentSession.swift:286 | ⚠️ | content_filter/供应商自定义值会被当正常完成，用户看到空回复无解释。P2 |
| usage：可挂 finish chunk 或尾 chunk 取最新；cache 命中从 input 中拆出（prompt_tokens 含缓存） | translate.ts:55-72,204 | ✅ 取最新；❌ 无 cache 拆分（promptTokens 原样收录），也未发送给 UI/日志做 token 审计 | DeepSeekAdapter.swift:119-122 | ⚠️ | 对 DeepSeek 计费/缓存观测有影响；青山把 usage 只用于 done 事件透传，AgentSession 未消费（done 的 tokens 参数被 `_` 丢弃，AgentSession.swift:279） |
| 停止无任何块 → EMPTY_RESPONSE 错误 | translate.ts:133-141 | 无检查：空回复 → messages.removeLast + 正常 turnEnd completed | AgentSession.swift:327-332 | ⚠️ | 模型偶发空响应被静默吞掉，模型侧无信号重试 |
| 流空闲看门狗（idleWatchdog 默认 300s，读无进展即断）+ abort 映射 ABORTED + 传输错误归一 TRANSPORT | adapter.ts:138-159,473-520 | req.timeoutInterval=120（整体超时，非空闲检测）；onTermination cancel ✅；错误统一 DeepSeekError 无分类 | DeepSeekAdapter.swift:42,58；AdapterSession 无重试分类 | ⚠️ | 慢速长流（ reasoning 模型 5 分钟无换行很常见）在 120s 整体超时下反而会被误杀——timeoutInterval 是"整个请求"预算。P1 风险点 |
| 重试策略：retryPolicy 走 agent/request-error 瀑布（providerRetryAfterMs 遵循 Retry-After） | adapter.ts:311-319,685-691 | AgentSession 内联重试：≤3 次、2·a² 秒退避、条件=429/500/502/503/rate_limit 字符串匹配且尚未收到任何 delta | AgentSession.swift:251-304 | ⚠️ | 方向正确（首个 delta 后不重试避免重复输出 ✅）；差距：不读 Retry-After、字符串匹配脆弱、流中途断线不重试。P2 |
| 每次调用冻结连接事实（endpoint+key 同代快照） | adapter.ts:447-452 | 每步 makeAdapter() 新建 DeepSeekAdapter 读当前 SettingsStore——步中途改设置会在下一步生效（无中途换 key 风险，因请求内不变） | AgentSession.swift:516-519 | ✅ | 请求粒度一致性成立 |
| 图片输入/Files API/请求扩展 | adapter.ts:203-299,552-618 | 无（纯文本 Agent） | 搜索 image/files 无结果 | ⚠️ | 明确的范围裁剪，非缺陷；记录备查 |

## 7. 错误路径与上下文一致性

| dsh 语义 | dsh 证据 | 青山现状 | 青山证据 | 判定 | 差距与影响 |
|---|---|---|---|---|---|
| LLM 失败 → 结构化 turn/end{error{message,code}}，失败被驱动边界包含 | agent.ts:311-324 | turnEnd reason="error"（裸串）+ Toast + UI 行内错误说明；turn 终止 ✅ | AgentSession.swift:300-324 | ⚠️ | 失败信息（哪个 provider/code）未结构化落盘，resume 后无法区分失败类型 |
| 重试后不产生重复的上下文污染（retry 重建 request） | agent.ts:390-407 | 重试仅发生在零 delta 时，llmHistory 无污染 ✅ | AgentSession.swift:291-299 | ✅ | — |
| 工具结果进 llmHistory 与落盘一致（replay 可重建等价上下文） | tool-calls.ts:282-289 | 正常路径一致 ✅；**两个洞**：未知工具（§3.2）与 deny 后的 approval/request·decision 事件 replay 时被 load() 的 default 分支丢弃（不影响 llmHistory 但丢审批审计） | AgentSession.swift:341-347,358-368,174-193 | ⚠️ | 审批历史不进重放；P2 |
| 上下文估算与压缩 | dsh compaction 包（不在本次基准范围） | 自有 auto-compact：字符数/2 估算 token，>8000 触发摘要压缩，压缩事件落盘且 replay 重建 | AgentSession.swift:91,484-512；AgentSession.swift:186-189 | 青山自有 | 估算粗糙（中文≈1 字 2 "token" 偏差大），但闭环完整；列入 §6 清单 |

---

## 8. 青山有而 dsh 没有（自有功能，非偏差）

| 功能 | 证据 | 说明 |
|---|---|---|
| 审批系统（三策略 fail-closed 白名单、内联审批卡、allowOnce/allowAlways/deny） | Approval.swift 全篇；AgentSession.swift:350-386 | dsh 审批在别的包且 header 已退役该字段；青山按移动端形态重做 |
| auto-compact 上下文压缩 + /compact | AgentSession.swift:479-512 | dsh 压缩在独立包，青山为单机简版 |
| FakeLLM 脚本化大脑（无 Key 可验收） | FakeLLM.swift | 测试基线用途 |
| max-steps 步数护栏（12） | AgentSession.swift:90,409-411 | dsh agent-loop 无此概念 |
| iSH 就绪探测/命令重发（boot 后 shell 未就绪） | PersistentShell.swift:34-40 | 平台特有（iSH 启动时序） |
| 记忆系统（MemoryStore 注入 + <qs-mem-cite> 引用闭环，参照 Codex） | AgentSession.swift:100-103,215-217,414-426 | 归 audit-codex-mem 审计域 |
| Keychain BYOK、EffortTier 推理档位 | LLMTypes.swift:59-130；DeepSeekAdapter.swift:83-87 | 移动端 BYOK 形态 |
| ExecutionController 一次性命令管道（SIGKILL 超时治理、终端面板） | ExecutionController.swift | 独立于 Agent 的 M1 执行桥 |
| Think 折叠行 / 内联审批卡 UI 形态 | AgentSession.swift:26-32,260-269 | UI 层 |
| 会话重命名（重写 header title） | SessionLog.swift:147-164 | 破坏 append-only，见 §4 |

---

## 9. 差距修复优先级

### P0（正确性，立即修）
1. **resume 后 seq 重置 + 重复 header**：`AgentSession.load()` 后未恢复 SessionLog 游标（SessionLog.swift:70,99-112 + AgentSession.swift:139）。任何"恢复会话继续聊"都会写坏日志。修复：load 时用 replay 结果初始化 nextSeq / headerWritten（或 SessionLog 提供 `resume(from:)`）。
2. **未知工具不落 tool/call + tool/result**（AgentSession.swift:341-347）：resume 后 llmHistory 出现"有 tool_calls 无结果"，DeepSeek API 400。修复：未知工具同样 append toolCall + toolResult 事件（内容可为 "未知工具"）。
3. **write_file heredoc 分隔符碰撞**（AgentSession.swift:453）：content 含单独一行 `QSEOF` 即截断/注入。修复：改 base64 管道（`echo <b64> | base64 -d > path`）或先校验。

### P1（可用性/健壮性）
4. **模型输出无截断上限**：对齐 dsh maxOutputChars（16k + `<response clipped>` 提示），防大输出撑爆上下文（PersistentShell.swift:68-73）。
5. **shell 退出自愈缺失**：检测 shell 退出（探测写失败/连续超时）→ 重建 shell 并告知模型（对照 index.ts:196-217）。
6. **超时策略分歧**：Ctrl-C 保留状态 vs dsh reset；至少在超时后验证 shell 可用（`echo` 探测），不可用则 reset（PersistentShell.swift:76-88）。
7. **取消能力**：给 AgentSession 加 cancel（终结当前流 + 合成工具结果 + turnEnd aborted），否则失控 turn 无法打断（AgentSession.swift 全文无 cancel）。
8. **流超时模型**：120s 整体 timeoutInterval 会误杀长思考流；改为空闲看门狗语义（对照 adapter.ts:473-520）。
9. **finish_reason 未知值 / EMPTY_RESPONSE**：未知 reason 按 error 呈现；空响应给模型明确错误信号（translate.ts:32-44,133-141）。

### P2（架构对齐/审计性）
10. request/header、request/context 事件落盘（配置审计与 resume 可解释性）。
11. inbox 双通道（next-turn/next-step）——工程量大，建议先做"turn 结束后自动消费排队输入"的简版。
12. interrupted 标志、sourceEventSeqs 溯源、结构化 reason/code、usage cache 拆分、Retry-After 遵循、审批事件进重放。
13. zstd 压缩、rewriteHeaderTitle 改独立 meta 文件（恢复 append-only）。
14. 参数解析失败保留原文回喂模型（tool-calls.ts:104-111 语义）。

---

## 10. 审计结论

青山对 dsh 的复用是**真实但选择性**的：事件溯源行格式、turn/step 事件序列、三类 SSE delta、[DONE] 哨兵、持久 shell 核心语义（stty -echo、状态保持、退出码采集）都有一一对应的实现证据，且注释中明确标注了对齐来源。但三条 dsh 的"骨架级"语义完全缺失：**inbox 双通道（§2 全 ❌）、中断/abort 全链路（§3.1 全缺失）、工具并行调度（降级为串行）**；持久化侧则存在 1 个 P0 实现缺陷（resume seq 重置），它使"事件溯源 + resume"这条宣称在当前代码下不成立。修复 P0 三项后，"复用 dsh 工程架构"的宣称在单机 Agent 场景下可达到诚实的 ⚠️ 水平。
