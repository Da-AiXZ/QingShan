# 03 - iOS 生命周期 × Agent 进行中操作：完整影响矩阵与适配清单

> 分析日期：2026-09-05。分析员：m67-ios-lifecycle。
> 依据：青山源码逐行阅读（RootView / QingShanApp / AgentSession / MemoryPipeline / PersistentShell / SessionLog / MemoryStore / DeepSeekAdapter / ExecutionController / ISHKernel.h+.m）、iSH 原版 app（repos/ish-arm64）、OpenMinis（repos/OpenMinis）对照实现、Apple 生命周期公开文档常识。
> **禁止臆测声明**：文中所有 API 均为公开文档 API 或在本仓库代码中实际读到；iOS 26 后台预算 48 CPU-s/60s 滑窗来自 ISHKernel.m 注释（IPS 2026-08-02 实测），非官方公开数值。

---

## 0. 核心结论（一句话版）

**dsh 是 CLI——进程活着一切都在；青山是 iOS App——随时被挂起/冻结/杀掉。** 当前青山在生命周期维度只有一行代码：`RootView.swift:119-123` 在 scenePhase == .background 时踢一脚记忆管线，而记忆管线本身（LLM 流式调用）恰恰最需要系统时间却没有 `beginBackgroundTask` 保护。iSH 内核侧的闭环 CPU governor（ISHKernel.m:1581-1830）**已完整实现但 Swift 侧零调用，等效死代码**（全 Swift grep 无 beginBackgroundCPUGovernor）。

---

## 1. 状态机定义（本文使用的六个状态）

| # | 状态 | 系统行为（Apple 公开语义） | 对青山进程的影响 |
|---|------|--------------------------|----------------|
| **S1** | 前台活跃 | scenePhase == .active | 一切正常，CPU/网络无额外限制 |
| **S2** | 前台非活跃 | 来电、控制中心、通知中心、App 切换动画中、iPad Slide Over 失焦 | 进程继续跑，但 UI 事件暂停；**无时间限制** |
| **S3** | 后台短暂窗口 | 退后台后系统给的一段宽限；若调用了 `UIApplication.beginBackgroundTask` 则约 30s（实测 25-30s，有时更短），过期回调到达后**必须** end，否则进程被杀 | CPU 可全速，只是有墙钟倒计时 |
| **S4** | 后台 + CPU governor | iSH/OpenMinis 特殊能力：进程仍在跑，但 iOS 对后台进程有 CPU 累计预算（**实测 48 CPU-s / 60s 滑窗，超预算 RunningBoard 直接杀**，ISHKernel.m:1584-1586）。governor 用闭环节流把 60s 滑窗 CPU 压在 soft=30s / hard=38s 以下（GREEN/YELLOW/RED 三档 + 10Hz poke） | 慢但活；guest 执行被压到 3%-100% duty 浮动 |
| **S5** | 挂起/冻结 | 无任何后台保活手段且宽限用尽 → 进程 **suspend**（信号不派发、代码不执行、socket 断流）；iOS 15+ 进一步 **App Freeze**（冻结内存页，jetsam 压力下可随时丢弃） | 所有 Swift Task / 内核线程全部冻结；TCP 连接被对端或中间设备切断；**恢复时间不确定**（可能几秒后 thaw，也可能永远停在冻结态直到被杀） |
| **S6** | 终止 | 用户上滑杀 / jetsam（内存）/ RunningBoard（后台 CPU 超预算 / bgTask 过期不 end）/ 崩溃 | 无信号预警（SIGKILL 类），唯一防线是落盘的持久化状态 |

**青山现状**：S3→S5 之间没有任何缓冲——退后台后既没有 beginBackgroundTask 买宽限，也没有接 governor，约 5-30 秒后直接进 S5。

---

## 2. 影响矩阵（6 状态 × 6 操作 = 36 格）

每格格式：**会发生什么 ｜ 数据是否安全 ｜ 需要的适配**。

### O1 — LLM SSE 流式中（AgentSession.runTurn L261-313 的 `for try await ev in stream`）

