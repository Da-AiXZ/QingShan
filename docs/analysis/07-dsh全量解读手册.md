# dsh 全量解读手册（DeepSeek Harness 全库逐包解读）

> 生成：2026-09-05 · 分析员：dsh-full-read
> 对象：`repos/deepseek-harness/deepseek-harness-master/`（TypeScript monorepo，pnpm workspace）
> 方法：README + docs/architecture.md + docs/subsystems/*.md（50 篇）逐篇解读；核心模块（core/agent、core/session、shell、guard、subagent、jobs、compaction、schedule）精读源码。
> 规模：packages/ 下 **56 个类别目录、249 个包**（package.json 计数，已剔除测试 fixture）。
> 参数细节不重复：完整参数与默认值见《01-dsh参数全量对照.md》；本手册聚焦"是什么/怎么设计/为什么"。
> 价值分级：🅐 直接可复用（下一里程碑就该用）· 🅑 需 iSH/iOS 环境适配 · 🅒 暂不需要（备查）· 🅓 不适用（CLI/平台特有）

---

# 第一部分 总体架构：一切皆插件

## 1.1 框架与组合模型（Cordis）

dsh 构建在 [Cordis](https://github.com/cordiverse/cordis) 之上（`docs/architecture.md:9-13`）：**每个部件都是插件**——模型适配器、工具注册表、session 日志、agent 循环本身。插件向共享 Context 贡献服务（`ctx.xxx`）、类型化事件、可逆副作用（注册即 effect，卸载即回退）。没有需要打补丁的"特权核心"：扩展 dsh = 在旁边挂一个插件。

**运行时组合是分层 patch 叠加**（architecture.md:15-29）：

- **Profile**：命名的组合模板（`web`/`headless`/`sdk`/`sdk-minimal`/`acp`），列出叠加的 bundle；
- **Bundle**：Cordis 配置行的分发格式，包 package.json 的 `dsh.bundle` 字段指向自己的 `cordis.patch.yml`；
- **叠加顺序**：空入口 → 依序各 bundle 的 patch → profile 的 patch → 用户级 patch → `--patch` 覆盖；每行按 id 定位、整行替换或插入。
- `dsh --profile web --dump-config` 可打印实际启动树——**任何一行都可被用户 patch 替换**。

设计理由：把"产品=配置"做到极致，所有能力都可被下游（含模型自己，见 extensions/tool-cordis）替换或禁用；这也是 `sdk-minimal` 能存在的原因——一份 patch 就是完整 SDK 树，不带任何可选件。

## 1.2 事件三分域（架构第一决策）

| 域 | 代表 | 特性 |
|---|---|---|
| **Session 事件** | `turn/*`、`step/*`、`user/message`、`assistant/*`、`tool/*` | 追加式持久日志，"进模型就必须在日志里"（runtime invariant 断言） |
| **Agent 事件** | `agent/*`（created/status/inbox/pre-step/request/turn-stopping…） | 携带活 Agent 的实时扩展点，观察/拦截在途工作；waterfall 型需调 `next()` |
| **能力事件** | `fs/*`、`tools/*`、`telemetry/*` | 把策略和适配器挂到 seam 上，不导入循环 |

## 1.3 两个贯穿全库的类型模式（core.md:267-315）

1. **`…Map → derived-union`**：所有可扩展 sum 类型用"以 tag 为键的 interface + keyof 派生 union"，插件靠 **declaration merging** 加变体、不改属主包。五大 Map：`ContentBlockMap`、`MessageSourceMap`、`FinishReasonMap`（dsh-llm）、`TurnEndReasonMap`、`SessionEventMap`（dsh-session）。约定：switch 而非 if 链；对 SessionEvent **禁用 assertNever**（插件变体是合法未知值）。
2. **Branded IDs**：跨包传递的 id 都是编译期品牌字符串（`SessionId`/`ToolCallId`/`JobId`…），不可互换但运行时就是 string。原语在 `util/brand`。

## 1.4 Turn/Step 流水线（architecture.md:74-101）

**step = 一次模型请求 + 它调的工具；turn = 0..n 个 step。**

```text
turn/start
  claim 输入（next-step 全部 + turn 边界时一条 next-turn）
  组装 prompt sections + tool schemas
  → agent/pre-step        reject | enter(messages, startsRequestSeries?)
     step/start → user/message 落日志 → deriveMessages() 从日志导出历史
     agent/request → llm/stream → assistant/chunk* → assistant/message
     tool/call* → tools/pre-execute → tools/execute → tools/post-execute → tool/result*
     step/end
     工具欠请求 or 有 next-step 输入 → 下一步
  → agent/turn-stopping（串行，可 steer 反对）
turn/end
```

关键设计：**模型可见 = 已记日志**。`request/header`（完整请求信封快照）也落日志，故每次请求都是日志的纯函数；未经循环的重放/重建可与缓存逐位一致。

## 1.5 包关系地图

```text
dsh CLI（launcher）
 └─ Profile（web / headless / sdk / sdk-minimal / acp）
     └─ Bundle 叠加层
         ├─ dsh-base（共享第一层：模型适配器、工具、持久化、沙箱/审批策略、
         │            settings、credentials、telemetry —— 一切 base-backed profile 的底座）
         ├─ dsh-web-app / dsh-headless / dsh-sdk-app / dsh-acp-app（各自的增量层）
         └─ dsh-sdk-minimal（例外：自成一体，不叠 dsh-base；最小完整树 =
              llm + llm-deepseek + session-log-deepseek + sandbox-local + subprocess-local
              + terminal + terminal-bash + fs-local + agent-loop + session + jsonl 持久化 + JSON-RPC server）

核心脊柱（core/）:
  agent-loop ──实现──> Agent 接口 <──注册── agent（ctx.agents）
     │ 使用                       │ 依赖
     ├─ session（ctx.sessions，事件日志）←─ scope（每 agent 作用域原语）
     ├─ system-prompt（ctx.systemPrompt，prompt 段+工具 schema 组装）
     └─ tools（ctx.tools，注册表+守卫执行管线）

能力 seam（围绕脊柱，全部可选）:
  llm ──> llm-deepseek / llm-pi-ai / llm-retry / token-meter
  shell ──> bash-local / bash-sandbox / pwsh-* ；tool-bash / tool-bash-persistent
  subprocess ──> subprocess-local（进程组/溢写/凭证清洗/DSH_* 环境命名空间）
  terminal ──> terminal-bash（PTY 后端）；tool-terminal（6 个持久终端工具）
  fs ──> fs-local / fs-sandbox / fs-observation-policy；tool-fs / tool-fs-search / tool-str-replace-editor
  sandbox ──> sandbox-local（bwrap/landlock/seatbelt/win-ACL）/ sandbox-policy
  subagent ──> spawn/fork-in-process / acp / codex / claude-code / dsh-sdk；tool-subagent(+control)
  compaction / jobs / schedule / goal / plan / todo / skill / web / mcp / lsp / code-runtime
  / spill / workflow / webhook / interaction(approval/user-questions/commands) / hooks / extensions

基础设施:
  session-persistence(-jsonl) / session-projection(-cache) / session-query(-sqlite)
  / session-title* / session-stats / session-turn-outline / session-telemetry(-otel)
  / settings(-file) / credentials(-local) / storage(-json/-sqlite/-domain) / attachment(-local)
  / workspace / context(agent-instructions/file-reference/session-reference/time-context/tmux-context)

表面层（CLI 特有，青山大部不适用）:
  host(webserver/frontend/directory-picker) + api(gateway/remotes/controllers) + client(50+ ui-* 包)
  + acp + sdk(client/protocol/server) + boot(app-boot/cmdline) + bundle
```

---

# 第二部分 逐包解读

## 2.0 根目录与 docs

- **根 README**：`npx @deepseek-ai/dsh web` 一键起 Web UI（127.0.0.1:3080）；developer preview，会有破坏性变更。
- **docs/**：架构文档群——architecture（总图）、agent-lifecycle（时序）、tool-execution-pipeline、capability-seams、event-producer-consumer（事件生产者/消费者全表）、config-catalog、persistence-catalog、tool-catalog、module-graph、defensive-patterns、cookbook/（加包/加工具/加适配器指南）、subsystems/（50 篇子系统规格）。**这套 docs 本身就是青山最值得借鉴的"架构文档怎么写"范本**：每篇都包含机制、类型全文（从源码生成、`verify-cordis-catalog` 保证新鲜）、设计决策链接（`.agents/notes/implemented/...` 决策笔记）。

---

## 2.1 core/ —— 脊柱

### core/scope 🅒（库原语）
- **是什么**：作用域注册原语——`ScopeKey`（不透明对象身份）+ `scopeTarget()` 载体 + 按作用域过滤的事件分发。
- **机制**：dsh-scope 是唯一无依赖库包，位于 session/system-prompt 之下避免循环（core.md:20）。事件声明 `this: Scoped<Agent>` 即编译期强制作用域过滤。
- **设计理由**：让"一次注册"同时表达 per-agent 可见性与共享生命周期；循环用活 Agent 对象当自己的 key。
- **青山现状**：未实现（概念可借鉴：每 agent 独立工具/监听器集合）。

### core/session（ctx.sessions）🅐
- **是什么**：事件溯源 session 存储——追加式 `SessionEvent` 日志是唯一事实源，模型历史从日志*派生*。
- **核心机制**（docs/subsystems/session.md）：
  - 12 个核心事件：`turn/start|end`、`step/start|end`、`user/message`、`assistant/chunk|message`、`tool/call|result`、`request/header|context`、`session/end-seed`。
  - **Surface 机制**：只有三类消息产生型事件（`SurfaceEventType`）可进"表面"（派生历史的唯一来源）；`surfaceOp: 'append' | {op:'replace',start,end}` 声明如何进入表面——**replace 是 compaction 的实现方式**：旧节点被"阴影化"而非删除，日志无损、重放安全（session.md:287-296）。`sourceEventSeqs` 记录派生来源（如 assistant/message 引用其 chunk seqs）。
  - `append()` 在写入点同步校验 JSON 可序列化（BigInt/函数/循环引用等直接抛错，session.md:500-512）——坏事件永远进不了日志。
  - `deriveMessages()` 缓存 + 深冻结：每个表面节点只投影一次，O(新节点)；空内容 assistant/message 跳过（max-tokens 截断的 usage 载体不进 provider 转录）。
  - **`session/end-seed`**：seed（resume/fork/回放）构造后立即追加，是"本生命周期写从哪开始"的持久投影；解决"seed 历史与活工作字节相同、无法区分打开的括号是死是活"的问题（session.md:627-633）。
  - **`TurnEndReasonMap`**：completed / aborted{cause} / blocked / error{LlmFailure} / max-tokens（任何一步截断则整轮标记，截断事实压过后续续跑）/ **interrupted**（崩溃恢复专用，活循环永不发出）。
  - **fork API**：`ctx.sessions.fork(source, boundary?)` 任意稳定边界分叉，拒绝在未闭合 turn 内剪断；fork 子会话带 `parentSession`+精确 `inheritedEventCount`。
- **设计理由**：一切下游（回放、fork、遥测、UI、持久化）都从同一条流导出——"Model-visible means logged" 不变量让任何请求都可从日志重建。
- **关键参数**：格式版本 `SESSION_FORMAT_VERSION`；无兼容承诺（未发布格式），加载时拒绝不认识的旧事件而非猜。
- **青山现状**：已实现（核心事件日志+派生）。**未实现：surface/replace 投影、sourceEventSeqs、session/end-seed、max-tokens/interrupted 终态区分**。

### core/agent（ctx.agents）🅐
- **是什么**：Agent 接口、活注册表、initiator 作用域、`agent/*` 事件词汇。
- **核心机制**（core.md:53-205）：
  - **Inbox 双通道**：`InboxTarget = 'next-turn' | 'next-step'`——两条有序待处理消息列表。`claim(target)` 取"全部 next-step + turn 边界时一条 next-turn"；纯删除式 splice，循环另行逐条发 claimed 通知。
  - **统一 `send(message, target, wakeup)`** + 三个固定预设别名：
    - `followup()`：排队为下一个普通 turn 并唤醒；
    - `steer()`：最近 step 边界插话（idle 则开 turn）；
    - `inject()`：**不唤醒**的模型可见上下文注入，等下次 followup/steer 唤醒时在 pre-step 领取。
  - **`cancel(cause, {keepInbox})`**：cause ∈ user/parent/hook/disposed，落入 turn/end 的 `{kind:'aborted', reason}`；keepInbox 保留排队工作。
  - `whenIdle()`、`runMaintenance(task)`（从真 idle 相位跑一个非 turn 维护任务，如标题生成）。
  - **事件**：`agent/pre-step`（唯一请求派生前 waterfall，可 reject 或改写消息批，空 enter 仍记一个 0 step 的 turn）；`agent/request`（换调用配置，不能改消息）；`agent/request-error`（返回 `{kind:'retry'}` 接管恢复）；`agent/turn-stopping`（串行；反对=steer，数据裁决——收件箱重读后有 steering 就继续，没有就关）；工具结果带 `concludesTurn` 也可数据化提前结束 turn。
  - 创建事务：`createAgent(ownerCtx, options)` 的 `setup(agentCtx)` 在两个 id 都未发布时组装 agent 专属世界，setup 抛错即回滚、不发布。
- **设计理由**：三通道分离解决"插话打乱 turn 边界"经典难题——followup 是新回合、steer 是步内纠偏、inject 是静默上下文；inject 不唤醒意味着 cron 提醒等可先囤积、由真消息一并带入。
- **青山现状**：部分实现（单通道队列）。**未实现：next-turn/next-step 双通道、steer/inject 语义、pre-step/turn-stopping、runMaintenance、keepInbox**。

### core/agent-loop（ctx.agentLoop）🅐
- **是什么**：Agent 接口的唯一具体实现（默认产品循环），以 factory 注册到 `ctx.agents.setFactory()`。
- **核心机制**：每驱动跑在 `ctx.agents.withInitiator()` 内（进程内因果归因）；配置式声明 agent 条目（启动即建），失败发 `agent-loop/config-start-failed` 供缓冲方拒收；resume 时对存储日志尾部未闭合 turn 追加 `interrupted` 关闭（崩溃恢复）。`maxParallelToolCalls = 10`（constants.ts:6）。
- **设计理由**：循环本身可换（消费者只依赖 agent 包）；循环不拥有持久化 checkpoint（那是 session-checkpoint-policy 的事）。
- **青山现状**：已实现（基础循环+并行工具）。

### core/tools（ctx.tools）🅐
- **是什么**：作用域化工具注册表 + 守卫执行管线（`tools/pre-execute → execute → post-execute` 三个 waterfall）。
- **核心机制**（tools.md）：`ToolDefinition` = `ToolSchema` + 强制 canonical `output` 声明 + `execute` + `timeoutMs`/`isConcurrencySafe`（调度元数据）+ 可选 `finalizeContent`/UI presenters。`schemas()` 用显式**白名单**构造模型可见 schema，执行字段永不泄漏进请求。`defineTool` 类型化 DSL 构造；`tools.restrict()` 按作用域收窄（可见性=可执行性，一处收窄两处生效）。
- **设计理由**：执行管线是 waterfall 意味着超时/沙箱/审批/溢写/重复提醒全是**外挂包装器**而非循环内建——青山加任何策略都不该改循环。
- **青山现状**：部分实现（注册表+执行）。**未实现：pre/post-execute waterfall、canonical output 声明、restrict**。

### core/system-prompt（ctx.systemPrompt）🅐
- **是什么**：prompt 段与工具 schema 组装注册表。段按作用域/顺序贡献，`plan:policy`、`deployment:persona` 等都是段。青山现状：部分实现。🅐

### core/agent-tool-presentation / core/agent-default-model 🅒
- 前者：一个 agent 的工具以 PTC（代码模式）/原生/两者呈现的选择器；后者：共享默认模型选择。青山暂不需要（单一适配器）。

---

## 2.2 session/（session 域全家）

### session-persistence（ctx.sessionPersistence）🅐
- **是什么**：日志持久化的抽象 seam：`create/open/stat/list/export`，`open/create` 返回每会话 `SessionHandle`（`read/append/flush/close`），**单写者所有权**；无平行持久化事件类型——存的就是原日志。
- **设计理由**：句柄而非 id 寻址 = 强制串行化；backend 可自选编码只要 `read()` 逐位还原。
- **青山现状**：已实现（自有持久层）。

### session-persistence-jsonl 🅐
- JSONL 后端：默认"打包 chunk 行"编码（chunk 合行存储），逐位还原契约不变。**未实现（青山）**：chunk 打包、`session/flush` 检查点。

### session-checkpoint-policy 🅐
- **是什么**：语义化持久检查点——在每次模型请求前与工具副作用前落盘，而非 turn 边界（loop 不等 flush，消费者自己 flush）。
- **设计理由**：iSH 式随时被杀环境里，"请求前+副作用前"是最小丢失窗口。青山：未实现，**建议 M 系列优先采纳**。

### session-log-deepseek 🅐
- **是什么**：**官方 DeepSeek LLM API 的"增量无损 session-log 请求扩展"**——把整条日志增量地随请求发给官方 API 的私有 wire 扩展（配合 deepseek-llm-api-extensions 的附加字段注册表）。
- **设计理由**：服务端可见完整日志 ⇒ 服务端可做更好的缓存/截断；这是 DeepSeek 自家 API 特权通道。青山现状：未实现（若用官方 API 可白拿收益）。🅐

### session-projection（ctx.sessionProjections）🅐
- **是什么**：投影 seam——域插件注册纯"投影单元"，框架统一订阅 `session/event` 一次、增量折叠所有单元；消费者 `stateOf()` 读类型化状态，客户端 `snapshot()` 拿裁剪视图。强约束：宿主读取者**激活期必须注入此服务，缺失即显式失败**。
- **设计理由**：把"n 个插件各自订阅日志"收敛为一次订阅 n 个折叠器；plan/todo/goal/schedule/sandbox-mode/terminal 状态全走它。
- **青山现状**：未实现（青山各自手写状态）；建议以轻量形式引入。

### session-projection-cache 🅒 / session-stats 🅒 / session-turn-outline 🅒
- 投影缓存（写回节流）、全会话计数/墙钟统计、整日志轮次大纲——UI/检索向，暂不需要。

### session-title(-llm/-first-prompt/-all-prompts) 🅑
- **是什么**：最新胜出的持久标题状态 + 异步 LLM 标题 provider（两种策略：首条消息 / 全部用户消息），经 `runMaintenance` 在 idle 生成。青山：未实现；维护任务模式值得抄。🅑

### session-query(-sqlite) + tool-session-query 🅒
- 会话语料查询（live 优先语料、trace、过滤）+ SQLite FTS5 全文索引 + 模型可见的历史搜索工具（工作区授权门）。暂不需要（单设备会话量小），M7 备查。

### session-telemetry(-otel) 🅒
- 遥测 seam：捕获点+投影+脱敏 waterfall+最小 backend 契约；"harness 的职责止于 emit()，批处理/重试归 SDK"。OTel 后端为示例 provider。暂不需要。

---

## 2.3 shell/ —— 执行域

### shell/shell（ctx.shell）🅐
- **是什么**：bash 执行器抽象 seam（一个 context 只允许一个实现）。
- **核心机制**（shell.md）：**request/spec 分离**——模型/插件面 `ShellExecRequest`（可选字段）经 `resolve()` 填默认+钳制为 `ShellExecSpec`（必填）再执行。`ShellRunResult` 各结果**正交独立**：`timedOut`/`aborted`/`signal`/`exitCode` 各是各的字段——"进程可以既超时又 exit 0（trap 了信号）"，单一融合 deadline 保证 timeout 与 abort 只报 first-cause。`CollectedOutput` 截断时 text 是**尾部**、完整流落溢写文件。
- **设计理由**：显式优于隐式的包边界规则；正交结果防"被杀的运行被读成成功"。
- **青山现状**：已实现（对标）。

### shell/bash-local / pwsh-local 🅐（bash）/ 🅓（pwsh）
- 本地子进程实现；ENV_OVERRIDES：`NO_COLOR=1, TERM=dumb, PAGER=cat, GIT_PAGER=cat`（模型友好终端）；`DSH_*` 环境命名空间见下。bash 侧青山已实现。

### shell/shell-env（ctx.shellEnv）🅐
- **是什么**：工具无关的 `DSH_*` 托管环境注册表。每次模型 shell 调用重建快照：执行器**先剥除环境中的所有 `DSH_*`**，再合并注册表快照（在普通 env 之后合并，普通 env 无法顶替托管事实）。
- **设计理由**：过时事实不能从 harness 进程继承；插件可 effect 化注册额外事实。
- **青山现状**：未实现（青山直接注入固定变量）；建议引入命名空间概念。

### shell/bash-sandbox / pwsh-sandbox 🅒
- 消费 `ctx.sandbox` 的受限执行器：每命令套沙箱，结果携带 `ShellSandboxInfo{mode, denied, enforcement, runnerFailed}`——**命令失败与策略拒绝可区分**。runner 失败=前台抛 `SANDBOX_UNAVAILABLE`（fail-closed）。青山不需要 iOS 内沙箱（iSH 本身是容器），🅒 备查其"事实报告"模式。

### shell/tool-bash 🅐
- 模型面 bash 工具：可选 `run_in_background`（默认 true，后台无超时）、`sandbox_permissions`+`justification` 一次性放宽（须 `ctx.approval` 批准该次调用）。青山已实现前台/后台。

### shell/tool-bash-persistent 🅐
- **是什么**：owner 隔离的持久 bash 工具，基于 PTY 服务（dsh-terminal）。
- **机制**（01 已详）：单命令墙钟 300s，**超时重置整个持久 shell**；返回截 16k 字符附 `<response clipped>`；25ms 轮询完成标记；scrollback 按 1000 行分页回读。青山已实现 PersistentShell。
- **未实现（青山）**：超时整体重置、scrollback 分页回读、`parseExitStatus` 的 `[exit code: N]`/`[killed by signal: X]` 标记反转共享契约。

### shell/tool-pwsh(-persistent) 🅓 Windows 特有。

### jobs/（ctx.jobs）🅐
- **是什么**：通用后台任务注册表——长任务身份、owner 隔离、轮询、取消、完成监听。
- **核心机制**（jobs.md）：`JobId = <kind>-N`（品牌 id，访问控制靠 owner 授权不靠 id 保密）；`JobStart{kind,label,owner?,run()}` → `JobHooks{cancel,done,readOutput?}`；`done` 在**释放资源后**才 resolve；`JobSnapshot.reported` 抑制重复完成通知（teardown 层每层省一次模型请求）。`JobKindMap` 可合并扩展（内置 bash、subagent）。工具：`job_output / job_list / job_kill`。
- **设计理由**：bash 后台、subagent、workflow 等所有长活共用一套身份与控制——工具只需把 `ShellProcess` 适配成 `JobStart`。
- **青山现状**：未实现（青山后台 bash 自管）。**🅐 建议 M7 采纳：run_in_background/job_output/job_kill 一体化**。

### terminal/（ctx.terminals + tool-terminal）🅑
- **是什么**：持久 PTY 会话 seam——owner 隔离 id、后端注册、交互式 send/read/signal/awaited 清理。
- **机制**：6 个模型工具 `terminal_open/send/read/signal/close/list`；`TerminalWaitReason = stdin_read | inferred_idle | timeout | session_exit`（send 为何返回与顶层 shell 存活正交）；后端 terminal-bash 在 win32 上切换 pwsh 方言。
- **与 tool-bash-persistent 的关系**：persistent bash 是"一条命令"语义包装 PTY；tool-terminal 是"多个命名会话"全控制面（vim/交互程序场景）。
- **青山现状**：未实现；iSH 可用 `script`/pty 方案适配。🅑 备查。

---

## 2.4 llm/

- **llm（dsh-llm）** 🅐：provider 无关服务 seam + 对话词汇（Message/ContentBlock: text|reasoning|image|tool-call|tool-result、StreamChunk、FinishReasonMap）+ 适配器契约 + 共享 assembler。`reasoning` 块与可见文本区分。青山已实现（对齐）。
- **llm-deepseek** 🅐：chat-completions 适配器；`apiKeyEnv: DEEPSEEK_API_KEY`，`defaultContextWindow: 1_000_000`，`streamIdleTimeoutMs: 172_800_000`（48h，sdk-minimal 配置）。青山已实现 DeepSeek 适配。
- **deepseek-llm-api-extensions** 🅐：官方 API 附加请求字段的**注册表**（session-log-deepseek 等通过它声明 wire 扩展）——扩展点自身是插件可组合的。
- **llm-retry** 🅐：provider 路由的重试策略；失败经 `agent/request-error` waterfall，plugin 可接管。
- **token-meter（ctx.tokenMeter）** 🅐：回放感知的 token 计量——`logRevision` + 基线锚 + surfaceDeltaTokens + 逐节点定价；compaction 的压力判定全靠它。青山未实现，**🅐 压缩功能前置依赖**。
- **llm-pi-ai** 🅒：pi-ai 背书的设计验证孪生适配器。
- **plugin-package-inventory-deepseek** 🅒：官方 API 请求携带插件包清单（清单遥测）。

## 2.5 guard/ —— 循环守卫（青山此前漏掉的重点）

### guard/repeat-tool-reminder 🅐（重要发现）
- **是什么**：advisory 重复调用检测器——**只提醒、不否决、不改写**。
- **核心机制**（guard/repeat-tool-reminder/src/index.ts）：
  - 配置：`thresholds` 默认 `[3,5,8]`（空/非整数/<2/重复 → **加载期 fail-loud**）、`include`/`exclude` 通配符模式（`exclude:[mcp_*]` 在无 MCP 部署也合法）、`argumentsPreviewChars` 默认 500。
  - 检测键：参数 **deep key-sort 规范化后 JSON.stringify**——属性顺序不同视为相同；链键始终用**完整**规范串，仅提醒文本截断（`… (+N more chars)`）。
  - 升级话术：第一阈值→gentle（"analyze the previous result…try a different approach"）；后续阈值→detailed（点名工具/连续次数/参数）。键控 `thresholds[0]` 而非字面 3。
  - 注入方式：`tools/post-execute` 决策中 prepend 一条 `{kind:'plugin', plugin:'repeat-tool-reminder'}` 来源的 user 消息——**source 标签是载荷**（无标签会渲染成用户 prompt）。
- **设计理由**：检测和呈现分离；advisory 不抢模型自主权；规范化让"参数顺序差异"不成漏网。
- **青山现状**：未实现。**🅐 最高性价比之一：几十行逻辑，直接抑制循环烧钱。**

### guard/timeout-policy 🅐
- **是什么**：协作式工具超时执行器（`tools/execute` 包装器）。
- **核心机制**（guard/timeout-policy/src/index.ts:52-77）：工具声明 `timeoutMs` 且承诺尊重 `exec.signal`；包装器 `deadline()` 派生新信号**临时替换 exec.signal**，finally 恢复上游信号（post-execute 监听者永远看不到已中止的超时信号）；若自己的定时器先触发（用 `TOOL_TIMEOUT` code 作用域化判定，防外层 deadline 误判），把工具自己的 abort 结果替换为结构化 `TOOL_TIMEOUT` isError 结果。
- **设计理由**：不竞速、不抛弃工具 promise——等工具自行到达 quiescence 再替换结果；分类 code 让重试/沙箱插件可路由。
- **青山现状**：未实现（各工具自带超时）；🅐 统一收口到管线层。

---

## 2.6 compaction/ —— 上下文压缩（青山 M7 核心）

- **compaction（seam）** 🅐：`ctx.compaction`；向 `SessionEventMap` 合并 `compaction/start|summary|end` 三个 **log-only** 事件（锁、摘要、选中范围、被阴影 seqs、token 数、模型调用）。摘要本体不走 SurfaceEventType 扩展，而是普通 `user/message` + `surfaceOp:{op:'replace',start,end}`——**全库唯一执行表面替换的机制**。
- **compaction-basic** 🅐：token-meter 驱动的压力判定（`thresholdRatio` 触发、`retainRatio/retainTokens` 保留策略）+ LLM 摘要后端；`modelPolicies` 可按 provider/model 覆盖；`auto` 开关；**overflow 重试**：摘要后仍超窗则按 `CONTEXT_WINDOW_EXCEEDED_CODE` 再压（`compactionRetries`/`maxOverflowRetries`）；`summarize()` 是唯一子类钩子，回放与持久变更策略固定。
- **compaction-tool-result-pruner** 🅐：**无模型、回放安全的 head/middle/tail 裁剪**——专剪工具结果表面节点（压缩的零成本第一档）。
- **command-compact** 🅒：`/compact` 人工命令。
- **设计理由**：压缩=表面投影替换而非日志删除 ⇒ 任何时刻可从完整日志重建任何历史版本；压力判定独立成 token-meter 使策略可测。
- **青山现状**：未实现。🅐 M7 主菜：建议先抄 pruner（无 LLM）再抄 basic。

---

## 2.7 subagent/ —— 委派与多 agent（重要发现）

- **subagent（seam，ctx.subagents）** 🅐：**命名 provider 注册表**（与 bash 的单实现相反，多个 provider 并存）。能力发现双路：start-time 静态 `SubagentCapabilities{agentOptions,outputSchema,depthLimit,toolFilter,persona}` 缺即**响亮拒绝**（`UNSUPPORTED_CAPABILITY`，绝不接受-然后-忽略）；continuable 走 `prepareContinuable` 方法存在性=能力（TS narrowing）。
- **一次性委托**：`SubagentStartRequest{label,prompt,parent,signal,outputSchema?,maxDepth?,toolFilter?,persona?}`；`signal` 是启动前后唯一取消通道。outputSchema=对象根 JSON Schema，成功子代理经强制捕获工具返回结构化值。toolFilter=子代理创建窗内的 scoped `tools.restrict()`（prompt 消失+执行拒绝一体）。
- **Continuable 子代理 + Activation**（subagent.md:122-168）：持久 child Session ⇄ 至多一个进程内 **Activation**（child Agent 常驻期），可执行多个 FIFO turn；状态 running/waiting（仍有未处置子代）/settled（全部子代已处置→释放 AgentHandle）。**Agent inbox 是唯一队列**：`sendMessage` 对 running=steer 最近 step、waiting=唤醒再 steer、无 Activation=冷 resume 再 steer。**权威=精确活发送者**：只许直接父↔直接子，兄弟/跨代/自指一律拒绝。`interrupt(authority)` = `cancel(cause,{keepInbox:true})`，不等待静默；parked FIFO 由下一次 send 唤醒。
- **后端**：spawn-in-process（全新子代理）、fork-in-process（父日志前缀为 seed）、in-process-driver（共享驱动）、acp / codex / claude-code（跨产品子代理）、dsh-sdk（独立子运行时）。fork 特例允许 tool 时委派在父 turn 打开时做 completed-prefix 裁剪。
- **工具**：`tool-subagent`（per-provider `subagent` 委托，provider 未注册时工具延迟注册）、`tool-subagent-control`（全局 `send_message`、`interrupt_agent`、`list_agents`——持久目录）。
- **设计理由**：委派=能力而非循环特性； continuable 让"多轮子代理"复用 inbox/FIFO/steer 全套原语，零新增队列。
- **青山现状**：未实现。🅐 spawn-in-process 一档即可起步（复用青山自己的 createAgent），continuable 语义照抄。

---

## 2.8 fs/ 与 storage/、attachment、spill

- **fs（ctx.fs）** 🅐：文件系统 seam——文本 IO + 可选版本守卫原子变更 + `fs/*` 策略事件。fs-local 本地实现；fs-sandbox 按每次调用沙箱模式拒绝/围栏写入。
- **fs-observation-policy** 🅐：**无服务 API 的策略插件**——纯靠裁决 `fs/*` waterfall 追加"观察态、read-before-edit、版本守卫写"（stale 编辑失败）。移除它工具不坏——工具调 ctx.fs 并派发事件，从不调策略方法。**设计范本：策略与机制解耦**。青山：未实现（read-before-edit 值得抄）。
- **tool-fs（read/write/edit）** 🅐、**tool-fs-search（glob/grep，@vscode/ripgrep 打包二进制）** 🅑、**tool-str-replace-editor（view/create/str_replace/insert 行编辑）** 🅒。青山已有文件工具；ripgrep 在 iSH 有 ARM 二进制可行性，🅑。
- **storage/（ctx.storage + storage-domain + json/sqlite 后端）** 🅒：一切非 session 日志的持久化：hub 是"名字→backend 表"（不做 IO），data form 拥有语义（schema 校验 KV 域、发事件）。青山暂不需要。
- **attachment(-local)** 🅑：内容寻址（sha256 前缀）不可变附件存储；**先持久后落事件**——事件与 ImageBlock 只含引用，绝不含 base64/临时路径。设计规则：`imageHostPath()` 返回的位置必须经当次 execution 读取（不缓存路径）。青山：未实现；多模态时按此模式适配沙盒容器路径。🅑
- **spill/（ctx.spillStore + spill-policy + spill-local）** 🅐：超长工具结果 → `tools/post-execute` 策略替换为"保留预览+溢写文件路径"（头部预览+完整文件落私有会话目录）。唯一服务操作 `saveText`。**青山此前不知道**：这是 64KB 输出上限之外的通用兜底。🅐

## 2.9 interaction/ —— 人机交互（重要发现）

- **user-approval（ctx.approval）** 🅐：审批 seam——`approval/request` answerer waterfall + log-only 审计对（`approval/asked`/`approval/decided`）+ 每会话 ask/never 策略。**closed、fail-closed**：只有 `allowed-once` 放行且仅限被问的那个动作。沙箱一次性放宽（bash 工具）经它批准。青山：未实现；M 系列"危险命令确认"直接照抄此形状。🅐
- **user-questions + tool-ask-user** 🅐：`ask_user_question` 工具；`AskUserQuestionIntent` 按种类标注呈现意图，**只改呈现不改协议**（不认识 tag 的 UI 渲染通用选项列表）。青山：未实现；🅐 简单直接。
- **commands（ctx.commands）** 🅒：人类命令注册表（UI 直派发，不经模型 turn）。
- **permission-presets** 🅒：把 sandbox/mode + approval/policy 两旋钮捆成命名预设（workspace-write/danger-full-access），只记意图、写穿各自规范 setter。

## 2.10 schedule/ —— 会话内定时器（青山此前不知道）

- **schedule** 🅐：**agent 作用域的持久 after/at/every 提醒**，落在 session 事件日志上（`schedule/change` 事件 + 投影）；`every_seconds` 最小 **5 分钟**；创建即规范化为 RFC 3339 UTC `scheduledAt`。
- **机制**（schedule/schedule/src/index.ts:36-60）：只挂 **root agents**（`ctx.agents.roots().includes(agent)`）；每 agent 一个 `ScheduleRuntime`；agent 转 **idle** 且日志有 schedule/change 时 `requestDrive()`——提醒以普通 user/message（带专门 framing 渲染）回到原会话开新 turn；`MIN_EVERY_INTERVAL_SECONDS` 常量导出。
- **设计理由**：定时器状态=日志事件 ⇒ resume 后仍在；"提醒不唤醒、等 idle 驱动"避免与在途 turn 竞争。
- **青山现状**：未实现。🅐 青山"提醒/计划"能力（M7 候选）直接对标。

## 2.11 plan / todo / goal —— 任务态三件套

- **plan-mode** 🅐：**软引导**——`plan/mode` 是 log-only 整值替换事件（持久+可回放、不进模型转录）；激活时贡献 `plan:policy` prompt 段 + `exit_plan_mode` 工具 + `/plan` 命令 + **用户审阅退出**。执行限制由沙箱/审批独立配置，plan 包不读写它们。青山：未实现；🅐。
- **todo（tool-todo）** 🅐：`todo_write` **整列表快照**（last-write-wins，无 id/优先级/activeForm——故意极简）；三态 pending/in_progress/completed；事件+回放投影+不变量伴随包。青山：未实现；🅐。
- **goal/** 🅒：同会话目标——`GoalRef{id,revision}` CAS 变更；持久相位 active/paused/blocked/complete（blocking 是唯一"被问题停下"持久态，带 kebab code）；goal-round-driver 竞态围栏续跑轮次；工具 get/create/update_goal。暂不需要，M7 备查。

## 2.12 skill/ 与 mcp/、web/、lsp/、code-runtime/

- **skill（ctx.skills + tool-skill + skill-filesystem + skill-badge）** 🅑：技能 provider 注册表（host+per-scope 分层合并）；技能=可选指令非会话事件；`skill` 工具加载后作为注入上下文进下一步。文件系统 provider 扫描技能目录；badge 提供内置技能。青山：未实现；🅑（目录约定可直接抄 SKILL.md 形态）。
- **mcp/mcp-client** 🅑：连接 MCP 服务器、把其工具注册上 `ctx.tools`（`dsh-mcp-client 0.0.1` 客户端身份）。青山：未实现；iSH 跑 stdio MCP server 可行但重。🅑 备查。
- **web/（ctx.web + tool-web + 4 providers）** 🅑：一个 seam 两操作（web_search/web_fetch）——"并行方法对是故意的"；providers：deepseek（Anthropic 兼容 API 原生搜索）、exa、perplexity、fetch-http（匿名公共 HTTP）。青山：未实现；iOS 网络受限+隐私，🅑。
- **lsp/（ctx.lsp + lsp-stdio + tool-lsp）** 🅒：四个封闭语义查询（goToDefinition/findReferences/goToImplementation/hover）；零基 UTF-16（协议）↔ 工具层一基转换。暂不需要。
- **code-runtime/（ctx.codeRuntime + worker-thread 后端）** 🅒：跑模型写的程序、绑定宿主 async 函数、回报打印+返回值；experimental/code-runtime-python 为 CPython 子进程后端。暂不需要。

## 2.13 hooks/ —— Claude Code / Codex 桥

- **hook-protocol** 🅑：共享 wire 协议——matcher 引擎、stdin/exit-code/stdout 编解码、多 hook 合并、`hook/invoked|result` log-only 事件对（handlerId 关联）。
- **hooks-claude-code / hooks-codex** 🅑：把对方的 hooks.json 配置跑在 dsh 拦截 seam 上（UserPromptSubmit/PreToolUse/PostToolUse/Stop 天然 turn 内封闭；SessionStart 上下文进 inbox 等唤醒）。
- **设计理由**：兼容生态而非另造钩子方言。青山：未实现；若要兼容 CC 生态钩子，协议可参考。🅒/🅑。

## 2.14 workflow/ / webhook/ / experimental/

- **workflow（ctx.workflowEngine + worker-thread + tool-workflow + tool-ralph）** 🅒：模型写的 JS 编排脚本跑在 worker 线程 vm 里，`agent()` 调用桥回 `ctx.subagents`；每 run 一个 worker。ralph 工具=新 agent 的 Ralph 循环。暂不需要。
- **webhook（ctx.webhookRuntime + webhook-github）** 🅒：fire-and-forget 已验证投递 → 受信规则 → 创建 Workspace 会话；运行时**不存任何投递状态**。暂不需要。
- **experimental/agent-team** 🅒：隐式根 Team 域——花名册（provisioning→active/failed）、持久同伴邮箱、共享任务 DAG（task-<n> 局部单调 id）；模型工具 experimental/tool-agent-team；私有 opt-in。
- **experimental/webworker-runtime + webworker-packer** 🅓：浏览器内整棵 harness（内存 VFS、模块转换、postMessage 隧道）——纯 Web 特技。
- **experimental/inspector** 🅓、**code-runtime-python** 🅒。

## 2.15 extensions/ —— 模型挂插件（重要发现）

- **tool-cordis + cordis-host-runner + cordis-client-runner + ui-cordis** 🅒：**自指 cordis 工具集**——模型可 inspect 活运行时、编写并挂载/卸载插件（`cordis_define`，双半包：host 半沙箱生命周期 + client 半事件订阅）；UI 有定义卡片和 run/stop 开关。设计含义：插件组合本身暴露给模型。青山暂不需要，但这是"agent 自我扩展"的完整参考实现。

## 2.16 基础设施杂项

- **settings（ctx.settings + settings-file）** 🅑：每命名空间节；解析序=schema 默认→组合 base→用户节；settings.yaml 存储+外部编辑推送。青山未实现（iOS 用 UserDefaults 适配）。
- **credentials（ctx.credentials + credentials-local）** 🅑：设置只存*引用*（环境变量名），provider 拥有值（`$DSH_HOME/.env` + 进程环境）；**每次操作重新 resolve**——轮换密钥下一请求即生效、零重启。空存储值=处处缺席。青山：Keychain 适配点。🅑
- **context/ 五包** 🅐：agent-instructions（AGENTS.md/CLAUDE.md 工作区指令加载）、file-reference(-local)（@file 语法+有界模糊索引）、session-reference（跨会话引用+不可信模型上下文协议）、time-context（每步当前时间+流逝时间，opt-in 持久）、tmux-context（每步 tmux 位置，🅓）。**time-context 与 agent-instructions 均 🅐**：青山系统提示词应含时间、应支持指令文件。
- **invariants（ctx.invariants）** 🅒：包自有运行时不变量的注册表服务（全局开关+包正则 allowlist/denylist）；各包发布 `./invariant` 伴随插件。理念可抄：青山可为核心关系（call/result 配对、turn 封闭）写不变量自检。
- **workspace** 🅒：目录的持久记录（uuid≠path，realpath 归一）+ 会话挂靠账目。
- **typert/** 🅓：TS 项目分析器 + 生成 Remote 元数据/Zod schema 的反射代码生成（Host↔Client RPC 骨架）。
- **util/ 12 包** 🅐：`atomic-write`（独占创建+rename 携权限）、`brand`、`crypto`（浏览器安全 UUID）、`deque`（环形双端队列）、`home-paths`、`launch-environment`（记录每个值由哪层提供）、`native-command`（🅓）、**`output-retention`**（ItemRetainer/TextRetainer 有界保留+"保留了什么/省略了什么"中性通知原语，🅐 输出截断场景通用）、`util-time`（IANA 时区校验）、**`timeout`**（clampTimeout/deadline/timeoutOf/TimeoutReason——纯计时+分类、不终止，🅐）、`values`、`workspace-path`。
- **test-support/ 6 包** 🅒：agent-loop-testkit、client-runtime、llm-mock-server（可脚本化 OpenAI 兼容故障注入服务器）、llm-replay（从 JSONL 重建 chunk 短路 llm/stream——无密钥快照测试）、loader-smoke、session-snapshot。**llm-replay 模式对青山测试有直接参考价值**。

## 2.17 表面层（青山基本 🅓）

- **host/**：webserver（路由注册）、frontend-static（SPA dist 服务）、directory-picker 三包（native/browse/auto）、plugin-inventory。
- **api/**：gateway（Typert Remote Host 分发）、remotes、session/settings/workspace-controller——浏览器 RPC 面。
- **client/**（50+ 包）：connection/hmr/locale/modules/store + ui-*（primitives、layout、sidebar、conversation、chat、trajectory、tool、approval、plan、goal、jobs、schedule、subagent、user-questions、settings 全家、skill、workflow-run、theme…）+ web（启动内核）。React + 插件化 UI，零 cordis 的原子组件层。
- **acp/**：自动化专用 Agent Client Protocol 服务器（JSON-RPC stdio）。
- **sdk/**：protocol（newline-delimited JSON-RPC stdio wire）+ server（stdio JSON-RPC 服务插件）+ client（TS SDK：DeepSeekHarness 高层 turns API + HarnessClient）；Python SDK 打包同一 CLI 为 runtime wheel。
- **boot/**：app-boot（.env 加载、fail-loud Loader 守卫、快照感知配置解析）、cmdline（不可变命令行交接）。
- **identity/anonymous-user-id** 🅒、**feedback/**（message-feedback 本地 sidecar 评分+note，CAS 版本 token；command-feedback 日志型）🅒。

---

# 第三部分 🅐🅑 级能力汇总表（青山后续路线候选，按建议优先级排序）

| 优先 | 能力 | dsh 包 | 一句话价值 | 依赖 |
|---|---|---|---|---|
| P0 | 重复工具提醒 guard | guard/repeat-tool-reminder | 防循环烧钱；规范化参数键 + gentle→detailed 升级，advisory 不否决 | tools post-execute |
| P0 | 工具超时统一策略 | guard/timeout-policy + util/timeout | 管线层 deadline 换信号，结构化 TOOL_TIMEOUT 结果 | tools execute waterfall |
| P0 | 工具结果溢写 | spill 三包 + util/output-retention | 超长输出→预览+文件，防上下文爆仓 | post-execute |
| P0 | 上下文压缩（先 pruner 后 LLM 摘要） | compaction-basic + tool-result-pruner + token-meter | surface replace 无损压缩；overflow 重试 | token-meter |
| P0 | 会话检查点策略 | session-checkpoint-policy | 请求前+副作用前落盘——iSH 随时被杀的最小丢失窗口 | 持久层 |
| P1 | Inbox 双通道 + steer/inject | core/agent | 插话不打乱 turn 边界；静默上下文囤积 | agent-loop |
| P1 | 后台任务运行时 | jobs 三包 | job_output/list/kill 统一后台身份与控制 | — |
| P1 | subagent（spawn-in-process 起步） | subagent 域 | 委派=能力 seam；continuable 复用 inbox 全套原语 | agent registry |
| P1 | 计划/待办/目标三件套 | plan-mode / todo / goal(-后) | 全部是"事件+投影+工具"同构，一次学会三个 | 投影 |
| P1 | ask_user_question + approval fail-closed | interaction 四包 | 人机问答与一次性授权的标准形状 | — |
| P2 | 会话内定时提醒 | schedule | after/at/every(≥5min) 落日志，idle 驱动回投 | 投影 |
| P2 | pre-step/turn-stopping 拦截 | core/agent 事件 | plan-mode/压缩/注入上下文的统一挂点 | P1 inbox |
| P2 | token 计量 | llm/token-meter | 压缩与显示的前置 | 日志 |
| P2 | session-title 维护任务 | session-title 族 | runMaintenance 空闲期生成，不占 turn | agent runMaintenance |
| P2 | DSH_* 环境命名空间 | shell/shell-env + subprocess | 托管事实不被继承/顶替 | shell |
| P2 | read-before-edit 观察策略 | fs-observation-policy | 策略=waterfall 裁决而非服务，可插拔 | ctx.fs |
| P3 | 会话投影注册表 | session-projection | 一次订阅折叠全部域状态 | 日志 |
| P3 | 技能系统 | skill 四包 | SKILL.md 目录约定 + skill 工具 | 注入通道 |
| P3 | 增量日志 API 扩展 | session-log-deepseek | 官方 API 私有通道白拿收益 | DeepSeek API |
| P3 | 持久终端多会话 | terminal + tool-terminal | vim/交互程序场景 | PTY（iSH 需适配） |
| P3 | LLM 重放测试 | test-support/llm-replay + mock-server | 无密钥快照测试/故障注入 | — |
| 🅑 | 时间/指令上下文 | context/time-context + agent-instructions | 每步注入时间；AGENTS.md 加载 | pre-step |
| 🅑 | 凭证引用解析 | credentials(+local) | 引用≠值，Keychain 适配 | settings |
| 🅑 | 内容寻址附件 | attachment(-local) | 先持久后落事件，只传引用 | 多模态时 |
| 🅑 | glob/grep 工具 | tool-fs-search | @vscode/ripgrep，iSH 需 ARM 二进制验证 | ctx.fs |
| 🅑 | MCP 客户端 | mcp-client | stdio MCP→ctx.tools | iSH 进程能力 |
| 🅑 | web_search/web_fetch | web 域 | 单 seam 双操作+多 provider | iOS 网络 |
| 🅒 备查 | 会话查询 FTS5 / 遥测 / workflow / agent-team / webhook / cordis 自挂载 / hooks 桥 | 各域 | M7 之后再看 | — |
| 🅓 不适用 | 沙箱后端（bwrap/seatbelt/ACL）、win32、pwsh、web 全家桶、host/api/client、typert、webworker 运行时、e2b | — | CLI/浏览器/平台特有 | — |

---

## 附：三个"此前完全不知道"级别的认知修正

1. **compaction 不删历史**：压缩通过 `surfaceOp:'replace'` 阴影化表面节点实现，日志永远无损——"压缩"是投影层概念，重放任意历史版本永远可行（session.md:287-296 + compaction.md）。
2. **重复工具提醒是纯 advisory**：thresholds `[3,5,8]`、deep key-sort 规范化链键、只 prepend 带插件来源标签的 user 消息，绝不否决调用（guard/repeat-tool-reminder/src/index.ts）。
3. **continuable subagent 复用 inbox**：多轮子代理不发明新队列——Activation 常驻 + `sendMessage` 按 running/waiting/无 Activation 三态分别路由为 steer/唤醒/冷 resume，权威=精确活发送者（subagent.md:122-168）。
4. （附赠）**session-log-deepseek**：官方 DeepSeek API 存在"整条日志增量随请求上行"的私有 wire 扩展，且扩展字段本身有注册表包（deepseek-llm-api-extensions）——用官方 API 的客户端可白拿。
