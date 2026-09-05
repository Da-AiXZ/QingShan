# dsh 参数全量对照（青山 vs DeepSeek Harness）

> 生成：2026-09-05 · 分析员：m67-dsh-params
> 方法：逐包 grep dsh 源码全部 `Config`/`z.object`/`.default()`/数值常量；逐文件读青山全部 Swift。
> 路径基准：dsh = `repos/deepseek-harness/deepseek-harness-master/packages/`；青山 = `QingShan/QingShan/`。
> 所有默认值均来自亲自读取的源码行号，可复核。

---

## 一、dsh 参数总表（参数 | 默认值 | 位置 | 语义）

### 1. Agent 循环调度（core/agent-loop）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| maxParallelToolCalls | 10 | core/agent-loop/src/constants.ts:6、index.ts:314 | 每步并行在途工具调用上限（1=串行）；热更新可改 |
| maxTokens（AgentOptions） | 无默认（可选，正整数校验 index.ts:199-204） | core/agent-loop/src/index.ts:371 | 请求输出 token 上限，逐 agent 配置 |

### 2. Bash 执行器（shell/bash-local，一次性前台命令）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| timeoutMs | 120_000 | shell/bash-local/src/index.ts:107 | 前台命令默认超时 |
| maxTimeoutMs | 600_000 | index.ts:108 | 模型 per-call 覆盖上限（clampTimeout） |
| maxOutputBytes | 64_000 | index.ts:109 | 每流内存输出上限，超出溢写临时文件 |
| maxSpillBytes | 64 MB | index.ts:38,110 | 溢写文件上限，更大只保留内存尾 |
| graceMs | 3_000 | index.ts:35,111 | SIGTERM→SIGKILL 升级宽限（对齐 OpenCode 3s） |
| cwd | process.cwd() | index.ts:159 | 默认工作目录 |

### 3. 持久 bash 工具（shell/tool-bash-persistent，青山 PersistentShell 的对标）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| timeoutMs | 300_000 | index.ts:446 | 单条命令墙钟上限；**超时后重置整个持久 shell** |
| maxOutputChars | 16_000 | index.ts:447 | 返回给模型的字符上限，截断附 `<response clipped>` NOTE |
| POLL_INTERVAL_MS | 25 | index.ts:22 | 完成标记轮询间隔 |
| SCROLLBACK_PAGE_LINES | 1_000 | index.ts:21 | 回读 scrollback 分页行数 |
| backendType | 'shell' | index.ts:445 | PTY 后端 |

### 4. bash 工具层（shell/tool-bash）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| enableRunInBackground | true | index.ts:40 | 是否暴露 run_in_background（后台无超时） |
| ENV_OVERRIDES | NO_COLOR=1, TERM=dumb, PAGER=cat, GIT_PAGER=cat | bash-local/src/index.ts:27-32 | 模型友好终端环境 |

### 5. 后台任务（jobs）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| waitTimeoutMs | 30_000 | jobs/tool-jobs/src/index.ts:48 | job_output 默认等待 |
| maxWaitTimeoutMs | 600_000 | index.ts:49 | job_output 等待上限 |
| completionDelivery | 'wakeup' | index.ts:50 | 完成通知方式 |
| maxConsecutiveWakes | 3 | index.ts:51 | 连续唤醒上限 |
| maxConcurrentTasksPerOwner | 10 | jobs/jobs-local/src/index.ts:28 | 每 owner 并发任务上限 |

