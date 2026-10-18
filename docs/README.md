# 文档索引

核对日期：2026-10-18。当前以 `main` 的 macOS 原生 CLI / PTY 工作台为准。

## 当前维护

| 文档 | 用途 |
| --- | --- |
| [项目说明](../README.md) / [English](../README.en.md) | 安装、使用、快捷键和源码构建 |
| [产品范围](ycode-feature-spec.md) | 当前功能、限制与暂缓事项 |
| [验收清单](bdd-iteration-plan.md) | 日常迭代的场景与证据要求 |
| [CLI 界面规则](cli-ui-policy.md) | PTY 交互与结构化界面的边界 |
| [Hook 对接](agent-hook-integration-spec.md) | 当前 Swift 通知链、配置归属与限制 |
| [macOS 开发](../macos/README.md) | 开发构建、签名与隔离数据目录 |
| [GitHub 构建与发布](macos-native/github-release.md) | CI、签名、公证、Sparkle 与发布操作 |
| [编辑器范围](macos-native/manual-editor-scope.md) | 文件查看、基础高亮、手动编辑保存 |
| [画布过渡](macos-native/canvas-transition.md) | AppKit 布局动画与验证边界 |
| [标题同步](macos-native/session-title-sync.md) | 各 CLI 标题适配与当时的验证记录 |
| [网站维护](../website/README.md) | 静态站点、演示视频与部署 |

## 暂缓与研究

- 原生会话界面与统一输入入口保留在本地分支 `codex/unified-session-entry`；设计、实现与验收记录在该分支维护，未纳入 `main`。
- Pi 继续作为普通 CLI 使用；不再保留以 Pi 为统一底座的实施方案和对话原型。
- worktree 创建、任务级隔离、合并与自动回收未接入原生工作流；原有元数据保留，不自动恢复隔离会话或改成主目录运行。
- [Computer Use](computer-use-integration-plan.md) 仅保留研究边界，尚未立项。

## 历史记录与设计参考

[原生迁移总结](macos-native-refactor-plan.md)和[验收记录索引](macos-native/README.md)保留迁移过程、数据兼容、备份与回退依据。记录中的版本、路径、通过或阻塞状态仅对应当时环境；旧代码通过 Git 历史回溯。

以下 HTML 保留视觉和交互决策，页面内已标明参考状态；其中的示例数据、未实现控件和旧尺寸不作为当前验收要求。

| 设计参考 | 保留原因 |
| --- | --- |
| [原生 UI 初稿](ui-native-redesign.html) | 已实施布局的早期决策 |
| [原生 UI 规格快照](ui-native-spec.html) | 2026-09 的界面结构与交互记录 |
| [视觉方向](ui-visual-direction.html) | 已选择方向 B 的配色与窗格依据 |
| [跨项目画布](canvas-cross-project.html) | 项目标识、焦点和面板归属的设计依据 |
| [更新窗口](update-window-redesign.html) | 自绘更新窗口的流程与状态参考 |
| [图标探索](icon-redesign.html) | 历次候选对照；实际图标源为 `macos/Resources/AppIcon.svg` |

已删除旧 Task/Worktree 设计、ACP 事件模型草案、React UI 迁移计划、Pi 对话原型及已被当前设置实现替代的旧设置稿；需要追溯时使用 Git 历史。

维护规则：功能变更同步产品范围和验收清单；操作命令同步对应开发或发布指南；历史记录只补充更正和替代关系，不把旧测试结果写成最新验证。