| | O1 LLM SSE 流式中 |
|---|---|
| **S1 前台活跃** | 正常，URLSession.shared.bytes 逐行收流 ｜ 安全 ｜ 无 |
| **S2 前台非活跃** | 进程继续，流继续收；但 UI 不刷新（无妨，回来会对齐 @Published）｜ 安全 ｜ 无 |
| **S3 后台短暂（~30s）** | 现状：**没有任何保护**。约 5-30s 后 suspend：SSE socket 冻结，`bytes.lines` 迭代停住。thaw 后迭代可能继续（若连接未断）也可能抛错（连接被回收）——**不确定性行为**。DeepSeekAdapter req.timeoutInterval=120 在后台计时会被暂停（墙钟语义），回来后可能突然超时 ｜ assistantChunk 已逐条 append 进 SessionLog（部分安全）；**流尾部 + step 收尾事件不安全** ｜ P0：包 beginBackgroundTask("AgentLoop")；P1：流断后按"可重试"语义处理（见 §5） |
| **S4 后台 + governor** | 进程活着，网络流不受 governor 限制（governor 只节流 guest CPU）；DeepSeek 流式可以继续收。但 swift 消费循环在 MainActor 上，若同时有 guest 命令在跑被压到 RED，turn 会变慢但不死 ｜ 安全 ｜ P0：接线 begin/endBackgroundCPUGovernor；P2：流式期间 governor 维持 GREEN 即可（LLM 流几乎不耗 CPU） |
| **S5 挂起/冻结** | socket 死亡。thaw 后 `bytes.lines` 抛错或永远 hang（取决于连接池状态）；`reason="error"`，turn 以 stepEnd+turnEnd("error") 收尾——**但收尾代码本身也被冻结了，所以连错误落盘都不会发生**，直到 thaw 才补写 ｜ 不安全：turn 收尾两个事件可能延迟数分钟到永远 ｜ P0：SSE 循环挂 onTermination/超时兜底；P1：thaw 后检测"冻结期间中断的 turn"并落一条 interrupted 事件 |
| **S6 终止** | 全丢：本步 assistant 文本（已流出的 delta 在 assistantChunk 里部分落盘）、toolCalls 不可恢复。下次启动 resume 会看到 turn/start 后无 turn/end 的悬尾 ｜ **不安全** ｜ P1：resume 时识别悬尾 turn 并在 UI 上标"该轮被系统中断，可重发" |

### O2 — 工具命令执行中（持久 shell 前台命令；PersistentShell.run L43-88 轮询 /tmp/.qs_done）

| | O2 工具命令执行中 |
|---|---|
| **S1 前台活跃** | 正常。iSH 内核线程执行 guest 进程，60ms 轮询 done 文件 ｜ guest 文件写在 fakefs=宿主真实文件，安全 ｜ 无 |
| **S2 前台非活跃** | 命令继续跑（计时器 DispatchSource 也继续）｜ 安全 ｜ 无 |
| **S3 后台短暂** | 现状无保护：suspend 后 iSH 内核线程（asbestos 执行引擎）全部冻结，guest 命令停摆；done 文件永远不会出现；轮询循环（Task.sleep）同样冻结。thaw 后：命令**继续跑**（iSH 进程状态完整保留），但墙钟超时可能已经"过期"——run() 会立刻发 Ctrl-C 杀掉一个其实没机会跑完的命令 ｜ guest 侧半成品文件（如 write_file 的 cp 到一半）不保证原子 ｜ P0：命令执行期包 beginBackgroundTask（超时上限取命令 timeout_sec）；P2：write_file 类命令落盘后 fsync（见 §4） |
| **S4 后台 + governor** | **这是 iSH 血统的核心场景**：governor 以 10Hz poke + 三档 duty 把 guest CPU 压在 iOS 48s/60s 预算之下。长命令（编译、pip install）能跑完，只是慢（RED 档 ~3% duty）。**不接 governor 的后果**：busy-loop 类命令（Agent 常写 `while true; do ...` 探测）在后台全速跑 60s → RunningBoard 杀进程 = S6 ｜ guest 数据安全（fakefs 持续写宿主盘）｜ **P0：接线 governor（专项方案见 §3）** |
| **S5 挂起/冻结** | 命令冻结在内核态；thaw 后继续。若用户长时间不来：命令侧的 timeout 已经无意义（Task.sleep 也冻结，超时逻辑同步停摆——这点其实是"对的"）｜ guest 数据安全 ｜ P1：UI 上标记"此命令因后台挂起而暂停" |
| **S6 终止** | guest 进程随宿主进程死亡。fakefs 是宿主真实文件，**已写完的部分保留**；但 PTY 中断，持久 shell 的 /bin/sh 不复存在——重启 App 后 boot 流程会重开 shell，cd/export 状态丢失 ｜ 半成品文件不安全；shell 状态不安全（可接受，dsh 同样丢）｜ P1：resume 后向模型注入"宿主曾中断，shell 状态重置"提示 |

