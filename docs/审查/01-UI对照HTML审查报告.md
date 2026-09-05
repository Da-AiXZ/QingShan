# 「青山」UI 对照审查报告：React 原型 vs SwiftUI 实现

- **日期**：2026-09-05
- **审查人**：audit-ui-html（独立审计员）
- **基准**：`F:\AppData\GameViewer\Download\agent-prototype.html`（2205 行，已逐行读完）
- **被审**：`QingShan/QingShan/` 下 RootView / Sidebar / ComposerKit / Sheets / SettingsSheet / Toast / SessionStore（已逐行读完），并对 AgentCore、Approval.swift 等做了交叉 grep 验证（避免误判"未找到"）
- **方法**：先列全 HTML 组件清单（含 CSS-only 效果），再逐组件对照 Swift 源码。框架差异（React div↔SwiftUI VStack、useState↔@State、hover 样式↔常显）不算差异；审的是功能与交互语义。HTML 中的 mock 演示剧本（runDemo/runGenericReply 的假数据流）按"交互链路语义"审，不要求复刻假数据。
- **搜索口径**：凡判 "Swift 中未找到"，均已用关键词（queued/排队、interrupt/中断、plan、explored、system role、KeyEquivalent/keyboard、diff、Browser 等）在 `QingShan/QingShan` 全目录 grep 确认。

## 总判定统计

| 判定 | 数量 |
|---|---|
| ✅ 完整实现 | **26** |
| ⚠️ 部分或简化 | **22** |
| ❌ 未实现 | **9** |

---

## 一、消息流（HTML 行 769–917）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| MsgUser 右对齐气泡 | 784–786 | 用户消息行（左对齐灰底块，非右侧气泡） | RootView.swift:369–379 | ✅ | 版式不同（框架/设计取向），消息本体+文本选择完整 |
| 用户消息「已排队」徽章 + 排队机制 | 785, 901, 1660–1667, 1827–1843 | 未找到 | 全目录 grep `queued/排队/queue` 仅命中工具 description | ❌ | running 时发送不会排队，无排队徽章、无 +N 排队中、无 flushQueue 串行化 |
| MsgAssistant 流式输出 + 光标 | 787–789, 1632–1643 | agent 消息行，真实 LLM 流式 | RootView.swift:380–384；AgentSession.swift 流式 | ✅ | 真实流式优于原型逐字 mock；末尾无闪烁光标（观感级） |
| MemBadge / renderRich `[[mem|…]]` 悬浮记忆徽章 | 769–782, 1701 | 直接剥离不显示 | RootView.swift:744–751 `strippingMemCite`（grep `<qs-mem-cite>`） | ❌ | 记忆引用语义被丢弃：原型中用户可见"记忆来源"徽章+悬浮说明 |
| MsgThink 折叠思考行（Thinking→Think·摘要·chev 展开） | 794–807, 1621–1626 | ThinkRowView 同语义 | RootView.swift:763–800 | ✅ | spinner 态/摘要/展开全文/chevron 全对齐 |
| MsgThinking 斜体简单行 | 790–792, 1959 | 无对应 role | AgentSession.swift:21 Role 枚举无此项 | — | HTML 中亦无任何数据使用该类型（死代码），不计差异 |
| MsgSystem 系统提示行（中断/压缩/工作树等反馈） | 808–810, 1777, 1802, 2036… | 无 system role，反馈走 Toast | RootView.swift:219/225 用 Toast；grep `case system` 仅 LLMTypes.swift:8（LLM 协议层） | ❌ | 系统事件不再留在消息流里，历史不可回溯 |
| MsgPlan 计划步骤卡（done/doing/todo + 计数） | 811–818, 1683–1688 | 无 plan role，grep `plan` 无 UI 实现 | AgentSession.swift:21；RootView.swift:367–392 switch 无 plan 分支 | ❌ | 计划模式（/plan、addmenu 计划模式）无任何呈现载体 |
| MsgTool 工具行（状态点/verb 着色/耗时/chev/展开输出） | 819–839 | ToolMessageRow 同语义 | RootView.swift:881–928 | ✅ | ok/fail/denied/spin、耗时、展开输出全有；verb 着色简化为统一文案 Ran/Running/Denied |
| 工具输出 `__MORE__`「+N lines」截断 | 834–836 | 展开显示全量输出 | RootView.swift:916–925 | ⚠️ | 无截断与"更多"行（真终端场景可接受，观感级） |
| MsgExplored 探索聚合行（Explored N 个动作 + tag 项） | 840–851, 1704–1710 | 无 explored role | grep `explored` 全目录无命中 | ❌ | 探索类动作直接散落为多个 tool 行，无聚合折叠 |
| MsgApproval 审批卡（3 按钮 + 已决态 this time/every time） | 852–872 | ApprovalInlineRow 全对齐 | RootView.swift:803–877；Approval.swift:27–31 | ✅ | 标题固定"Agent 想执行命令"（HTML 为每次定制标题，如"新建文件 LoggerFacade.swift"）——minor |
| DiffBlock 逐行 diff（+/−/hunk/可展开省略行/行号） | 875–892, 644–697 | 未找到 | grep `diff` 仅审查 tab 文案 | ❌ | 全 App 无任何 diff 渲染；审查 tab 与工具行展开都只显示纯文本输出 |
| StatusLine（Working(Xs•esc to interrupt)·状态文本·排队数·点击中断） | 895–903, 1976 | 仅"Agent 工作中…"spinner 行 | RootView.swift:336–341 | ⚠️ | 无秒计时、无 esc 提示、无排队数、不可点击（见"中断"行） |
| 运行中断（点击 statusline / Esc → system 提示、保留上下文） | 1772–1778, 1846–1860 | 未找到（仅终端 tab 有 stop 按钮停独立命令） | RootView.swift:549–555；grep `interrupt` 仅 AgentSession 流错误语义 | ❌ | Agent 运行中无法人工中断 |
| EmptyHero 标题+副题+4 建议卡填入输入框 | 906–917, 637–642, 1954 | 同语义 | RootView.swift:266–315；Sidebar.swift:80–85 | ✅ | 点卡后 HTML 会 focus 输入框，Swift 仅赋值（minor） |