### 6. LLM 请求与流（llm/llm-deepseek）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| streamIdleTimeoutMs | **300_000** | llm/llm-deepseek/src/adapter.ts:138、index.ts:185 | **流空闲看门狗**：两次 SSE 增量间最大间隔；非总时长超时 |
| defaultContextWindow | 1_000_000 | adapter.ts:140 | 上下文窗口估算（compaction 分母） |
| DEFAULT_MAX_TOKENS | 256_000 | adapter.ts:142 | 请求默认输出 token 上限 |
| filesApiTimeoutMs | 60_000 | adapter.ts:158 | Files API 请求超时 |
| maxRequestFilesBytes | 128 MB | request-pricing.ts:20 | 单请求文件总字节 |
| maxImagesPerRequest | 600 | request-pricing.ts:22 | 单请求图片数 |
| apiKeyEnv | DEEPSEEK_API_KEY | index.ts:88,178 | 凭据环境变量 |
| MAX_CHAT_IMAGE_BYTES / MAX_FILE_UPLOAD_BYTES | 32 MB / 128 MB | file-store.ts:11、files-api.ts:13 | 上传硬上限 |

### 7. LLM 重试策略（llm/llm/src/retry-policy.ts，dsh-llm-retry 执行）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| maxRetries | 5 | retry-policy.ts:14 | 首次请求后最大重试次数 |
| initialDelayMs | 500 | retry-policy.ts:15 | 指数退避起始延迟 |
| maxDelayMs | 10_000 | retry-policy.ts:16 | 退避上限 |
| jitterRatio | 0.1 | retry-policy.ts:17 | 对称抖动比例 |
| retryableCodes | [EMPTY_RESPONSE, RATE_LIMIT, SERVER, TIMEOUT, TRANSPORT] | retry-policy.ts:18-22 | 可重试失败码（**含 TIMEOUT/TRANSPORT**） |

### 8. Compaction（compaction/*）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| thresholdRatio | 0.8 | compaction/compaction-basic/src/config.ts:20 | 请求压力达窗口 80% 触发压缩 |
| retainRatio | 0.16 | config.ts:23 | **压缩后逐字保留的尾部比例** |
| maxTokens（摘要请求） | 8_192 | config.ts:91 | 压缩摘要的输出上限 |
| compactionRetries | 1 | config.ts:92 | 压缩调用重试 |
| maxOverflowRetries | 1 | config.ts:93 | 压缩后仍溢出的重试 |
| thresholdChars / headChars / tailChars（工具结果修剪） | 8_192 / 4_096 / 1_024 | compaction/compaction-tool-result-pruner/src/config.ts:10-13 | 超长工具结果保留头尾、中段打码 |

### 9. 护栏（guard/*）——**dsh 没有步数护栏**

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| thresholds | [3, 5, 8] | guard/repeat-tool-reminder/src/index.ts:46 | **同一工具重复调用 3/5/8 次**时注入提醒（软提示，不终止） |
| argumentsPreviewChars | 500 | index.ts:49 | 提醒中参数预览长度 |
| timeoutMs（工具级，无默认） | 每工具自声明；未声明=无截止 | core/tools/src/index.ts:247、guard/timeout-policy/src/index.ts | 协作式超时由 tools/execute 包装器执行（TOOL_TIMEOUT 码） |

> **负面结论（重要）**：全库 grep `maxSteps|maxTurns|stepLimit|turnLimit|guardrail` 零命中。dsh 循环没有任何步数/轮数硬终止，收敛靠模型自停 + 工具超时 + 用户中断。青山"12 步护栏误杀"的根因即在此：**该护栏在 dsh 中不存在对应物**。

### 10. 会话持久化（session/session-persistence-jsonl）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| compression | 'zstd' | index.ts:70 | 日志压缩 |
| packChunks | true | index.ts:50 | 打包行写入 |
| LIVE_WRITE_BATCH_MAX_DELAY_MS | 200 | storage.ts:34 | 实时写批最大延迟 |

### 11. 通用（util/timeout）

| 参数 | 默认值 | 位置 | 语义 |
|---|---|---|---|
| MAX_TIMER_DELAY_MS | 2_147_483_647 | util/timeout/src/index.ts:25 | 任何 timeout 配置的上界 |

dsh 参数总计 **36 项**（不含 pwsh 系与图片/文件冷参数后，与青山相关的约 24 项）。

---

## 二、逐条对照表

判定：✅已对齐 / ❌应修改（给建议值） / 🟦青山特有（标理由） / 🟪dsh 特有（评是否需要）