### O3 — turn/step 循环间隙（Swift 侧代码在跑：日志 append、llmHistory 更新、下一步准备）

| | O3 turn/step 循环间隙 |
|---|---|
| **S1/S2** | 正常 ｜ 安全 ｜ 无 |
| **S3** | 间隙操作是毫秒级，通常能溜过去；但若间隙正逢墙钟到期，suspend 打断 append 调用中间态 ｜ SessionLog 单行 write 可能写一半（JSONL 半行）——**replay 有半行容错**（SessionLog.swift:144 注释明确），安全 ｜ P1：在 runTurn 每步间隙调 waitIfBackgroundSuspended() 语义（OpenMinis AIChatViewModel+BackgroundTask.swift:427 同款），把"继续跑"变成显式决策 |
| **S4** | governor 不影响 Swift 主线程 CPU（只节流 guest）；循环间隙照常 ｜ 安全 ｜ 无 |
| **S5** | 冻结，thaw 后继续。llmHistory 在内存里，安全 ｜ 安全 ｜ 无 |
| **S6** | 内存中的 llmHistory/messages 全丢；但 SessionLog 事件溯源设计（每步都 append）保证 resume 能重放到最后完整事件 ｜ **安全（这是青山架构做对了的地方）** ｜ 无 |

### O4 — 记忆管线（MemoryPipeline.kick：Phase1 LLM 流式调用 + entries.json/summary 写入）

| | O4 记忆管线 |
|---|---|
| **S1** | 正常（App 启动时 kick，RootView.swift:721）｜ 安全 ｜ 无 |
| **S2** | 正常 ｜ 安全 ｜ 无 |
| **S3** | **当前最大风险点**：RootView.swift:119-123 在 scenePhase==.background 时 kick，管线 Phase1 要发 LLM 流式请求（10s-60s+），且 prefix(5) 个候选会话串行提取——**总耗时轻松超过 30s 窗口**。无 beginBackgroundTask 保护：suspend 后 Phase1 JSON 解析没跑、entries.json 没写，本会话的记忆**整条丢失**；更糟的是 `extractedSessions` 标记在 Phase1 成功后才写（MemoryPipeline.swift:48-49），所以丢的是"提取中途"——回来后 kick 重入（running 标志已复位？不，suspend 冻结时 defer 未执行，thaw 后 defer 才跑）——行为不确定 ｜ **不安全**：Phase1 LLM 结果全丢（内存 text 变量）｜ **P0：kick 外包 beginBackgroundTask("MemoryPipeline")，过期时取消管线并保证 `running` 标志复位** |
| **S4** | Phase1 是纯网络 + 主线程轻 CPU，governor 不构成障碍；但管线若在 governor RED 期间与 guest 命令抢 MainActor 会让 UI/轮询变慢 ｜ 安全 ｜ P2：把 MemoryPipeline.kick 从 MainActor 摘到后台 actor（目前 @MainActor，App 启动 kick 时会阻塞首帧渲染的兄弟任务）|
| **S5** | 同 S3，全丢 ｜ 不安全 ｜ 同上 |
| **S6** | 全丢；且 `.pipeline_meta` 与 entries.json 若写在 rename 中途——`.atomic` 写法（MemoryStore.swift:72/79）保证原子性，**不会出现半文件** ｜ 文件本身安全（atomic），内容安全 ｜ 无新增 |

### O5 — SessionLog 追加写入（SessionLog.writeLine L114-123）

