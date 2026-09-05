# 08 · Codex 机制补充解读手册

> 2026-09-05 ｜ 解读对象：`repos/codex-rust/codex-rust-v0.153.0-alpha.6/codex-rs/`（v0.153.0-alpha.6）
> 定位：青山此前只对照了 Codex 的**记忆系统**（见 `审查/03`），本手册补齐 Codex **其余全部机制**的解读与对照。所有结论均来自本解读员亲自读取的源码，行号为该版本实际行号。
> 价值分级：🅐 直接可吸收 ｜ 🅑 需 iOS 适配 ｜ 🅒 暂不需要 ｜ 🅓 CLI 特有不适用

---

## 〇、包关系简图

Codex-rs 是一个约 140 个 crate 的 workspace。核心依赖方向：

```
┌────────────────────────── 前端层 ──────────────────────────┐
│  tui/          终端 UI（ratatui，insert_history + composer） │
│  exec/         无头 CLI（一次性任务）                        │
│  app-server*   给 IDE/桌面端用的 JSON-RPC 服务层             │
└──────────────────────────────┬─────────────────────────────┘
                               │ EventMsg 流 / TurnInput 提交
┌──────────────────────────────▼─────────────────────────────┐
│                    core/  （agent 引擎本体）                 │
│  codex_thread.rs → ThreadManager → CodexThread              │
│  session/mod.rs(Session) ─ session/turn.rs(run_turn 主循环)  │
│  session/input_queue.rs（插话/steer 队列）                   │
│  tools/（审批 approvals.rs、工具路由、unified_exec）          │
│  compact.rs（本地压缩）+ compact_remote*（服务端压缩）        │
│  client.rs（模型流客户端）  exec.rs（命令执行）               │
│  safety.rs（补丁安全检查）  exec_policy.rs（规则引擎）        │
└───┬──────────────┬──────────────┬──────────────┬───────────┘
    │              │              │              │
┌───▼────┐   ┌─────▼─────┐  ┌─────▼─────┐  ┌─────▼──────┐
│sandboxing│  │ protocol/ │  │ rollout/  │  │ state/     │
│ seatbelt │  │ 协议类型   │  │ JSONL 会话 │  │ SQLite DB  │
│ landlock │  │(SandboxPolicy│ │ 持久化+resume│ │ 会话元数据  │
│ bwrap/win│  │ AskForApproval│└───────────┘  └────────────┘
└──────────┘  └───────────┘
      ▲
      │ 派生子进程
linux-sandbox/（独立二进制：landlock + seccomp 启动器）
```

与青山架构的对应：`core/session` ≈ 青山 AgentCore；`rollout` ≈ SessionLog；`compact.rs` ≈ ContextAssembler 的压缩；`tools/approvals.rs` ≈ Approval；`client.rs` ≈ LLMAdapter。**memories/ 模块已对照过（审查/03），本手册跳过。**

---

## 一、主循环与 turn 管理

### 1.1 run_turn 主循环

**是什么**：Codex 的 agent 循环不是递归而是一个平铺 `loop`——每次迭代"取插话 → 捕获 step 上下文 → 发一次采样请求 → 执行工具 → 判断是否继续"。
关键文件：`core/src/session/turn.rs:155`（`run_turn` 函数签名）、`turn.rs:312`（主 `loop`）。

**设计要点**：
- 循环体每轮先 `get_pending_input`（turn.rs:316）取用户插话（steer），合并进历史后再发请求；
- `needs_follow_up = 模型要求跟进一步 || 有待处理插话`（turn.rs:434），`needs_follow_up` 为 false 才 `break` 结束 turn；
- 模型返回消息后还要过 Stop hook（turn.rs:513-559）：hook 可"拦截续跑"（`should_block`）或"强制停止"（`should_stop`），且有 `stop_hook_active` 防止 hook 无限自续；
- 每个 turn 持有 `CancellationToken`（turn.rs:160），所有可取消 await 都 `.or_cancel(&token)`——**中断是协作式的、贯穿全链路的**；
- turn 开始前还有 `run_pre_sampling_compact`（turn.rs:171, 1053）：上一 turn 结束后如果 token 超限，先压缩再开新 turn。

