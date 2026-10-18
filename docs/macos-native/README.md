# 原生迁移与实现记录

更新：2026-10-18。M0–M5 是历史验收编号，迁移总结见[上一级](../macos-native-refactor-plan.md)；当前功能以[产品范围](../ycode-feature-spec.md)为准。

## 当前维护参考

- [构建与发布](github-release.md)：CI、签名、公证与 Sparkle 操作。
- [文件查看与手动编辑](manual-editor-scope.md)：当前编辑器范围；LSP 已移除。
- [画布过渡](canvas-transition.md)：原生动画实现与验证边界。
- [标题同步](session-title-sync.md)：CLI 标题适配及当时的测试结果。

## 历史验收

以下文档保留当时的版本、状态、测试数量、日志和备份位置，不表示这些结果已在当前代码上重验。旧源码路径、已移除的 LSP / 收件箱、早期互斥检查器和旧设置形态仅用于回溯。

发布链已在后续实现；M5.3 / M5.4 当时的证书阻塞不作为当前环境结论。实际发布与升级需按发布指南单独确认。`/tmp`、本地 dist 和用户目录中的历史证据使用前检查存在性。

| 记录 |
| --- |
| [M0.1 功能对照表（冻结清单）](M0.1-feature-inventory.md) |
| [M0.2 旧版运行基线与性能预算](M0.2-baseline.md) |
| [M0.3 原生终端验证与选型](M0.3-terminal-spike.md) |
| [M0.4 原生编辑器 / 预览验证与架构决策](M0.4-editor-preview-spike.md) |
| [M1.1 原生工程骨架验收](M1.1-project-skeleton.md) |
| [M1.2 SQLite / JSON 数据兼容验收](M1.2-data-compatibility.md) |
| [M1.3 原生项目工作区验收](M1.3-project-workspace.md) |
| [M1.4 设置、命令与界面状态验收](M1.4-settings-ui-state.md) |
| [M2.1 Agent 配置与启动环境验收](M2.1-agent-environment.md) |
| [M2.2 会话进程池与生命周期验收](M2.2-session-lifecycle.md) |
| [M2.3 原生终端画布验收](M2.3-terminal-canvas.md) |
| [M2.4 项目辅助 Shell 与分屏验收](M2.4-project-shell-splits.md) |
| [M2.5 项目独立窗口、焦点与快捷键验收](M2.5-project-windows.md) |
| [M3.1 Claude/Codex 历史扫描、解析、展示与搜索](M3.1-history-introspection.md) |
| [M3.2 历史恢复与用量统计](M3.2-history-resume-usage.md) |
| [M3.3 待办界面与 Swift Todo MCP](M3.3-todos-mcp.md) |
| [M3.4 Agent hook、通知与关注收件箱](M3.4-hooks-notifications.md) |
| [M3.5 Swift CLI、深链与安装管理](M3.5-cli-deep-links.md) |
| [M4.1 文件树与文件操作](M4.1-file-tree.md) |
| [M4.2 多标签编辑器与保存冲突处理](M4.2-editor-save-conflicts.md) |
| [M4.3 语法高亮与原生内容预览](M4.3-syntax-native-preview.md) |
| [M4.4 LSP 安装管理与协议接入](M4.4-lsp-integration.md) |
| [M4.5 Git 状态、Diff、提交与普通分支](M4.5-git-branch.md) |
| [M4.6 普通项目目录检查点与逐轮审阅](M4.6-checkpoints.md) |
| [M5.1 全量设置、主题、语言、字号及窗口恢复](M5.1-settings-appearance.md) |
| [M5.2 全量功能回归与性能稳定性](M5.2-regression-stability.md) |
| [M5.3 原生安装包、更新与签名发布链](M5.3-release-update-signing.md) |
| [M5.4 正式数据切换及回退演练](M5.4-cutover-rollback.md) |
| [M5.4-local 本地自用切换](M5.4-local-selfuse.md) |
| [M5.5 移除旧实现和其他平台构建](M5.5-legacy-removal.md) |

## 其他历史记录

- [原生 UI 实施记录](ui-redesign-implementation.md)：2026-09 的布局与交互演进，后续形态以源码为准。
- [本地自用记录](local-selfuse-log.md)：已记录的问题及当时环境；四周观察期已不再是源码清理门槛。

新增功能的当前验收场景维护在[验收清单](../bdd-iteration-plan.md)，无需继续扩充迁移编号或复制历史“通过”状态。