| | O5 SessionLog 追加 |
|---|---|
| **S1/S2** | queue.sync + FileHandle seekToEnd+write，毫秒级 ｜ 安全 ｜ 无 |
| **S3** | 单次 append 毫秒级完成，撞上 suspend 边界的概率低；撞上则产生半行——replay 容错（crash 半行静默丢弃）已覆盖 ｜ 安全 ｜ 无 |
| **S4** | 同上 ｜ 安全 ｜ 无 |
| **S5** | 冻结期间无法 append；事件在内存排队（实际上没有队列——append 是同步的，冻结即停）｜ 最后一个事件可能半行（可容错）｜ 无新增 |
| **S6** | **关键问题：无 fsync**。FileHandle.write 只进 page cache。被 SIGKILL 时 iOS 通常仍会 flush（进程死亡不清 page cache），但**掉电/内核崩溃场景**尾部丢失；另外 assistantChunk 每 delta 一次 open+seekToEnd+close（SessionLog.swift:118-122 每次新开 FileHandle），高频小写放大 IO ｜ 基本安全，尾部理论风险 ｜ P2：turnEnd 事件后 `fh.syncFile()`（或对 FileHandle 调 synchronizeFile）；P3：assistantChunk 改为内存缓冲 + 每 300ms 批量 flush（可选，收益是 IO 减半） |

### O6 — 审批等待（ApprovalService 触发，AgentSession L375-378 CheckedContinuation 无限挂起）

| | O6 审批等待 |
|---|---|
| **S1** | 用户在场，正常 ｜ 安全 ｜ 无 |
| **S2** | 正常；但通知提醒缺失——用户看不到审批卡 ｜ 安全 ｜ P3：审批请求发本地通知（UNUserNotificationCenter），把用户拉回来 |
| **S3** | **微妙的良性场景**：continuation 挂起不占 CPU，suspend 冻结它也无妨——用户回来 thaw，审批卡还在，点一下继续。但现状：退后台触发记忆管线 kick 抢跑又没保护，可能先于审批超时被杀 ｜ 安全（continuation 语义）｜ 无专门适配；受益于 O4 的 P0 修复 |
| **S4** | 同 S3 ｜ 安全 ｜ 同上 |
| **S5** | 冻结期间审批卡不可交互（App 冻结了）。用户点图标 → thaw → 审批卡原样在 → 可点 ｜ 安全 ｜ 无 |
| **S6** | approval/request 事件已落盘（AgentSession L373），resume 重放显示审批卡但 **approvalCont 不在了**——当前 resume 重放只还原 UI，不重建 continuation（AgentSession.load 不处理 approval 事件）｜ 重放后审批卡是死卡：点了 resolveApproval 找不到 continuation，approvalCont 为 nil，`resume` 空转，turn 永远不会继续 ｜ **P1：load() 时若最后未决事件是 approval/request 且无 decision，把 turn 标记为"待恢复"——用户点审批后以新 user 消息形式续跑，或重建一个续跑任务**（OpenMinis 用 canResume/badge 机制表达同语义） |

---

## 3. 用户操作场景 × 系统行为（iPad 特化）

| 用户操作 | 系统行为 | 青山受到的影响 |
|---|---|---|
| **锁屏**（Smart Cover 合盖/电源键） | scenePhase .background；iPad 无"后台音频"需求即进宽限 | 与"切到别的 App"等价。长任务（编译类命令）最可能在此被腰斩 |
| **切到别的 App**（手势回主屏/切换器选择） | .inactive → .background，同上 | 同上。当前唯一反应是踢记忆管线（无保护） |
| **分屏：另一半活跃** | iPad 双 App 同时 .active，**青山不受影响** | 无需适配（这是 iPad 相对 iPhone 的红利） |
| **Slide Over 失焦 / 拖走** | .inactive（不 background） | 任务继续跑；注意 0.25s 计时器（RootView.swift:65）继续耗电，可接受 |
| **台前调度 Stage Manager 缩放/收起窗口** | 尺寸变化走 GeometryChange；收起不 background | P3：拖拽手柄（dragHandle）在窄窗口下的最小宽度保护已有（180/260 下限），够用 |
| **直接杀 App**（切换器上滑） | SIGKILL，无任何回调（applicationWillTerminate 不保证） | 依赖 SessionLog 持久化（已是事件溯源，最坏丢半行）+ fakefs 文件。**这是当前架构最能扛的场景** |
| **系统杀**（后台超 CPU 预算 / 内存） | 同 SIGKILL | 同上；且**不可预期**——governor 接线就是为了把这类死法变成"慢但活" |
| **后台启动**（thaw 失败被杀后用户点 Live Activity/通知拉起） | applicationState == .background 直接启动 | OpenMinis BackgroundKeepAliveManager.swift:394-398 的教训：**setup 时若已在后台也要 arm governor**，因为不会有 didEnterBackground 通知 |