**对青山**：🅑 主循环结构（青山 AgentCore 已是类似 while 循环）；🅐 三个可直接吸收的点：
1. **needs_follow_up 单一判定**（模型继续 ∪ 有插话）作为循环继续条件，比青山的"固定 12 步护栏"更干净——护栏只该是兜底而非循环条件；
2. **Stop hook 的 block/stop 双语义 + 防自续标志**；
3. **turn 前置压缩**：开新 turn 前先检查窗口，避免"先塞爆再压缩"。

**青山现状**：部分（无插话合并、无 Stop 语义；循环条件为步数上限）。

### 1.2 插话（steer）与邮箱机制

**是什么**：turn 进行中用户输入不丢弃，进 `InputQueue`，在下一轮采样前 drain 进历史。
关键文件：`core/src/session/input_queue.rs:79`（InputQueue）、`turn.rs:306-309`（注释解释两类延迟 drain 场景）。

**设计要点**：
- 两类输入：`Steer`（插话进当前 turn，存于 TurnState.pending_input）与 `Mailbox`（跨 agent 通信，可触发新 turn，input_queue.rs:66-70）；
- 两个"不立即 drain"的细节：turn 开头先采样本轮新输入（turn.rs:307-309）；auto-compact 之后让模型/工具续跑优先于插话（turn.rs:507 `can_drain_pending_input = !model_needs_follow_up`）——**压缩后的连续性优先于用户插话**，避免摘要刚生成就被打断。

**对青山**：🅐 插话队列模型（青山完全没有，审查 02 判定"无 inbox"）；"压缩后不 drain 插话"这一细节同样值得抄。

**青山现状**：未实现。

### 1.3 turn 中断（Esc/Ctrl-C）

**是什么**：`Session::interrupt_task`（session/mod.rs:4567）调 `abort_all_tasks(TurnAbortReason::Interrupted)`，本质是 cancel CancellationToken + 杀子进程组（exec.rs:69 取消宽限期 50ms）。
**对青山**：🅐 青山 G-1（turn 无取消）正要修——Swift 侧对应"取消 `URLSessionTask`/AsyncTask + 杀 iSH 内子进程"。Codex 的协作式取消（每个 await 点都 or_cancel）比"杀线程"可靠。
**青山现状**：未实现（批 2 计划中）。

---

## 二、命令执行与 sandbox 策略

### 2.1 SandboxPolicy 四级模型

**是什么**：命令执行限制的声明式模型。
关键文件：`protocol/src/protocol.rs:1070`（SandboxPolicy）、`protocol.rs:1126`（WritableRoot）。

**设计要点**：
- 四级：`danger-full-access` / `read-only`（可开 network_access） / `external-sandbox`（进程已在别的沙箱里，比如 IDE 容器）/ `workspace-write`（cwd + TMPDIR + /tmp 可写 + 额外 writable_roots，协议行 1096-1117）；
- **WritableRoot 内嵌"只读子路径"**（protocol.rs:1120-1136）：workspace 可写，但 `.git`（尤其 `.git/hooks`）、`.codex` 等可提权路径强制只读（PROTECTED_METADATA_PATH_NAMES）。这是"沙箱内防提权"的关键设计；
- 实现层三选一（`sandboxing/src/manager.rs:297` select_initial）：macOS **Seatbelt**（sandbox-exec + .sbpl 策略文件，seatbelt.rs:21-34 内嵌基础策略模板，且硬编码 `/usr/bin/sandbox-exec` 防 PATH 投毒，seatbelt.rs:59-63）；Linux **Landlock**（独立 `codex-linux-sandbox` 二进制做启动器）；Windows 受限 token。平台不支持时 `SandboxType::None`，此时安全责任完全落到审批层（safety.rs:72-88：**有沙箱才自动放行，没沙箱就问用户**）。

