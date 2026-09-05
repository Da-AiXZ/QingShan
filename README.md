# 青山 (QingShan)

作者自己的 iPad 本地 AI Agent —— SwiftUI 原生界面 + 内嵌 iSH(ARM64) Linux 沙箱（Alpine 3.21）执行底座。Agent 工程架构参考 [dsh](https://github.com/deepseek-ai/deepseek-harness)（DeepSeek 官方 Harness），记忆系统设计参考 Codex（补 dsh 之缺），界面以自研 HTML 原型为基准。

- 状态：**M0-M6 ✅ 已完成并真机验收**（沙箱/执行桥/事件溯源/真模型/工具审批/持久 PTY/记忆系统）；当前进行健壮性加固（批 2）与能力扩展（M7）。详细进度见 [docs/完成度总账.md](docs/完成度总账.md)。

## 构建与安装

1. GitHub Actions 自动构建（push 到 main 触发），在 [Actions](https://github.com/Da-AiXZ/QingShan/actions) 页面下载 `QingShan-ipa` artifact
2. 解压得到 `.ipa`，用 [TrollStore](https://github.com/opa334/TrollStore) / [Sideloadly](https://sideloadly.io) / AltStore 侧载到 iPad
3. iOS 16.0+，iPad 优先（横屏）

## 能力一览

- **持久 Linux 沙箱**：Agent 的命令在 Alpine 环境执行，cd/export 状态跨调用保持
- **流式对话**：DeepSeek/OpenAI 兼容 API（BYOK，密钥存 Keychain）
- **工具系统**：run_command / read_file / write_file，审批策略三档（每次问/危险才问/完全访问）
- **记忆系统**：会话自动提炼可复用记忆（21 天未用淘汰），文件存储用户可查可编辑
- **会话溯源**：JSONL 事件日志，杀 App 重开对话原样恢复

## 文档

- [完成度总账](docs/完成度总账.md) —— 权威现状与计划
- [AGENTS.md](AGENTS.md) —— AI 代理上手入口
- [docs/analysis/](docs/analysis/) —— 对标分析手册（dsh 参数/iSH 环境/iOS 生命周期/失败模式/外部情报）

## License

GPL-3.0（因静态链接 [ish-arm64](https://github.com/OpenMinis/ish-arm64)）。详见 LICENSE。