---

## 4. 数据安全：挂起/杀死时的写入清单

| 写入目标 | 写法（现状代码位置） | suspend 时 | SIGKILL 时 | 掉电/内核崩溃时 | 策略建议 |
|---|---|---|---|---|---|
| SessionLog JSONL | FileHandle seekToEnd+write（SessionLog.swift:114-123），每 delta 一次 | 停在最后一个完整/半行 | page cache 通常已 flush，尾部基本保住 | 尾部丢 | turnEnd 处加 `synchronizeFile()`；半行由 replay 容错兜底（已有） |
| entries.json / .pipeline_meta | `Data.write(options: .atomic)`（MemoryStore.swift:72/79） | 停 | atomic=临时文件+rename，**不会半文件** | rename 前后要么旧要么新 | 已合格，无需改 |
| MEMORY.md / memory_summary.md / rollout_*.md | `String.write(atomically:)`（MemoryStore.swift:106/116/130） | 停 | 同上安全 | 同上 | 已合格 |
| guest rootfs（data/ 下 fakefs 真实文件） | iSH 内核直写宿主 APFS | 冻结在中间态 | **半成品可能存在**（如 cp 写一半） | 半成品 | P2：write_file 工具命令尾加 `sync`；Agent 提示词已要求"写后验证"，可接受残余风险 |
| /tmp/.qs_o|.qs_r|.qs_done（shell 文件协议） | guest 写、宿主轮询 | 三文件状态一致冻结 | 一致（都在 fakefs） | 一致 | 无需改 |
| UserDefaults（mem.extracted、approval.policy） | 系统管理，cfprefsd 异步落盘 | 停 | cfskigel 崩溃丢失窗口极小 | 可能回滚 | extractedSessions 丢失=重复提取一次，无害 |

**结论**：青山最大的数据风险不是文件格式，而是**"耗时写操作（记忆管线 LLM 调用）在没有时间预算的状态下启动"**。

---

## 5. 恢复体验（后台回前台 / 冷启动）

### 5.1 SSE 流断了怎么办（P1 设计）

现状：DeepSeekAdapter 抛错 → runTurn L326-334 直接终止 turn，UI 显示"（流中断：…）"。用户只能重发整条消息。

建议（照 OpenMinis expiry-handler 的"re-arm 而非取消"哲学）：
1. **已有 delta 但流断**（`full` 非空 / hadDelta）：不重试整步——把已收内容落 assistantMessage 事件 + reason="stream-truncated"，turn 正常收尾；用户下一条消息自然续。
2. **无 delta 流断且错误可重试**（现有 429/5xx 重试逻辑已覆盖 attempt<3）：保持现状。
3. **thaw 后检测**：scenePhase 变 .active 时，若 `isThinking == true` 且距上次收到任何 SSE 事件 > 90s（URLSession timeoutInterval=120 的一半），主动 cancel 流并走路径 1。这修复"S5 冻结后流永远 hang"的死态。

### 5.2 冷启动续跑

现状已具备：resumeLatest() + SessionLog.replay 事件重放（AgentSession.load L137-202），悬尾 turn（有 turn/start 无 turn/end）能重放消息但不会继续执行。需要补：
- 悬尾 turn 检测：重放最后事件是 toolCall 无 toolResult，或 assistantMessage 带 toolCallsJSON 但后续无对应 tool/result → UI 插一条系统提示"上一轮被系统中断于第 N 步"，并给"继续"按钮（把工具调用结果以"（宿主中断，结果未知）"补进 llmHistory 后直接重入循环）。
- 审批死卡修复（见 O6/S6 格）。

---

## 6. governor 接线专项方案（照 OpenMinis 已验证实现翻译）