**对青山**：
- 🅓 Seatbelt/Landlock 实现本身——iSH 是天然沙箱，不适用；
- 🅐 **"有沙箱才能自动放行"的哲学**值得作为青山审批器的公理：青山命令免审白名单之所以危险（S1-1 绕过），正是因为它在"沙箱能力未知"时假设了安全。青山 iSH 沙箱是进程级而非文件系统级，等价于 `external-sandbox`——可以引用这个语义来定义青山的默认审批档；
- 🅑 WritableRoot 保护清单思想可移植成青山的**免审命令黑名单前缀**（即使命令白名单通过，触碰 `.git/hooks`、shell rc 等提权路径的命令仍需审批）。

**青山现状**：未实现（无沙箱等级概念；审批白名单是纯字符串匹配）。

### 2.2 exec_policy 规则引擎

**是什么**：命令先过**静态规则**（.rules 文件：allow/deny/prompt 前缀匹配）再决定是否需要审批。
关键文件：`core/src/exec_policy.rs:48-56`（常量：策略与审批冲突时 fail-closed 的文案）、`BANNED_PREFIX_SUGGESTIONS`（exec_policy.rs:57-71——明确禁止把 `bash`、`bash -c`、`sh -lc` 等万能前缀写进 allow 规则）。

**设计要点**：规则解析为前缀树（codex_execpolicy crate）；规则要求 prompt 但 `AskForApproval=Never` 时直接拒绝（不静默放行）；危险命令检测（`is_dangerous_command`）独立于规则存在。

**对青山**：🅐 两条：① **免审白名单禁止含糊前缀**（`bash`、`sh -c` 一类等于全放行——正是青山 S1-1 的教训的体系化表达）；② **白名单与审批档冲突时 fail-closed**。
**青山现状**：部分（有 isSafe 白名单，但无前缀黑名单、无 fail-closed 规则）。

### 2.3 命令执行细节（exec.rs）

**是什么**：统一的命令执行管线。
关键文件：`core/src/exec.rs:61-92`。

**设计要点**（参数默认值）：
- 默认超时 10s（DEFAULT_EXEC_COMMAND_TIMEOUT_MS，exec.rs:61）；超时退出码沿用惯例 124、信号退出码 128+n（exec.rs:66-68）；
- 输出硬上限 EXEC_OUTPUT_MAX_BYTES（exec.rs:79，防止单条命令 OOM agent）+ 实时 delta 事件上限 10,000 条（exec.rs:83）；
- IO 排空超时 2s（exec.rs:92）——**孙进程继承 stdout 管道导致父进程读不完**是真实事故源，Codex 显式设防；
- 取消宽限 50ms 后 kill 进程组（exec.rs:69）。

**对青山**：🅐 输出上限青山已有（G-2，16k 字符）；🅐 **IO 排空超时 + 进程组 kill** 是青山 iSH 桥该抄的细节（青山的 shell 自愈 G-4 会遇到同款问题）；🅐 超时退出码语义（124）可让模型自己读懂"超时了"。
**青山现状**：部分（有截断，无进程组管理、无 IO 排空保护）。

---

## 三、审批模型

### 3.1 审批策略档（AskForApproval）

**是什么**：用户可配的审批粒度档位。
关键文件：`protocol/src/protocol.rs:984-1007`。

**设计要点**：四档——`untrusted`（UnlessTrusted，不可信项目全审批）/ `on-request`（**默认**，模型自己决定何时求助，serde alias 兼容旧名 `on-failure`，protocol.rs:992-994）/ `granular`（细分开关：sandbox_approval、rules、skill_approval、request_permissions、mcp_elicitations，protocol.rs:1010-1024，**false = 自动拒绝而非弹窗**）/ `never`。
**对青山**：🅑 四档语义可映射为青山的审批设置页（现只有整工具 allowAlways，审查判定"粒度过粗"）。**"granular=false 时自动拒绝"**这个语义尤其好——"关掉某类审批"不是"免审"而是"不容应该类操作"。
**青山现状**：部分。