## 二、左栏 Sidebar（HTML 行 919–1000）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| 侧栏头：logo 方块 + 标题 + 收起 + 新建对话 | 933–939 | 收起+标题+新建，无 logo 图形 | Sidebar.swift:124–144 | ⚠️ | 缺渐变 logo 图标（观感级） |
| 搜索框 + 清除按钮 + 过滤 | 940–943, 948 | 同语义 | Sidebar.swift:147–165, 229–232 | ✅ | |
| 项目分组：置顶组 + 项目组 + 新建 + | 977–990 | 同语义 | Sidebar.swift:174–188, 213–223 | ✅ | |
| 项目行：chevron/色块/名称/会话数/pin/行内+ | 952–961 | 同语义 | Sidebar.swift:238–268（pin 常显，框架差异） | ✅ | |
| 会话行：选中态/标题/空白占位 | 962–963, 55–59 | 同语义 | Sidebar.swift:290–323 | ✅ | |
| 双击重命名（inline input，Enter/Esc）+ 悬浮铅笔 | 962–971 | 仅铅笔按钮进入重命名；无双击手势 | Sidebar.swift:296–322（无 onDoubleClick/onTapGesture(count:2)） | ⚠️ | 重命名功能存在且持久化（SessionStore.swift:61–65），缺双击入口与 Esc 取消 |
| 运行中会话 rdot 蓝色脉冲 | 60–61, 963 | 无 running 指示；橙点=当前选中 | Sidebar.swift:71–75（SessRowItem.running 恒 false）、292–294 | ⚠️ | running 字段存在但从未赋值；选中点与运行点语义错位 |
| 「展开显示（还有 N 个）」 | 973 | 同文案 | Sidebar.swift:274–280 | ✅ | |
| 「无匹配会话」/「暂无项目」空态 | 974, 989 | 同文案 | Sidebar.swift:181–185, 281–285 | ✅ | |
| 底部 4 项：任务队列/插件 MCP/记忆/设置 | 993–998 | 同 4 项 | Sidebar.swift:195–201, 331–346 | ✅ | |
| 底部徽章计数（任务 N / 插件 N 启用 / 记忆 N） | 994–996 | badge 全部传 nil | Sidebar.swift:196–199 | ⚠️ | 无任何计数徽章 |

