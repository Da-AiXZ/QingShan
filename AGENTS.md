# AGENTS.md — 青山（QingShan）

> 本文件是给任何 AI 编码代理的项目入口。按"文档地图"顺序读，你就能完整接手。
> 最后更新：2026-09-05 ｜ 维护规矩：本文件随里程碑推进更新，过时内容必须删除。

## 项目是什么

**青山**：iPad 本地 AI Agent 应用。SwiftUI 原生 UI，内嵌 iSH ARM64 Linux 沙箱（Alpine 3.21），BYOK 接 DeepSeek/OpenAI 兼容 API。体验对标 OpenAI Codex CLI 与开源项目 dsh（DeepSeek Harness）。仅作者本人使用，TrollStore 侧载未签名 IPA，GitHub Actions 云构建（开发机为 Windows，无本地 macOS）。

- 仓库：`github.com/Da-AiXZ/QingShan`（公开，GPLv3）
- Bundle ID：`com.qingshan.juyang`

## 仓库地图

| 路径 | 职责 |
|---|---|
| `QingShan/` | App 源码（SwiftUI 视图 + AgentCore/） |
| `QingShan/AgentCore/` | Agent 核心：AgentSession（turn/step 循环）、SessionLog（JSONL 事件溯源）、PersistentShell（持久 PTY）、DeepSeekAdapter（SSE 流式）、MemoryStore/MemoryPipeline（记忆系统）、LLMTypes、FakeLLM |
| `Platform/` | OpenMinis 的 ISHKernel/ISHShellExecutor（iSH 启动编排与执行桥，生产验证版，勿轻易改） |
| `Vendor/ish/` | iSH-ARM64 源码（第三方，GPLv3；不要修改，meson 构建三静态库） |
| `scripts/` | build_ish.sh（交叉编译三静态库）、fetch_rootfs.sh（Alpine rootfs） |
| `.github/workflows/ios.yml` | CI：XcodeGen → xcodebuild 未签名 IPA → artifact（每次 push 触发） |
| `docs/` | **权威文档**（见下方文档地图） |
| `docs/审查/` | 四份独立审计报告（01-UI/02-dsh/03-Codex/04-架构） |
| `QingShan/Bridge/` | Swift-ObjC 桥接头 |

## 文档地图（新 AI 按此顺序读）

1. **`docs/完成度总账.md`** ← 权威现状账：逐模块 ✅⚠️❌、P0 缺陷清单、修复批次路线、12 维度对标分析清单（M6.7）。**先读这个**。
2. `docs/dsh语义对照笔记.md` — dsh/Codex 语义对照表（含每轮踩坑记录）
3. `docs/审查/01~04` — 四份独立审计报告（带双向源码行号证据）
4. 上层工作区（`../`）：`iOS端Agent-修正版架构方案.md`（架构基准）、`Codex记忆系统调研与移植方案.md`（记忆蓝本）
5. 参考源码（只读基准，勿改）：`../repos/deepseek-harness-master/`（dsh，TypeScript）、`../repos/codex-rust-v0.153.0-alpha.6/`（Codex，Rust）、`../repos/OpenMinis-main/`（Swift+iSH 参考）、`../repos/ish-arm64-master/`

## 构建与验证

- **构建只发生在 GitHub Actions**（push 自动触发，产物 `QingShan-ipa` artifact）。本地 Windows 无法编译 Swift——**push 前必须自查语法**（历史踩坑见 docs/审查 与 memory 日志）。
- CI 失败看 `gh run view <id> --log-failed`。
- 里程碑收尾：打 tag `v0.stage-N` + GitHub Release 存档 IPA。
- push 常见网络失败（环境代理 `HTTP_PROXY=127.0.0.1:55824` 间歇故障）→ **用重试循环直到成功**，不要放弃。

## 开发规矩（铁律，违反即返工）

1. **先读后写**：任何新模块/参数动工前，先读 dsh / Codex 对应源码（对照笔记有索引），禁止凭印象设计。
2. **参数不得拍脑袋**：dsh 的默认值（超时/重试/缓冲/上限）本身就是语义。对齐或有意偏离（写明理由）。
3. **诚实交付**：所有"没做/简化"必须记入 `docs/完成度总账.md`，不允许账外遗漏。
4. **假数据扫描**：交付前扫描——任何非用户产生、非真实 API 返回的数据不得出现在 App 里（演示数据只属于原型）。
5. **外部情报保鲜**：模型/API 会过时（deepseek-chat 已于 2026-07-24 下架）。涉及模型名/API 参数/上下文窗口，**先搜官方文档**再写代码。
6. **慢即是快**：一次只做一个可验收的小步；阶段末 tag + Release 存档；等用户真机验收后再进下一步。
7. 用户非技术背景：交付说明直白，验收标准 = 用户亲手可验证。

## 当前状态（2026-09-05）

- M0-M6 已完成并通过真机验收（tag v0.stage-0 ~ v0.stage-6）
- **进行中：M6.7 系统性对标分析**（5 路子代理产出 `docs/analysis/`，见总账附录 12 维度清单）
- 待做：批 2 能力补全（turn 取消/governor 接线/shell 自愈/项目隔离）→ 批 3 UI 对齐 → M7（任务队列/插件/技能）→ M8（测试/governor 实测/崩溃恢复/发布工程）
- 已知重要事实：DeepSeek 旧模型名已死（2026-07-24），现为 `deepseek-v4-flash`（thinking mode 是请求级参数）/`deepseek-v4-pro`，上下文 1M；V4-Flash 官方为 Codex 适配

## 边界（不要碰）

- `Vendor/` 与 `Platform/ISHKernel.*` 的内核逻辑（第三方生产代码，改前必须有实证理由）
- `.workbuddy/` 目录（会话记忆）
- 不要引入测试外的依赖（当前零 SPM 依赖是刻意设计）
- 不要删除 `.gitignore` 排除的构建产物规则

## Handoff 要求（每次改动的交接格式）

1. 改了什么（文件+意图）
2. 跑过什么验证（CI 链接 / 语法自查方式）
3. 遗留风险与未完成项（回写总账）