### 3.2 审批决定枚举（ReviewDecision）

**是什么**：用户对审批请求的应答类型。
关键文件：`protocol/src/protocol.rs:4053-4088`。

**设计要点**：`Approved` / `ApprovedExecpolicyAmendment`（批准并改规则，下次免审）/ **`ApprovedForSession`**（本会话内同指纹请求自动放行）/ `ApprovedMcpPolicyAmendment` / `NetworkPolicyAmendment`（allow/deny 按域名）/ `Denied{reason}` / **`TimedOut`**（自动审批超时是独立枚举值）/ `Abort`（拒绝并让 agent 停手）。**Default 实现 = Denied**（protocol.rs:4090-4096）——fail-closed 写进类型系统。

**对青山**：🅐 全套可吸收。青山 G-1 要加"审批 120s 超时默认 deny"——Codex 的做法更进一步：超时不是错误而是显式 `TimedOut` 决定，且 oneshot channel 断开时 `unwrap_or(ReviewDecision::Abort)`（session/mod.rs:2706）——**任何异常路径都落到 Abort/Deny**。
**青山现状**：未实现（只有 approve/deny，无超时、无 session 级记忆）。

### 3.3 会话级审批缓存（remembered approvals）

**是什么**：`ApprovedForSession` 的实现。
关键文件：`core/src/tools/sandboxing.rs:40-62`（ApprovalStore：HashMap<String, ReviewDecision>，key 是**序列化的审批指纹**）、`sandboxing.rs:70-115`（with_cached_approval）。

**设计要点**：① 缓存 key 是命令/补丁内容的**指纹**（approvals.rs:733-737 还会带上 execpolicy 规则文件的 fingerprint——规则变了缓存自动失效）；② apply_patch 一次改多个文件，**每个文件路径单独存 key**，下次命中任一子集都可免审（sandboxing.rs:64-69 注释）；③ 缓存只在 SessionServices 生命周期内（会话级，不跨会话落盘）。

**对青山**：🅐 比青山的 allowAlways（整工具级、且按审查是无边界的）精细得多：**按"命令内容指纹"记忆，会话内生效，会话结束即失效**。
**青山现状**：未实现。

### 3.4 审批请求数据结构与流程

**是什么**：审批 = oneshot channel + 事件广播。
关键文件：`core/src/session/mod.rs:2620-2707`（request_command_approval）、`core/src/tools/approvals.rs:495-568`（request_approval 优先级链）。

**设计要点**：请求方把 `tx_approve` 挂进活动 turn 的 pending_approval 表，再广播 `ExecApprovalRequestEvent`（含 command、cwd、reason、可选的 amend 提案、available_decisions 列表——UI 据此渲染按钮，mod.rs:2669-2704）；应答方按 call_id+approval_id 找回 channel。审批优先级链（approvals.rs:521-541）：**Hook（配置自动决定）→ Guardian（自动审查器）→ User**。审批器（Guardian）独立超时会产生 `TimedOut`。

**对青山**：🅑 "审批请求是带 available_decisions 的自描述事件"——青山 UI 的审批卡可以直接抄这个结构（含 reason 与可选项，而非裸命令）。
**青山现状**：部分（有审批卡，无结构化 reason/decisions）。

---

## 四、compact 算法

### 4.1 触发条件：双硬线

**是什么**：auto-compact 由两条独立硬线触发，任一命中即压缩。
关键文件：`core/src/session/context_window.rs:104-109`。

**设计要点**：
1. **压缩预算线**：`auto_compact_scope_tokens ≥ auto_compact_limit + fallback_buffer`（预算可按 Total 或 BodyAfterPrefix 两种口径统计，context_window.rs:60-80；BodyAfterPrefix = 总量减去本压缩窗口的 prefill 基线，即"本轮压缩后新增的 token"）；
2. **模型窗口线**：`active_context_tokens ≥ context_window × effective_context_window_percent / 100`（context_window.rs:83-85，全窗口有效百分比）。
   另有一条软提醒线：`base_window_tokens_remaining ≤ reminder_threshold_tokens` 时注入一次性 TokenBudgetReminder（token_budget.rs:127-144），**每个压缩窗口只发一次**（state/auto_compact_window.rs:87-89 用 `claim` 原子防重发）。