## 三、右栏多面板（HTML 行 1063–1074, 1343–1529, 2134–2180）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| 右栏空态：4 行入口 + kbd 快捷键 | 2134–2147 | 4 行入口+kbd | RootView.swift:494–519 | ✅ | 但「浏览器」行 openTab("term") 指向错误（见下） |
| 多 tab：开/切/关/「+」tabmenu/收起按钮 | 2148–2174 | tab 开关切关 + Menu 增项 | RootView.swift:433–492 | ✅ | Menu 无"均已打开"空态提示（minor） |
| TermPanel（彩色行/自动滚底/running spinner） | 1064–1074 | 真实终端输出流 + 手动命令输入 + 运行/停止 | RootView.swift:522–569；ConsoleHub RootView.swift:13–37 | ✅ | 超出原型：可真实执行命令；无 prompt 着色分级（观感级） |
| ReviewTab2：分支头 +/−统计 + 提交或推送(toast) | 1471–1479 | 简化头：分支名+"N 次操作" | RootView.swift:587–596 | ⚠️ | 无推送按钮、无 +/− 增删统计（数据源无 diff） |
| ReviewTab2：未跟踪过滤条 + 刷新 + 复制清理命令 | 1482–1491 | 无 | RootView.swift:572–625 无对应 UI | ⚠️ | 未实现（依附于 git 数据，当前无 git 集成） |
| ReviewTab2：文件块折叠 diff + 首个自动展开 | 1492–1504 | 工具操作卡列表（状态图标+耗时+输出预览 6 行） | RootView.swift:597–620 | ⚠️ | 无逐行 diff、无折叠、无文件路径分组；以"操作流水"替代"变更视图" |
| ReviewTab2：右侧文件树（目录分组+点击跳转+筛选） | 1506–1526 | 无 | grep 无对应实现 | ⚠️ | 未实现 |
| ReviewTab2 / ReviewPanel 空态文案 | 1024–1027, 1467–1470 | 同语义文案 | RootView.swift:576–585 | ✅ | |
| 浏览器面板 BrowserPanel（导航栏/URL/回车/刷新/mock 页/空态） | 1344–1382, 1908–1910 | 未找到；空态"浏览器"行误开终端 tab | RootView.swift:499 `rightRow("safari","浏览器","Ctrl+T","term")` | ❌ | 面板整体缺失，且入口错指向 term |
| FilesPanel：递归树/筛选/面包屑/行号代码视图/空态 | 1384–1441 | 扁平文件列表（find maxdepth 2），点击→终端 cat 预览 | RootView.swift:628–652, 724–730 | ⚠️ | 真数据可用，但无树形/筛选/内嵌带行号预览（跳终端查看） |

