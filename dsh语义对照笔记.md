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

---

# M4.5 施工图：HTML 稿全量对齐清单（2026-09-04）

> HTML 稿 = agent-prototype.html（用户更新版，134KB/2167 行）。本清单 = 逐组件核对后的差距施工图。
> 原则：HTML 有的全做；Swift 端已对齐的不再列。

## A. 左栏（Swift 缺 8 项）
1. 搜索框（真实过滤会话）
2. 项目分组 sections（置顶/工作/个人）+ 项目行（色块/会话数/展开收起）
3. pin 置顶切换
4. 会话重命名（inline 编辑）
5. 新建项目入口（CreateProjectSheet）
6. 底部入口带 badge（任务队列 3 / 插件 MCP 3 启用 / 记忆 12）
7. 会话行删除按钮（✕）
8. 收起后 rail 细条模式

## B. Composer（Swift 缺 7 项）
1. 上下文胶囊行：项目 chip（切换弹层+新建项目+解绑）/ 本地环境 chip（本地/工作树/云端弹层）/ 分支 chip（BranchPop：搜索+列表+创建）
2. 附件 + 菜单（@ 文件引用 / 目标 / 计划模式）
3. CtxRing 环形上下文图 + 点击弹层（含 % 与压缩入口）
4. slash 弹窗（12 条可执行：model/new/init/compact/review/diff/memories/skills/permissions/plan/export/rename）
5. @ 文件引用弹窗（WORKSPACE_FILES 过滤插入）
6. 策略 chip 下拉（三档，联动完全访问开关）
7. 模型/力度按钮（EffortSlider 拖动 + ModelEffortPop 双态：滑块⇄列表 + BYOK 入口 + 高档警告）

## C. 右栏多 tab（Swift 缺 6 项）
1. tab 系统（多 tab + 关闭 + 添加菜单 + 快捷键提示 Ctrl+Shift+G / `/T/P）
2. ReviewTab 完整（分支头 +N−N、main←origin/main、未跟踪文件过滤提示条、筛选框、文件 diff 卡+unmodified 折叠段）
3. BrowserPanel 浏览器面板（地址栏+开始浏览空态）
4. FilesPanel 文件面板（文件树+文件内容查看）
5. 右栏空态（打开面板列表+快捷键）
6. 右栏收起 rail

## D. 消息流（Swift 缺 3 项）
1. Think 折叠形态收紧（spinner Thinking → Think·摘要折叠 → 点击展开；当前直接展示）
2. MsgPlan 步骤列表（done/doing/todo）
3. MsgSystem alert 行

## E. Sheets（Swift 缺 4 + 改 1）
1. MemoriesSheet（统计卡+AGENTS.md 卡+条目+淘汰倒计时）
2. TasksSheet（任务列表+badge）
3. PluginsSheet（开关列表+添加按钮）
4. SkillsSheet（技能列表）
5. CreateProjectSheet（项目名+源文件夹）
6. SettingsSheet 对齐（权限双开关联动策略/BYOK 三件套/记忆组/Linux 重置）

## F. 其他
1. ctxwarn 上下文将满横幅（<25% 显示+/compact 提示）
2. Wizard 首启对齐（spinner 步骤+进入主界面/跳过）
3. 空态 hero（大标题+4 建议卡，Swift 已有 ✓）
4. 会话删除后切到最新剩余会话

## 实施批次
- 批 1：左栏完整 + Sheets 全家 + SessionStore 扩展
- 批 2：右栏多 tab 系统 + Review 完整 + Files + Browser
- 批 3：Composer 完整 + CtxRing + slash/@ + 策略联动
- 批 4：杂项（ctxwarn/Plan/System 消息/Wizard 对齐）+ 构建验收

---

# M5 记录：bash-persistent 移植（tool-bash-persistent → PersistentShell.swift）

| dsh 语义 | 青山实现 | 状态 |
|---|---|---|
| owner 级持久 shell 注册表（WeakMap+Map） | boot 时 `/bin/sh -l` 常驻 + PersistentShell 单例 | ✅ |
| wrapCommand 单物理行（printf START + eval + status + printf END:code） | 同款（nonce 标记 + $'...' 引用转义） | ✅ |
| quoteForBash（\ ' \r \n 转义） | 同款 | ✅ |
| scrollback 分页轮询（25ms）取输出 | 全局 console 流分流（outputCallback→ingest），无分页 | ✅ 简化 |
| END 标记带退出码、START 截断→LOST_PREFIX 提示 | 退出码 ✅；LOST_PREFIX 简化为空输出 | ⚠ 简化 |
| 超时→部分输出+reset shell | 超时→Ctrl-C 前台+部分输出+**不 reset**（保持持久性） | ⚠ 差异（记 M8 增强） |
| shell 退出→捕获残余+reset+提示 | 未处理（shell 意外退出时 pending 挂起至超时） | ⚠ 待补 |
| stty -echo | 同款 | ✅ |
| owner 内命令串行（queues） | runTurn 循环天然串行 | ✅ |
| maxOutputChars 截断 16k | prefix 6000（沿 M2 惯例） | ✅ |
| 工具名 bash / 描述含 persistent 语义 | 工具名 run_command + persistent 描述 | ✅ |