**对青山**：🅐 双硬线 + 一次性软提醒三件套，青山 C-2 修完 8k 硬编码后正需要这套语义；"claim 一次性"防止重复注入提醒的做法直接可抄。
**青山现状**：部分（有阈值触发 compact，无双线、无一次性提醒）。

### 4.2 压缩执行流程

**是什么**：把整个历史交给模型生成交接摘要，然后**替换**历史。
关键文件：`core/src/compact.rs:245-400`（run_compact_task_inner_impl）。

**设计要点**（按执行顺序）：
1. **摘要 prompt 极简**（`prompts/templates/compact/prompt.md`）：只有一句"CONTEXT CHECKPOINT COMPACTION，为另一个 LLM 写交接摘要：进度与关键决策/约束与用户偏好/待办与下一步/关键数据与引用"——不是复杂模板；
2. **摘要前缀**（summary_prefix.md）："另一个模型已开始解决此问题……基于以下摘要继续，避免重复劳动"——压缩后第一条 user 消息的固定开场；
3. **新历史构成**（compact.rs:645-734）：保留的用户消息（见下）+ 摘要消息。**用户消息保留上限 20k tokens**（COMPACT_USER_MESSAGE_MAX_TOKENS，compact.rs:61），从最新往旧收集、装不下的最后一条截断（compact.rs:664-689）；
4. **mid-turn 压缩的注入规则**（InitialContextInjection，compact.rs:72-78）：turn 中压缩必须把初始上下文（world-state 截图等）插到**最后一条真实 user 消息之前**（模型训练时预期摘要在历史末尾）；turn 前压缩则不注入、下轮正常重注入（compact.rs:587-643 的四级 fallback 插入位置规则）；
5. 压缩请求本身失败重试时若报 **ContextWindowExceeded，从最旧开始逐条删除历史再试**（compact.rs:314-329，保前缀缓存）；
6. 完成后推进压缩窗口号、发一次性警告："多次压缩会降低准确性，尽量开新会话"（compact.rs:395-398）。

**对青山**：🅐 摘要 prompt、SUMMARY_PREFIX、**尾部用户消息保留（20k 上限、最新的优先、超限截断）**三个全部可直接吸收——青山的 compact 目前是全文摘要丢原文（审查 03 范畴），保留原始 user 消息是大幅提升点；🅑 注入位置规则需适配（青山是 system prompt 体系而非 initial context 重注入）。
**青山现状**：部分（D-5 修了 compact 丢注入；无尾部保留、无 prompt 模板）。

### 4.3 world-state 截图

**是什么**：压缩/新窗口时注入"世界状态"快照（模型指令、权限、工具清单、AGENTS.md、协作模式等 20 余类状态的合成渲染）。
关键文件：`core/src/session/world_state.rs:35`（build_world_state_for_step）、`core/src/compact.rs:97-106`（压缩时带着 world_state 重建初始上下文）。

**设计要点**：每 step 只在**状态变化时**重记录（turn.rs:376-378 `record_step_world_state_if_changed`）。
**对青山**：🅑 "把权限/工具/指令清单作为可再注入的状态块而非散落文本"是青山 ContextAssembler 可借鉴的组织方式。
**青山现状**：部分（AGENTS.md 注入已有，无状态化组织）。

---

## 五、context_window 管理

**是什么**：token 计数与阈值判定。
关键文件：`core/src/session/context_window.rs`（全文 121 行）、`core/src/state/session.rs:294-297`（get_total_token_usage）。