## 四、Composer 与浮层（HTML 行 1578–2129）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| 项目 chip + 弹层（搜索/列表/新建/解除关联） | 1995–2023 | ProjectPopView 同语义 | ComposerKit.swift:359–395, 644–653 | ✅ | |
| 工作环境 chip + 弹层（本地/工作树/Web/云端） | 2024–2050 | EnvPopView 4 项 | ComposerKit.swift:399–417, 654–663 | ⚠️ | worktree/网页关联仅改 meta+Toast（RootView.swift:215–220），HTML 则向消息流推送 system 反馈 |
| 分支 chip + BranchPop（搜索/列表/创建 Enter/Esc） | 2051–2059, 1290–1316 | BranchPopView 同语义 | ComposerKit.swift:307–355, 664–673 | ⚠️ | 实现✅；但新建项目 git=false（Sidebar.swift:61）导致 chip 永不出现，与 HTML 新建项目 git:true 不符 |
| addmenu「+」chip（文件/Work/目标/计划模式） | 2069–2092 | 同 4 项 | ComposerKit.swift:701–725 | ✅ | 目标/计划模式两侧均为占位（HTML 假 system 消息 vs Swift Toast「M7 交付」） |
| 审批策略 chip + 3 档弹层 | 2094–2107, 591–595 | PolicyPopView 3 档联动 | ComposerKit.swift:421–444, 674–680 | ✅ | |
| CtxRing 圆环（70/90 变色） | 1540–1548 | CtxRingView 同语义（真实 token 估算） | ComposerKit.swift:147–160, 47–54 | ✅ | |
| CtxPop（百分比+K 用量+5 段构成条+明细行） | 1549–1569, 1532–1539 | 单条进度条 + 压缩按钮 | ComposerKit.swift:164–209 | ⚠️ | 无系统提示词/工具/对话/MCP/技能 5 段构成；多出"立即压缩"入口（加分项） |
| 模型 chip + ModelEffortPop（滑块态⇄列表态 5 模型+BYOK） | 1258–1288, 2117–2124 | 滑块态 + 列表态仅当前 BYOK 模型 + BYOK 设置入口 | ComposerKit.swift:252–303, 681–690 | ⚠️ | 无多模型列表可选（原型 5 档模型单选） |
| EffortSlider 渐变填充/刻度/拖拽/高档警告 | 1236–1256, 1286 | EffortSliderView 同语义 | ComposerKit.swift:213–248, 288–294 | ✅ | |
| 发送按钮（空输入禁用） | 2125 | 同语义 | ComposerKit.swift:622–632 | ✅ | |
| slash 菜单（12 命令过滤/无匹配）+ execCommand | 602–615, 1980–1985, 1792–1824 | 12 命令菜单+过滤 | ComposerKit.swift:513–528, 542–545；RootView.swift:401–413 | ⚠️ | 缺 /diff /init /plan /export /rename（HTML 有）；多出 /terminal /files /settings /tasks /plugins /help；未知命令 HTML 回 system"未知命令"，Swift 静默（default: break） |
| @ 引用文件菜单（光标处触发，替换插入） | 1878–1893, 1986–1991 | 真沙箱文件列表，仅当整行以 @ 开头才触发 | ComposerKit.swift:530–537, 546–550 | ⚠️ | 仅行首 @ 生效，文本中途 @ 不触发；插入后不可续搜 |
| Enter 发送 / Shift+Enter 换行 / 自动增高 | 1890–1899, 2062–2065 | TextField axis vertical lineLimit(1…6) onSubmit | ComposerKit.swift:592–597 | ✅ | Shift+Enter 由系统文本输入行为承担 |
| ctxbar（项目·会话·模型·推理档） | 1944–1950 | 同语义 + 额外设置按钮 | RootView.swift:243–263 | ✅ | |
| ctxwarn（剩<25% 提示 /compact） | 1973–1974 | used>75% 同义触发，文案"已用 N%" | RootView.swift:349–364 | ✅ | 文案视角略异（剩余% vs 已用%），语义一致 |