| dsh 参数/默认值 | 青山对应值 | 青山位置 | 判定 |
|---|---|---|---|
| streamIdleTimeoutMs=300_000（空闲看门狗） | URLSession.timeoutInterval=**120s 总时长超时**，无空闲看门狗 | DeepSeekAdapter.swift:58 | ❌ **最危险**。总时长 120s 会掐死合法的长思考/长输出流（正是"流中断"事故形态）。建议：去掉总时长限制，实现空闲看门狗——每收到一条 SSE 事件重置 300s 计时器 |
| bash timeoutMs=120_000 | run_command 默认 **60s** | AgentSession.swift:489（描述见 :40） | ❌ 建议 120s 对齐 bash-local。60s 是"30s 事故"的半修正，仍偏紧 |
| maxTimeoutMs=600_000 | timeout_sec 上限 min(600, t)=600s | AgentSession.swift:487 | ✅ 对齐 |
| tool-bash-persistent timeoutMs=300_000 | 网络类自动放宽 **240s** | AgentSession.swift:488 | 🟦 青山用命令分类放宽而非统一 300s；可接受，但建议把兜底默认提为 120s、网络类 300s 对齐 persistent 语义 |
| toolTimeout（execShell 兜底） | dsh 无此层 | AgentSession.swift:92 = **30s** | ❌ 遗留值，当前 execToolCall 总显式传 timeout 故未触发，但下一次新调用点绕过即复发"30s 事故"。建议删除或改 120_000 |
| maxOutputChars=16_000（persistent，保头+clip NOTE） | 16_000，保头+clip NOTE | AgentSession.swift:410-411 | ✅ 数值与语义均对齐（persistent 保头；注意 dsh tool-bash 非持久路径是保尾，青山只有持久路径，无需改） |
| compaction thresholdRatio=0.8 | compactThresholdTokens=48_000（est=chars/2，64k 窗口的 75%） | AgentSession.swift:94,517-519 | 🟦 近似对齐（0.75 vs 0.8）。窗口估 64_000 是青山对 DeepSeek 实际窗口的保守假设，合理保留 |
| retainRatio=0.16（压缩保留逐字尾部） | **无**：压缩后仅 system+摘要+一条确认 | AgentSession.swift:539-546 | ❌ 压缩把最近的对话细节全部丢弃，长任务中途压缩会失忆。建议：摘要外保留最近若干轮原文（≈16% 窗口 ≈10k tokens） |
| retry maxRetries=5 | attempt<3（2/3 次） | AgentSession.swift:300 | ❌ 建议 5 |
| retry initialDelayMs=500, maxDelayMs=10_000, jitter=0.1 | 2·n² → 2s,8s 固定 | AgentSession.swift:304 | ❌ 建议 0.5s 起指数退避、上限 10s、带抖动；2s/8s 固定档对 429 恢复偏慢且无抖动 |
| retryableCodes 含 EMPTY_RESPONSE/TIMEOUT/TRANSPORT | 仅 429/500/502/503 文本匹配，且要求 full.isEmpty && !hadDelta | AgentSession.swift:300-302 | ❌ TIMEOUT/TRANSPORT（网络抖断流）不可重试；流中途断（hadDelta=true）也不重试。建议：断流后带已收文本重试或至少补齐对 TIMEOUT 码的重试 |
| DEFAULT_MAX_TOKENS=256_000（随请求发送） | **不发送 max_tokens** | DeepSeekAdapter.swift:60-88 | ❌ DeepSeek API 缺省 max_tokens=4096，长回复会被 finish_reason=length 截断（青山已识别 max-tokens 但源头没防）。建议显式发送模型允许的上限 |
| repeat-tool-reminder thresholds=[3,5,8]（软提醒） | 无重复调用提醒；有 maxSteps=48 硬终止 + 24 步收敛提示 | AgentSession.swift:93,243-251,427-429 | ❌ 方向反了。dsh 只做软提醒不做终止。建议：删除 maxSteps 硬终止（或提高到不现实值仅作兜底），改为重复工具 3/5/8 次软提醒 + 24 步提示保留 |
| tool 级 timeoutMs（协作式，工具自声明） | run_command 工具 schema 暴露 timeout_sec（60-600） | AgentSession.swift:45,485-489 | ✅ 语义等价（模型可控超时+执行器封顶） |
| bash 超时处置：reset 整个持久 shell + 返回部分输出 | Ctrl-C + 等 400ms 读部分输出，**不 reset shell** | PersistentShell.swift:76-87 | ❌ 超时命令可能留下脏后台子进程/脏 cwd；dsh 超时即重置 shell 保证下一条从干净状态开始。建议：超时后重建持久 shell |
| graceMs=3_000（SIGTERM→SIGKILL 升级） | 直接 Ctrl-C（SIGINT），无升级链 | PersistentShell.swift:77 | 🟦 iSH 无进程组 SIGTERM 通道，Ctrl-C 是唯一手段；可接受，但超时后应补一次 shell reset（见上行） |
| POLL_INTERVAL_MS=25 | 60ms 文件轮询 | PersistentShell.swift:58 | ✅ 文件协议下 60ms 足够，语义对齐 |
| 命令注入前就绪探测 | 3s 无 done 文件则重发，最多 2 次 | PersistentShell.swift:36-40 | 🟦 青山特有（iSH boot 后 shell 未就绪的真实问题），dsh 无对应 |
| maxOutputBytes=64_000 / spill 64MB | 无内存/溢写分层；输出直接读文件，无大小上限 | PersistentShell.swift:68-69 | ❌ `cat 超大文件` 输出全量进 .qs_o 再全量读入内存+llmHistory（截断发生在读入之后）。建议：读侧直接 prefix(16_000+1) 判断，或写入侧 head -c 限制 |
| contextWindow=1_000_000（默认） | CtxUsage.windowTokens=64_000 | ComposerKit.swift:50 | ✅ 语义相同，青山取真实窗口更保守，保留 |
| job waitTimeoutMs=30_000/maxWait=600_000 | 无后台 job 系统 | — | 🟪 青山暂无 run_in_background；iSH 单 shell 前台协议下暂不需要，列 backlog |
| maxConcurrentTasksPerOwner=10 | 串行执行（for call in toolCalls） | AgentSession.swift:347 | 🟦 串行 vs dsh maxParallelToolCalls=10；iSH PTY 单通道决定串行，保留 |
| session 持久化 zstd/packChunks/batch200ms | 纯 JSONL 明文、逐行同步 append | SessionLog.swift:114-123 | 🟦 单机 iPad、日志量小，明文便于用户 Files App 查看；保留 |
| 断线恢复：interruptedTurnClosers（合成缺失 tool/step/turn 闭合事件） | load() 直接重放；**未补合成闭合事件**，靠"未知工具也落 tool/result 对"部分缓解 | AgentSession.swift:336-360、SessionLog.swift:187-194 | ❌ resume 时若最后一步停在"assistant 带 tool_calls 未执行"，DeepSeek API 400。建议：load() 末尾检测悬挂 tool_calls 并合成 error tool/result + turn/end |
| ENV_OVERRIDES（NO_COLOR/TERM=dumb/PAGER=cat） | 未设置 | PersistentShell.swift:31 仅 stty -echo | ❌ 低优先。建议注入 wrapped 命令前 export 同款变量，减少 ANSI 噪声进上下文 |
| 审批/沙箱升级（sandbox_permissions+justification） | ApprovalService 三策略+白名单/危险正则 | Approval.swift:43-56 | 🟦 青山特有（iSH root 单沙箱内，无 dsh sandbox mode 体系）；fail-closed 设计对齐 dsh 精神 |
| repeat-tool-reminder argumentsPreviewChars=500 | 无 | — | 🟪 随软提醒机制一并引入 |
| （无对应） | 系统提示 24 步收敛 hint | AgentSession.swift:246-251 | 🟦 青山特有，无害可留 |
| （无对应） | 记忆管线：transcript 8k 上限、agent 回复 prefix 800、首条消息≥6 字、每批 5 会话、21 天淘汰、topN 200、summary 10k 字符、AGENTS.md 16k | MemoryPipeline.swift:41-76、MemoryStore.swift:86-106,187 | 🟦 Codex 记忆语义移植，dsh 无此层；数值自洽，保留 |
| （无对应） | reasoning 落盘 prefix 6000、toolResult 落盘 prefix 6000 | AgentSession.swift:324,420 | 🟦 事件日志防膨胀，青山特有；注意 6000 截断的是**落盘副本**而 llmHistory 用全量 outForModel，语义自洽 |
| （无对应） | ConsoleHub 缓冲 128k→裁到 64k | RootView.swift:24-25 | 🟦 UI 层，保留 |
| （无对应） | ExecutionController 手动终端 [30s,120s,∞] + SIGKILL | ExecutionController.swift:12 | 🟦 用户手动终端与 Agent 循环无关；30s 档建议改名"快速"以免与事故混淆 |
| （无对应） | 审批 Toast 3s/3.5s 等 UI 时长 | Toast.swift:18 等 | 🟦 UI 层，无关 |