**设计要点**：
- **不做本地 tokenizer 估算做权威值**：以服务端返回的 usage 为准（`ServerObserved`），仅在恢复会话拿不到 usage 时用估算值占位，且一旦收到服务端值立即覆盖（auto_compact_window.rs:105-130：`ensure_server_observed_prefill_from_usage` 优先于 `set_estimated_prefill`，估算值永远盖不掉真实值）；
- 阈值判定集中在一个纯函数 `context_window_token_status_with_config`（context_window.rs:52-121），输出一个包含 8 个字段的状态结构（剩余量取"压缩预算剩余 ∨ 窗口剩余"的最小值，context_window.rs:88-94）；
- stream 中途断线拿不到 completed usage 时，`set_token_usage_full` 把用量直接标为窗口满（turn.rs:1447-1450）——**宁可提前压缩也不冒溢出风险**。

**对青山**：🅐 DeepSeek 流式响应同样返回 `prompt_tokens`，青山应改为"usage 权威 + 估算兜底"（现在 CtxUsage 是估算/常量制）；🅐 "拿不到 usage 就按满窗处理"的保守策略直接可抄。
**青山现状**：部分（8k 常量已修为 64k，仍非 usage 权威）。

---

## 六、状态持久化

**是什么**：三层持久化——rollout JSONL（会话内容）、state DB（SQLite 元数据）、thread-store（线程索引）。
关键文件：`core/src/rollout.rs`（转发层）、`rollout/src/recorder.rs`（2145 行，JSONL 追加记录器）、`rollout/src/state_db.rs`（SQLite）、`state/src/`（sqlite 封装 + migrations）。

**设计要点**：
- 会话 = 一个 append-only JSONL 文件（`sessions/` 目录按日期分片，归档进 `archived_sessions/`）；文件首行是 SessionMeta（含 cwd、来源、指令指纹），后续每行一条带序号的 ThreadItem；
- **resume = 重新读 JSONL 重建内存状态**（含恢复压缩窗口号与 window_ids，state/session.rs:247-253 restore_auto_compact_window——压缩计数器跨会话不丢）；
- 追加器与 UI 渲染解耦：JSONL 是唯一事实源，SQLite 只做索引/查询加速（state_db.rs）；
- 支持按 turn_id 截断 rollout（thread_rollout_truncation.rs，供"回退到某轮"用）；
- 列表/搜索走 reverse_jsonl_scanner（从文件尾反向扫，取最近会话 O(尾部) 而非 O(全文件)）。

**对青山**：🅑 append-only JSONL + header 外置 + seq 游标这套青山已有（D-1/D-3 修复后）；🅐 两个增量点：① **把压缩窗口计数持久化进 resume**（青山 resume 后压缩计数清零，长会话 resume 会过早/过晚压缩）；② 反向扫描取最近会话（青山 entries.json 全量读）。
**青山现状**：部分。

---

## 七、错误处理与重试

**是什么**：网络/流/鉴权三层重试体系。
关键文件：`core/src/util.rs:6-7,86-91`（backoff）、`core/src/client.rs:2016`（stream 入口）、`model-provider-info/src/lib.rs:27-29`（默认参数）。

**设计要点**（默认参数值）：
- **指数退避 + 抖动**：初始 200ms、倍率 2.0、抖动系数 0.9–1.1（util.rs:86-91）；
- 流级重试 stream_max_retries 默认 **5**；请求级 request_max_retries 默认 **4**（两者都可配但有硬上限，lib.rs:32-34）；流空闲超时默认 **300s**（lib.rs:27）——5 分钟无任何流事件才判死，不是靠 TCP 超时；
- 错误分类决定去向（turn.rs:574-606 + compact.rs:296-349）：`Interrupted/TurnAborted` → 直接中止；`ContextWindowExceeded` → 标记满窗/逐条删旧重试；`UsageLimitReached`（限流）→ 带 Retry-After 等待；其余 → 退避重试 N 次，每次发 `StreamError` 事件告知用户"Reconnecting... 2/5"；
- **401 鉴权恢复是专门状态机**（client.rs:2316-2376 PendingUnauthorizedRetry：刷新 token 后原请求重放，带 recovery_mode/recovery_phase 遥测）；
- **压缩请求与普通请求共用同一退避但独立计数**，且压缩失败不影响已生成的部分产物（OutputItemDone 逐条落历史，compact.rs:765-768）。