### 6.1 三层保活架构（OpenMinis 现状 = 推荐蓝图）

| 层 | 机制 | 效果 | 成本 | 青山建议 |
|---|---|---|---|---|
| L1 | `UIApplication.beginBackgroundTask` | ~30s 墙钟宽限，全速 | 零审核风险 | **必做（P0）**，无争议 |
| L2 | iSH 闭环 CPU governor（已有实现） | 宽限过后进程不死，guest CPU 被压进 iOS 预算（48s/60s）内持续跑 | 慢（RED 3% duty）| **必做（P0）**，纯接线 |
| L3 | 静音音频（audio 模式）/ 位置（location 模式 + `allowsBackgroundLocationUpdates` + iOS 17 `CLBackgroundActivitySession`） | 彻底绕过 suspend，governor 都可以不全速 | App Store 审核要求"功能确需"；iSH 原版正是靠 `UIBackgroundModes: location`（其 Info.plist:56-58）+ LocationDevice.m 的 CLLocationManager（allowsBackgroundLocationUpdates=YES）实现"后台保持运行" | **P3 观察**：青山若有"长任务不被杀"刚需再上，先 L1+L2 验证 |

### 6.2 具体接线代码（谁、什么时机、调什么）

**新文件 `QingShan/Platform/LifecycleCoordinator.swift`**（或并入 QingShanApp）：

```swift
// 时机一：didEnterBackground（等价 scenePhase == .background 的权威通知，
// 用 NotificationCenter 版本而非 SwiftUI scenePhase，后者在多场景下语义弱）
NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, ...) { _ in
    ISHKernel.shared.beginBackgroundCPUGovernor()   // 幂等（ISHKernel.m:1780 直接 return）
    bgTask = UIApplication.shared.beginBackgroundTask(withName: "QSAgentLoop") {
        // 过期回调：有 L3 保活时 re-arm（OpenMinis AIChatViewModel+BackgroundTask.swift:32-45 语义）；
        // 青山暂无 L3 → 立即 end 并让 runTurn 走"暂停"路径，防系统强杀
        UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid
        AgentSession.shared.requestBackgroundPause()   // 置标志，见 6.3
    }
}
// 时机二：willEnterForeground
{ _ in
    ISHKernel.shared.endBackgroundCPUGovernor()        // 幂等（ISHKernel.m:1817）
    if bgTask != .invalid { endBackgroundTask(bgTask); bgTask = .invalid }
}
// 时机三：App 冷启动即在后台（Live Activity/通知拉起）
if UIApplication.shared.applicationState == .background {
    ISHKernel.shared.beginBackgroundCPUGovernor()      // OpenMinis:394-398 教训
}
```

注意点（全部来自 OpenMinis 实战注释）：
1. **begin/end 都幂等**（ISHKernel.m:1780/1817 已保证），重复调用无害。
2. **后台启动也要 arm**——被 RunningBoard 杀后经通知拉起不会收到 didEnterBackground。
3. governor 的 dispatch timer 用 UTILITY QoS（ISHKernel.m:1782-1783），后台照常触发；前台的 `enableCPUThrottleWithDutyCycle` **不要**调用（那是固定占空比的旧接口，governor 是它的闭环替代，OpenMinis 注释明确）。
4. bgTask 的 expiry 回调在**任意线程**，里面要 hop 回 MainActor 再改状态。
5. `beginBackgroundTask` 可能返回 `.invalid`（系统拒绝），要检测（OpenMinis BackupActivityLock.swift:35 的坑）。

### 6.3 runTurn 配合：间隙暂停点

在 AgentSession.runTurn 的 while 循环顶部（L244 `while stepNo < maxSteps` 之后）插入：

```swift
// 一步开始前：若 bgTask 已过期且无保活，park 到前台（OpenMinis waitIfBackgroundSuspended 语义）
if lifecycleCoordinator.shouldPause {
    log?.append(SessionEvent.stepEnd, .init(turn: turnNo, step: stepNo, reason: "bg-suspended"))
    await lifecycleCoordinator.waitForeground()   // CheckedContinuation 等 willEnterForeground
    // 恢复后重新 begin bgTask 再继续
}
```

