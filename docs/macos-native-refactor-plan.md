# macOS 原生迁移总结

更新：2026-10-18。原生替换与旧源码清理已完成，项目进入原生版本维护；本文替代原迁移排期，不再把 M0–M5 当作当前待办。

当前功能以[产品范围](tandock-feature-spec.md)为准，日常检查见[验收清单](bdd-iteration-plan.md)，各阶段原始证据见[迁移记录索引](macos-native/README.md)。

## 当前工程

| 层次 | 当前实现 |
| --- | --- |
| 应用与窗口 | `macos/TandockApp/`，SwiftUI / AppKit |
| 核心服务 | `macos/Core/`，项目、会话、PTY、SQLite、配置、历史、Git 与集成 |
| 文件编辑与预览 | `macos/EditorSupport/`，原生文本编辑、基础语法高亮、Markdown / SVG / 图片预览 |
| 辅助程序 | `macos/Helpers/`，`tandock`、`tandock-mcp`、`tandock-notify`；迁移探针位于 `macos/Tests/Tools/` |
| 依赖 | Swift Package Manager；SwiftTerm、swift-markdown、Sparkle、TOMLKit |
| 构建与分发 | `macos/scripts/` 和 `.github/workflows/`；最低系统 macOS 14，分发脚本构建 arm64 / x86_64 通用包 |

React / Tauri / Rust 应用代码及其构建链已于 2026-09-27 移除，见 [M5.5](macos-native/M5.5-legacy-removal.md)。应用构建不再依赖 Node 前端工程；外部 CLI 仍需要各自的运行环境。

## 迁移结果与后续决定

| 范围 | 结果与当前边界 |
| --- | --- |
| M0 组件验证 | 终端、编辑和预览验证程序保留在 `macos/Spikes/`，用于回溯组件选型 |
| M1 数据与工作区 | 原生工程、SQLite / JSON 兼容、项目与窗口状态已迁移；旧记录中的配置细节可能已被后续产品决定替代 |
| M2 会话与终端 | CLI 启动、生命周期、多会话画布、项目 Shell 和多窗口已迁移；现有标签页与面板形态以当前实现为准 |
| M3 历史与集成 | 历史、搜索、用量、待办、MCP、hook、CLI 与深链已迁移；关注收件箱界面后续移除，hook 状态和系统通知保留 |
| M4 文件与 Git | 文件、手动编辑、预览、Git 和检查点已迁移；LSP 于 2026-09-27 明确移除，不再作为后置功能 |
| M5 设置与收尾 | 原生设置、回归工具、通用包、切换及回退工具已落地，旧源码已清理 |
| 发布与升级 | CI、Developer ID / 公证、Sparkle 发布链已有实现；旧记录中的凭据缺失和“后置”只代表当时状态。当前操作见[发布指南](macos-native/github-release.md)，每次实际发布与升级结果另行验证 |

上述结论来自现有源码和历史记录核对；本次文档整理没有重新执行运行验收、发布或真实升级。

## 保留的兼容约束

- 项目、会话 ID、CLI 恢复标识、待办排序和时间戳、检查点元信息沿用原数据；SQLite 备份应包含 WAL 中的最新内容，不能只复制数据库单文件。
- JSON 配置保留未知字段、自定义 CLI 和未展开变量；不把敏感变量展开后回写。
- Claude Code、Codex、Pi 和自定义 CLI 通过真实 PTY 工作，不迁到统一模型引擎；历史读取不复制维护第二份 CLI 对话真相源。
- 原有 worktree 元信息、路径和分支保留；原生版未接入创建、合并或自动清理，不静默改成共享目录会话。
- 历史 `lsp_installations` 数据为兼容而保留，应用不再使用它启动语言服务器。
- 开发版本使用独立标识和数据目录。涉及旧数据的验证使用一致性备份副本；切换、恢复和回退应先核对 manifest 的模式及路径，操作说明见 M5.4 记录和 `macos/scripts/cutover.sh` 的用法说明。
- 本地备份与 `/tmp` 日志可能已过期；使用前检查实际文件，不把历史路径存在性作为默认前提。

## 不纳入当前排期

- worktree / Task 架构重做：旧方案依赖已移除的 Rust 实现，已清理，后续如立项需重新设计。
- Pi 原生对话底座：已取消当前实施计划，只保留普通 Pi CLI。
- 统一输入入口及原生 Codex / Claude 会话界面：暂缓在 `codex/unified-session-entry`，不继续合入主线。
- Computer Use：仅[研究状态](computer-use-integration-plan.md)，无固定引擎组合或里程碑。

## 查阅历史

M0–M5 的原始验收、版本、测试数量和未解决项保留在 [macos-native/](macos-native/README.md)。它们用于追溯当时的结果，不能代替当前回归或发行验收；当前构建入口见 [macOS 开发说明](../macos/README.md)。