**对青山**：🅐 指数退避+jitter 直接修 LLMAdapter"重试无 jitter"；🅐 流空闲超时（DeepSeek 断流时青山现在靠系统超时，应该加显式 idle watchdog）；🅑 401 刷新重放对青山= DeepSeek key 刷新场景，规模可简化但"分类决定去向"的骨架值得抄。
**青山现状**：部分（有重试，无 jitter、无 idle 超时、无分类）。

---

## 八、TUI 架构（简要）

**是什么**：ratatui 终端界面。关键文件：`tui/src/insert_history.rs:61`（insert_history_lines）、`tui/src/app/history_ui.rs:24`（insert_history_cell）、`tui/src/bottom_pane/`（composer 及 30+ 子视图）。

**设计要点**：
- **历史区与活动区分离**：完成的对话作为"cell"逐行**写入终端回滚缓冲**（insert_history 不是内存列表而是向 terminal scrollback 打行），内存里只保留当前视口+composer——长会话不占内存；
- bottom_pane 是一个小状态机集合：chat_composer（输入态/历史翻阅/粘贴附件）、command_popup（斜杠命令）、file_search_popup（@文件）、approval_overlay（审批弹层）——审批到来时 composer 让位、取消后恢复；
- 所有审批/确认都以 overlay + available_decisions 渲染（见 3.4）。

**对青山**：🅓 终端实现细节不适用；🅒 两条交互思想可吸收：① "历史不可变、输入区独立状态机"；② 审批卡带可选按钮集（而非 approve/deny 两键）。SwiftUI 天然做到了前者。
**青山现状**：部分（SwiftUI 结构等价；审批卡升级见 3.2/3.4）。

---

## 九、🅐🅑 级可吸收设计汇总表（按建议优先级）

