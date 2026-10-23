# Agent Hook 对接

更新：2026-10-18。本文描述当前 Swift 实现，替代旧 Rust / Tauri 生命周期事件扩展草案；未增加新的 hook 点或审批机制。

## 当前链路

```text
CLI hook → tandock-notify → Unix socket → TandockAgentHookListener
                                      → 按数据根共享的 AttentionStore
                                        → 需关注面板、侧栏、检查点、系统通知
```

启动环境提供 `YCODE_TERMINAL_ID`、每次受管启动新建的 `YCODE_RUN_ID` 和 `YCODE_NOTIFY_SOCK`。helper 发送单行 JSON，包含终端 ID、运行代次、来源、事件名、stdin 与额外参数。共享服务核对终端、当前运行代次、来源、归档状态与可用的原生会话 ID 后才接受事件，不把 hook 解释为用户任务已验收。

| CLI | 写入配置 | 当前接入点 |
| --- | --- | --- |
| Claude Code | `~/.claude/settings.json` | `Stop`；`Notification` 仅匹配 `permission_prompt` |
| Codex | `~/.codex/config.toml` | 顶层 `notify` 完成事件；`hooks.PermissionRequest` 审批关注事件 |

这些是本项目生成的配置，实际触发仍取决于所用 CLI 版本。Pi 与自定义 CLI 不套用上述安装器。

## 配置归属

- Claude 配置采用附加条目，以 `_ycode_managed` 标记。重复安装替换自己的条目，卸载只移除自己的条目，保留其他 hook 和配置。
- Codex 使用 `# ycode-managed` 管理 `notify`，用成对的 `# ycode-managed-hooks` / `# ycode-managed-hooks-end` 管理审批 hook。缺少任一部分不显示为完整安装。
- 已有用户 Codex `notify` 时返回冲突，默认不覆盖。服务支持经明确选择后用 `--next` 串联原命令；卸载恢复原参数。当前设置开关遇到冲突会显示冲突状态，不自动串联。
- 首次安装修改已有文件前保存 `<file>.ycode.bak`；卸载依据管理标记，不用整份备份覆盖后续用户修改。
- 配置写入是原子文件替换。格式错误或 helper 不可执行会返回错误；安装状态不等于已完成真实 CLI 触发验证。

## 事件与通知

- 事件保留终端、运行代次、来源与原始事件名；payload 提供时保留原生会话、轮次、请求和事件 ID（包括 Codex 的 turn-id）。缺少代次、旧运行、未知来源／事件、原生身份冲突和归档／删除会话不进入关注状态或通知。
- Claude 完成预览优先读取 payload 的 last_assistant_message，缺少时读取 transcript 最后一条助手文本；关注预览读取通知内容。Codex 完成预览读取 notify 参数，审批预览读取工具描述或命令；正文截取前 200 字符，超长时追加省略号。
- socket 接收帧上限 128 KiB；helper 发送超时与 listener 接收超时均设置为 200 ms。stdin 读取和串联用户命令不受此 socket 超时约束。
- listener 与关注服务由窗口共享；2 秒内相同运行、来源、事件身份和预览合并，有稳定事件 ID 时在当前运行内去重。重复更新保留首次时间；已读和收起操作仅确认所见版本。
- 系统通知只消费共享服务接受的分类，仍受原通知开关与前台策略控制，不随窗口数量重复发送。面板关闭仅隐藏，主窗口跨项目汇总，项目窗口固定范围。
- 白名单仅包含 Claude Stop、permission_prompt 与 Codex turn_complete、permission_request。完成事件可触发一次轮次检查点，并收起同一会话、同一运行中此前的审批提醒；若双方有轮次 ID 则须一致。较新或其他明确轮次的审批、其他会话及异常提醒保留。普通输出不改变关注或已读；异常退出单独提示，主动停止不视作失败。

## 行为边界

Tandock 自己的通知发送失败时保持零退出码，不借 hook 阻止工具、注入模型上下文或代替用户审批。使用 `--next` 时 helper 会转交原用户命令，后续退出行为属于该命令，不能承诺整条链恒为零。

当前未注册 `SessionStart`、`PreToolUse` 或 `PostToolUse`；不承诺实时工具卡片、首次编辑前检查点或由 hook 提供完整 transcript 绑定。这些旧草案中的扩展项不作为当前待办。会话标题与身份发现另见[标题同步记录](macos-native/session-title-sync.md)。

## 实现与检查入口

| 入口 | 作用 |
| --- | --- |
| [HookRegistration.swift](../macos/Core/Sources/TandockCore/HookRegistration.swift) | Claude / Codex 配置安装、状态、冲突与卸载 |
| [TandockNotify](../macos/Helpers/Sources/TandockNotify/main.swift) | 输入封装、socket 发送与 `--next` |
| [AgentHookNotifications.swift](../macos/Core/Sources/TandockCore/AgentHookNotifications.swift) | 解析、预览、监听与去重 |
| [HookRegistrationTests](../macos/Tests/TandockCoreTests/HookRegistrationTests.swift) | 用户配置保留、冲突、串联与幂等性 |
| [AgentHookNotificationTests](../macos/Tests/TandockCoreTests/AgentHookNotificationTests.swift) | payload、真实 helper、分帧、超时与通知策略 |

本次实现及验证分层见[需关注实施记录](attention-panel-validation.md)。日常迭代仍需按[验收清单](bdd-iteration-plan.md)区分配置写入、helper 通信和真实 CLI 行为。