## 五、弹层 Sheets（HTML 行 1077–1231）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| Sheet 壳（遮罩/标题/关闭） | 1077–1086 | SheetShell | Sheets.swift:5–44 | ✅ | |
| Toggle 开关 | 1087, 260–263 | ToggleSw | Sheets.swift:48–59 | ✅ | |
| SettingsSheet·权限区（默认授权切换/完全访问红字警告） | 1092–1102 | 无 | SettingsSheet.swift 全文仅模型服务+使用说明 | ⚠️ | 设置弹层缺权限分区（策略改由 composer policy chip 承担，但设置页无入口） |
| SettingsSheet·BYOK（base/key/model/保存态） | 1103–1113 | 同语义 + Keychain/清除 Key | SettingsSheet.swift:39–84 | ✅ | BYOK 本体完整且更安全 |
| SettingsSheet·记忆区（自动提炼/仅充电/保留期 21 天徽章） | 1114–1128 | 无 | grep `chargeOnly/自动提炼` 无设置项 UI | ⚠️ | 记忆策略三项配置缺失（记忆管线本身存在，RootView.swift:119–123） |
| SettingsSheet·Linux 环境区（版本徽章+重置→向导） | 1129–1135, 2185 | 无 | SettingsSheet.swift 无该分区 | ⚠️ | 无环境信息展示与"重置"入口 |
| MemoriesSheet：4 统计卡（配额/条目/被引用/即将淘汰） | 1139–1146 | 3 统计卡（条目/被引用过/管线状态） | Sheets.swift:126–131 | ⚠️ | 无 token 配额、无"即将淘汰"数 |
| MemoriesSheet：AGENTS.md 卡片（只读展示） | 1147–1150 | 可编辑+保存（超出原型） | Sheets.swift:133–167 | ✅ | 原型只读，Swift 可编辑——增强 |
| MemoriesSheet：记忆卡（引用数/上次使用/21 天淘汰进度条 ttlbar） | 1151–1159 | 有引用数/最近使用/删除，无淘汰进度条与剩余天数着色 | Sheets.swift:204–232 | ⚠️ | 缺 ttl 可视化；新增删除按钮（增强） |
| TasksSheet（4 任务+状态徽章+提示行） | 1163–1173 | 诚实空态「M7 交付」 | Sheets.swift:254–266 | ⚠️ | 功能未实现（原型为 mock 数据展示层） |
| PluginsSheet（5 插件开关+添加按钮） | 1175–1185 | 诚实空态「M7 交付」 | Sheets.swift:270–282 | ⚠️ | 功能未实现 |
| SkillsSheet（4 技能+已安装徽章） | 1187–1201 | 诚实空态「M7 交付」 | Sheets.swift:286–298 | ⚠️ | 功能未实现 |
| CreateProjectSheet（名称 Enter/源文件夹 mock 区/取消/创建） | 1318–1342 | 同语义 | Sheets.swift:302–380；RootView.swift:669–673 | ✅ | 创建后 git=false 使分支/环境 chip 不可用（见分支行）⚠️ 已在分支行计 |
| Wizard 首启向导（5 步骤+进度条+跳过+完成按钮） | 1204–1231, 291–300 | 真实安装/启动两态状态行，无步骤列表 UI、无跳过 | RootView.swift:176–190, 683–741 | ⚠️ | 真实进度替代演示向导（方向正确），但无分步呈现与"进入主界面/跳过"按钮 |

## 六、App 全局交互（HTML 行 1571–2199）

| HTML 组件/功能 | HTML 证据 | Swift 现状 | Swift 证据 | 判定 | 差距描述 |
|---|---|---|---|---|---|
| 会话新建/选择/切换（清 revFilter 等） | 1781–1789 | newChat/load(sessionID:) | RootView.swift:126–132, 78–79；SessionStore.swift:20–34 | ✅ | 真实 JSONL 持久化 |
| 重命名会话（/rename + 左栏） | 1822, 927–930 | 左栏铅笔重命名（无 /rename 命令） | Sidebar.swift:305–312；SessionStore.swift:61–65 | ✅ | 功能在（入口少一个，已计入 slash 差距） |
| 排队与 flushQueue | 1660–1667, 1837–1839 | 无 | grep 无 | ❌ | 已计入消息流行 |
| 中断运行 | 1772–1778 | 无 | grep 无 | ❌ | 已计入消息流行 |
| 键盘快捷键（Ctrl+Shift+G / Ctrl+` / Ctrl+T / Ctrl+P；Esc 优先级：面板→浮层→中断） | 1846–1860 | 未找到 | grep `KeyEquivalent/keyboard/esc` 无命中 | ❌ | 全部快捷键缺失（iPad 外接键盘场景失效；Esc 关浮层也无） |
| 拖拽调宽左右栏（含限幅） | 1862–1873 | dragHandle 手势 | RootView.swift:156–170 | ✅ | 限幅不同（180–420/260–620 vs 200–360/320–560），可接受 |
| 收起 rail（左：展开/新建/设置；右：展开） | 1927–1931, 2132–2133 | 左右 rail 仅展开按钮 | RootView.swift:136–152 | ⚠️ | 左 rail 缺"新建对话/设置"两个快捷按钮 |
| 消息流自动滚底 | 1656–1658 | onChange 滚底 | RootView.swift:317–329 | ✅ | |
| Toast 提示（HTML 用 system 行/徽章 toast） | 1475–1476 等 | ToastCenter+ToastOverlay（Swift 特有载体） | Toast.swift:13–70 | ✅ | 作为 system 行缺失的补偿载体，但不可回溯（已计入 MsgSystem 差距） |
| 流式回复引擎 / Think 流式→折叠 | 1621–1643 | 真实 LLM 流式 | AgentSession.swift:306–320 | ✅ | |
| 主演示剧本 runDemo/continueDemo/decide 链路 | 1680–1770 | 真实 Agent 工具循环（run_command 等） | AgentSession.swift（工具定义 40–65） | ✅ | 语义对齐（真执行替代演示）；但 plan/explored/diff 呈现缺失使链路观感不完整（已分计） |

---

## 差距修复清单（按优先级）

### P0 — 核心交互缺失（主链路断裂）
1. **排队机制**：running 时发送应入队（消息加"已排队"徽章→状态行显示 +N→结束后 flushQueue 依次执行）。HTML 1660–1667/1837–1843。
2. **运行中断**：StatusLine 可点击中断 + Esc 中断，中断后插 system 提示、保留上下文。HTML 1772–1778。
3. **system / plan / explored 三种消息类型**：补 ChatMessage role 与渲染（计划步骤卡、探索聚合行、系统提示行），否则"思考→计划→探索→审批→diff"演示链路无法完整呈现。HTML 808–851。
4. **浏览器面板**：右栏第 4 个 tab 整体缺失，且右栏空态"浏览器"行错开终端 tab（RootView.swift:499），属可见 bug。
5. **键盘快捷键**：Ctrl+Shift+G / Ctrl+` / Ctrl+T / Ctrl+P / Esc 优先级链（iPad 外接键盘 + 触控板场景）。