| # | 设计 | 来源（文件:行） | 级别 | 青山现状 | 对应青山问题 |
|---|---|---|---|---|---|
| 1 | 审批 fail-closed 写进类型系统：Default=Denied，channel 断=Abort，超时=显式 TimedOut | protocol.rs:4090；mod.rs:2706；protocol.rs:4083 | 🅐 | 未实现 | G-1 审批超时 |
| 2 | 会话级审批缓存：按命令指纹记忆、ApprovedForSession、多文件逐 key | tools/sandboxing.rs:40-115 | 🅐 | 未实现（allowAlways 过粗） | 审查 03/总账 Approval |
| 3 | compact 保留尾部用户消息：20k token 上限、最新优先、超限截断 | compact.rs:61,664-689 | 🅐 | 未实现 | compact 质量 |
| 4 | token 计数以服务端 usage 为权威，估算只做占位且可被覆盖 | auto_compact_window.rs:105-130 | 🅐 | 部分 | C-2 后续 |
| 5 | 拿不到流 usage 就按窗口已满处理（保守压缩） | turn.rs:1447-1450 | 🅐 | 未实现 | 溢出风险 |
| 6 | 双硬线触发压缩（压缩预算线 ∨ 模型窗口线）+ 一次性软提醒（claim 防重发） | context_window.rs:104-109；auto_compact_window.rs:87-93 | 🅐 | 部分 | compact 触发 |
| 7 | 指数退避+jitter（200ms×2.0，抖动 0.9-1.1）；流重试默认 5 次、空闲超时 300s | util.rs:6-7,86-91；model-provider-info/lib.rs:27-29 | 🅐 | 部分（无 jitter/无 idle） | LLMAdapter |
| 8 | 错误分类决定去向：中止/删旧重试/限流等待/退避重试 四分支 | turn.rs:574-606；compact.rs:296-349 | 🅐 | 未实现 | 健壮性 |
| 9 | 免审白名单禁含糊前缀（bash/sh -c 黑名单）+ 规则与审批档冲突时 fail-closed | exec_policy.rs:48-71 | 🅐 | 部分 | S1-1 体系化 |
| 10 | 命令执行三防：输出字节硬上限、IO 排空超时 2s（孙进程持管道）、进程组 kill+退出码 124 | exec.rs:61-92 | 🅐 | 部分 | G-2/G-4 |
| 11 | 插话（steer）队列：turn 中输入进队列、下轮采样前合并；压缩后插话延后 | input_queue.rs:66-188；turn.rs:306-507 | 🅐 | 未实现 | 无 inbox |
| 12 | needs_follow_up 单一循环条件（模型继续 ∪ 有插话），步数护栏只做兜底 | turn.rs:434,469-571 | 🅐 | 部分 | AgentCore 循环 |
| 13 | turn 前置压缩：开新 turn 前先检查窗口超限 | turn.rs:171,1053-1082 | 🅐 | 未实现 | 压缩时机 |
| 14 | 压缩窗口计数（window_number/ids）随 resume 持久化 | state/session.rs:247-253 | 🅐 | 未实现 | resume 后压缩 |
| 15 | 中断=贯穿全链路的协作式取消（每个 await or_cancel + 50ms 宽限杀进程组） | turn.rs:160；exec.rs:69；mod.rs:4567 | 🅐 | 未实现 | G-1 |
| 16 | compact 摘要 prompt（交接式四要点）+ SUMMARY_PREFIX 固定开场 | prompts/templates/compact/* | 🅐 | 未实现 | compact 质量 |
| 17 | 沙箱缺失时审批兜底公理："能强制沙箱才自动放行，否则问用户" | safety.rs:72-88 | 🅑 | 部分 | 审批公理 |
| 18 | granular 审批档：false=自动拒绝而非弹窗（关闭≠宽容） | protocol.rs:996-1024 | 🅑 | 部分 | 审批设置页 |
| 19 | WritableRoot 保护子路径（.git/hooks 等提权路径即使可写根内也只读） | protocol.rs:1120-1172 | 🅑 | 未实现 | 提权防护 |
| 20 | mid-turn 压缩的初始上下文注入位置规则（最后真实 user 消息前） | compact.rs:72-78,587-643 | 🅑 | 部分 | 注入语义 |
| 21 | 审批请求=自描述事件（command/cwd/reason/available_decisions） | mod.rs:2686-2704 | 🅑 | 部分 | 审批 UI |
| 22 | 审批指纹携带策略文件指纹（规则变更缓存自动失效） | approvals.rs:726-737 | 🅑 | 未实现 | 缓存失效 |
| 23 | world-state 状态化组织上下文块 + 变化时才重记录 | world_state.rs:35；turn.rs:376-378 | 🅑 | 部分 | ContextAssembler |
| 24 | rollout：压缩计数持久化 + 反向扫描取最近会话 | state/session.rs:247；rollout/reverse_jsonl_scanner.rs | 🅑 | 部分 | SessionLog |

统计：🅐 16 项，🅑 8 项。

---

## 十、三个最值得单独立项的设计发现

1. **"审批状态机的 fail-closed 是类型级而非逻辑级"（#1+#2）**：Codex 把 Default=Denied、超时=TimedOut、channel 断=Abort 全部做成枚举的构造路径，任何新代码路径想"忘了处理审批"都编译不过语义。青山 G-1 只计划了"120s 默认 deny"，照 Codex 抄可以把审批做成真正的状态机而非 if 分支。

2. **compact 不是"摘要替换"而是"摘要 + 尾部原文保留"（#3+#6）**：Codex 压缩后新历史 = 最近 20k tokens 的原始 user 消息（从新到旧、装不下截断）+ 交接摘要。摘要负责"任务状态"，原文负责"具体约束/数据"。这是青山 compact 质量最低成本的大升级。

3. **token 预算的"多源置信级"设计（#4+#5）**：服务端 usage > 估算占位（可被覆盖）> 断流时按满窗处理。三层置信让"窗口溢出"这类最难看的失败几乎不可能发生——青山在 DeepSeek 流式（有 prompt_tokens）上完全可以复刻。