LLM 流式步骤中途无法暂停（流是活的）——这是对的：流式期间进程在做有用功，bgTask 覆盖它；真正要防的是"流 hang 死"（§5.1 的 90s 检测）。

---

## 7. iPad 特有适配

| 项 | 现状 | 建议 | 优先级 |
|---|---|---|---|
| 分屏双 active | 天然支持，无影响 | 无 | — |
| Slide Over 失焦 .inactive | 任务继续跑 | 无需保活（不算 background）；勿把 .inactive 误当 .background 处理——**RootView.swift:120 的 `sp == .background` 判断是对的，保持** | — |
| 台前调度窗口尺寸 | dragHandle 有 min/max（RootView.swift:163-166）；composer/右栏无塌缩态 | 窗口 < 500pt 时右栏自动塌缩为 rail | P3 |
| 外接键盘快捷键 | rightRow 显示了 Ctrl+Shift+G 等（RootView.swift:497-499）但**无实现** | `.keyboardShortcut()` 绑定 /new /compact /terminal | P3 |

---

## 8. 适配清单（按优先级）

### P0（不做则后台必出事故）
1. **接通 governor**：新建 LifecycleCoordinator，`didEnterBackground → ISHKernel.shared.beginBackgroundCPUGovernor()`、`willEnterForeground → end`、启动时已在后台也 arm。改动点：新文件 + RootView 移除 scenePhase 分支。这是把 ISHKernel.m:1779-1825 死代码激活的一行式修复。
2. **MemoryPipeline.kick 包 beginBackgroundTask**：RootView.swift:119-123 处（或管线内部）申请 "MemoryPipeline" bgTask；expiry 回调里取消 Phase1 流并复位 `running` 标志（否则 thaw 后 defer 复位语义不确定）。
3. **AgentSession 循环 bgTask + 间隙暂停**：runTurn 期间持有 "AgentLoop" bgTask；expiry 置 pause 标志，循环顶部 park（§6.3）。

### P1（体验与数据正确性）
4. **流中断分级处理**：§5.1 的三条路径 + scenePhase.active 时 90s hang 检测。
5. **悬尾 turn 恢复**：load() 检测无 turn/end 的悬尾，UI 提供"继续"。
6. **审批死卡修复**：resume 后 approval/request 无 decision 时给可用的续跑路径。
7. **后台启动 arm governor**（并入 #1 的时机三）。

### P2（稳健性）
8. turnEnd 事件后 SessionLog `synchronizeFile()`（SessionLog.swift writeLine 处对 turnEnd 类型特判）。
9. write_file 类工具命令尾部 `sync`（AgentSession.execToolCall L478 命令串拼接）。
10. MemoryPipeline 从 @MainActor 摘到独立 actor。

### P3（增强）
11. 审批请求本地通知（UNUserNotificationCenter）。
12. 键盘快捷键实现；窄窗口右栏塌缩。
13. 评估 L3 保活（audio/location 模式）是否上 App Store——若上，照 OpenMinis BackgroundKeepAliveManager + iSH Info.plist:56-58 的模式，并补 Live Activity。

---

## 9. 参考实现索引

| 主题 | 位置 |
|---|---|
| governor 实现（闭环/滑窗/三档/poke/trylock） | QingShan/Platform/ISHKernel.m:1581-1830；头文件 ISHKernel.h:179/183 |
| governor 接线样板（含后台启动 arm） | repos/OpenMinis/.../Agent/Background/BackgroundKeepAliveManager.swift:387-459 |
| bgTask 过期治理（re-arm vs suspend 决策树） | repos/OpenMinis/.../Agent/Chat/AIChatViewModel+BackgroundTask.swift:12-93, 427-501 |
| bgTask 拒绝检测（.invalid） | repos/OpenMinis/.../Agent/Backup/BackupActivityLock.swift:25-39 |
| iSH 原版后台保活（location 模式） | repos/ish-arm64/.../app/Info.plist:56-58 + LocationDevice.m:50-54 |
| 青山唯一生命周期代码 | QingShan/QingShan/RootView.swift:119-123 |
| 事件溯源容错（半行丢弃） | QingShan/QingShan/AgentCore/SessionLog.swift:144-146 |