### P1 — 功能不完整
6. **审查 tab 强化**：逐行 DiffBlock 渲染（含可展开省略行）、+/− 统计、文件树侧栏与跳转、筛选框。HTML 1443–1529。
7. **设置弹层补 3 分区**：权限（默认授权/完全访问联动）、记忆策略（自动提炼/仅充电/保留期）、Linux 环境信息+重置。HTML 1092–1135。
8. **slash 命令集对齐**：补 /diff /init /plan /export /rename；未知命令回显（HTML 为 system 行，Swift 可用 Toast）；@ 引用支持文本中部触发。
9. **ModelEffortPop 模型列表**：列表态应提供多模型可选（或按 BYOK 语义明示仅一档）。HTML 1263–1277。
10. **新建项目 git=true**：使分支/环境 chip 对新项目可用（Sidebar.swift:61）。
11. **运行中会话 rdot**：SessRowItem.running 接入真实状态（当前恒 false），左栏蓝点脉冲。
12. **StatusLine 补全**：秒计时、状态文本（statusText）、排队数。
13. **CtxPop 5 段构成**（系统提示词/工具/对话/MCP/技能分段条+明细）。
14. **双击重命名**会话行（保留铅笔按钮，补双击手势 + Esc 取消）。
15. **FilesPanel 树形化**：递归目录树 + 筛选 + 内嵌带行号预览（当前跳终端 cat）。
16. **底部徽章计数**：任务队列 N / 插件 N 启用 / 记忆 N（Sidebar.swift:196–199 传 nil）。
17. **任务/插件/技能三弹层**按 M7 计划交付真实功能（当前诚实空态，可接受但需排期）。

### P2 — 观感打磨
18. 收起 rail 左侧补"新建对话/设置"按钮。
19. 工具输出"+N lines"截断样式；MsgAssistant 流式末尾光标。
20. 审批卡标题使用具体动作描述（HTML 每次定制 title）。
21. ctxwarn 文案改为"剩余 N%"口径对齐原型；侧栏补 logo 图形。
22. 环境弹层 worktree/关联 Web 的反馈从 Toast 改为消息流 system 行（依赖 #3）。
23. 空态右栏补收起按钮（rempty-collapse）与 tabmenu"均已打开"提示。

## 备注与边界说明
- HTML 中 `ReviewPanel`（1008–1061）为被 ReviewTab2 取代的死代码，未计入对照。
- HTML `MsgThinking`（790–792）无任何数据使用，视为死代码，未计入差异。
- Tasks/Plugins/Skills 的"诚实空态"是 Swift 侧的有意设计决策（Sheets.swift:85 注释），本次按"功能未实现"计 ⚠️ 而非 ❌，因其不破坏既有交互闭环。
- 框架性不判定项：CSS hover 态（SwiftUI 无 hover，按钮常显或依赖轻点）、`prefers-reduced-motion`、滚动条样式。