---

## 三、修复优先级清单（批 2 输入）

**P0 —— 会直接复发真机事故**

1. **LLM 流总时长 120s → 空闲看门狗 300s**（DeepSeekAdapter.swift:58）。总时长超时必然掐死长推理流；dsh 语义是"两次增量间隔 >300s 才算断"。这是下一个"30s 超时"级事故的最可能来源。
2. **删除/修正 toolTimeout=30s 遗留**（AgentSession.swift:92）。一颗哑弹：任何新调用点走 `execShell(cmd)` 无参路径即回到 30s。改 120s 或删掉兜底参数强制显式。
3. **run_command 默认 60s → 120s**（AgentSession.swift:489），网络类 240s→300s 对齐 tool-bash-persistent。同步改工具描述（AgentSession.swift:40,45）。
4. **maxSteps=48 硬终止 → 移除**（AgentSession.swift:93,243,427-429）。dsh 零命中步数护栏；12 步误杀事故的根治是去掉硬终止，保留 24 步软提示，另加 repeat-tool 3/5/8 软提醒。

**P1 —— 高频质量问题**

5. **重试策略对齐**（AgentSession.swift:300-307）：次数 3→5、可重试码加 TIMEOUT/TRANSPORT/空响应、退避 0.5s 起指数+10s 上限+0.1 抖动；流中断（hadDelta）场景至少允许重试一次。
6. **显式发送 max_tokens**（DeepSeekAdapter.swift:60-88）：避免 DeepSeek 缺省 4096 截断，finish_reason=length 目前只标记不防护。
7. **compaction 保留尾部**（AgentSession.swift:539-546）：补 retainRatio≈0.16 语义（摘要 + 最近原文），否则长任务压缩后执行细节全失。
8. **resume 悬挂 tool_calls 修复**：load() 末尾合成 error tool/result + turn/end（对齐 dsh interruptedTurnClosers），否则崩溃后 resume 400。

**P2 —— 稳健性**

9. **超时后重置持久 shell**（PersistentShell.swift:76-87）：对齐 dsh 超时即 reset，防脏状态跨调用传染。
10. **输出读入内存前限流**：.qs_o 读取侧按 16_000+1 截断判断，防超大输出打爆 iPad 内存。
11. **注入 NO_COLOR/TERM=dumb/PAGER=cat** 环境变量（对齐 bash-local ENV_OVERRIDES）。

**已对齐、无需动**：maxOutputChars=16_000、timeout_sec 上限 600、轮询间隔、64k 窗口估算、串行执行（iSH 约束）、明文 JSONL（单机场景）。

**Top5 危险参数**：① LLM 120s 总超时 ② toolTimeout=30s 遗留 ③ maxSteps 硬终止 ④ 重试不含 TIMEOUT/断流不重试 ⑤ 未发 max_tokens（缺省 4096 截断）。
