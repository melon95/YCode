# Agent Hook 对接规格 — Claude Code / Codex

> status: draft, awaiting confirmation
> 参考来源：`deepseek-ai/deepseek-harness` 的 `dsh-hook-protocol` / `dsh-hooks-claude-code` / `dsh-hooks-codex`
> 三个包的实现与其 Known Limitations 清单。本文把那份跨方言规格翻译成 ycode 视角。

## 一句话

ycode 目前只把 agent hook 当作**单向完成通知信号**用了两个点；两家协议实际提供的是**带结构化 payload 的生命周期事件流**，其中 `SessionStart` 和 `PreToolUse`/`PostToolUse` 能直接消掉 ycode 现在靠扫目录和等落盘做的两处猜测。

---

## 现状

### 已实现的链路

```
agent CLI ──hook──> ycode-notify (一次性 helper)
                      │ UDS 单行 JSON, 200ms 超时, 恒 exit 0
                      ▼
                 NotifyListener (ycode-ipc)
                      ▼
      UiEventKind::AgentTurnComplete { source, event_kind, body_preview }
                      ▼
              Tauri shell → 系统通知（窗口失焦时）
```

`agent_patcher`（`crates/ycode-config/src/agent_patcher.rs`，1556 行）负责写用户的配置文件：

| Agent | 文件 | 写法 | 冲突处理 |
|---|---|---|---|
| Claude Code | `~/.claude/settings.json` | hook 是**每事件一个列表**，可加自己的条目，用 `"_ycode_managed": true` 标记 | 无冲突分支——要么标记条目在、要么不在 |
| Codex | `~/.codex/config.toml` | `notify = [...]` **单命令字段** | 用户已设置则拒绝覆盖，UI 显示 "managed by you"；`ycode-notify --next` chain mode 可前置 |

首次改动写一次性备份 `<file>.ycode.bak`；卸载靠标记识别而非还原备份。

### 目前用到的 hook 点

| Agent | 点 | 用途 |
|---|---|---|
| Claude Code | `Stop` | 回合完成 |
| Claude Code | `Notification`（matcher 限定 `permission_prompt`） | 等待授权 |
| Codex | `notify` | 回合完成 |

`CLAUDE_NOTIFICATION_MATCHER` 刻意只保留 `permission_prompt`，排除 `idle_prompt`（回合结束后约 60s 才触发，会和已发出的"已完成"提示自相矛盾）、`auth_success`、`elicitation_*`。这个取舍是对的，本文不建议改动。

### 现状的两处猜测

1. **terminal ↔ transcript 关联靠 cwd 扫目录。** `scanner::scan_workspace(home, cwd)` 分别扫 Claude 和 Codex 的目录，按 `jsonl_path` 去重。哪个 jsonl 对应哪个正在跑的 PTY，没有权威绑定——同一个 project 开两个 Claude session 时只能靠时间和内容推断。
2. **工具活动要等落盘。** 实时信息只有 `PtyOutput`（原始字节）和 `JsonlChanged`（文件被写了，去重取）。"agent 现在在跑什么工具"必须等 CLI 把行写进 jsonl，再由 HistoryTab 重新全量解析。

---

## 两家协议的完整语义

以下是 ycode 目前**没用上**但协议提供的部分。

### 输出契约（两家共享）

hook 是一个子进程，ycode 关心的是它的退出码和 stdout：

| 退出码 | 语义 |
|---|---|
| `0` | 通过。stdout 可以是结构化 JSON（携带决策/上下文），也可以是纯文本 |
| `2` | **阻塞**。stderr 作为阻塞原因返回给 agent |
| 其他非零 | 非阻塞错误。记录并继续 |

stdout 的 JSON 可携带 `additionalContext`（注入模型上下文）、`systemMessage`、`continue: false`、以及点位专属的 `permissionDecision`。

**一个点上有多个 hook 命中时的合并规则**：权限决策 `deny > ask > allow`；`continue: false` 一旦出现即粘性；阻塞原因用 `\n\n` 连接；`additionalContext` 按顺序累积。

### matcher 语义 —— 两家不同，容易踩

| Agent | 规则 |
|---|---|
| Claude Code | 纯 `[A-Za-z0-9_|]+` 的模式视为**字面量**（`|` 是精确匹配的 alternation）；含其他字符则视为**正则** |
| Codex | **总是**非锚定正则，没有字面量快路径 |

空 / 缺失 / `*` 在两家都是 match-all。matcher 的匹配对象取决于点位：`PreToolUse`/`PostToolUse` 匹配工具名，`SessionStart` 匹配 session 来源，`UserPromptSubmit`/`Stop` 忽略 matcher。

### 可用点位

dsh 映射了 Claude Code 30 个点里的 7 个、Codex 10 个里的 5 个。这 7 / 5 个是语义清晰、payload 稳定、值得对接的子集：

| 点位 | Claude Code | Codex | payload 关键字段 |
|---|---|---|---|
| `SessionStart` | ✅ | ✅ | `session_id`、`transcript_path`、`source` |
| `UserPromptSubmit` | ✅ | ✅ | `session_id`、`transcript_path`、prompt 文本 |
| `PreToolUse` | ✅ | ✅ | `tool_name`、`tool_input`、`session_id` |
| `PostToolUse` | ✅ | ✅ | `tool_name`、`tool_response`、`session_id` |
| `Stop` | ✅ | ✅ | `session_id`、`stop_hook_active` |
| `SubagentStart` / `SubagentStop` | ✅ | ❌ | `agent_type`、子 session id |

Codex 侧一个重要缺陷：它把所有工具的参数压成 `tool_input: { command }`，非 shell 工具的参数不忠实暴露。做 UI 展示时不能假设 Codex 的 `tool_input` 完整。

---

## 对 ycode 的三个机会

### A. `SessionStart` 精确绑定 terminal ↔ transcript（建议优先做）

`SessionStart` 的 payload 自带 `session_id` 和 `transcript_path`。ycode 在 spawn PTY 时已经注入了 `YCODE_TERMINAL_ID`，hook 进程继承它。所以一个 `SessionStart` hook 一次性给出三元组：

```json
{ "terminal_id": "<YCODE_TERMINAL_ID>", "agent_session_id": "...", "transcript_path": "/abs/path.jsonl" }
```

这把现在的"扫 cwd 目录 + 按 jsonl_path 去重 + 推断"换成权威绑定。直接受益：

- 同 project 多 session 时 HistoryTab 不再可能挂错文件
- `JsonlChanged` 可以精确路由到某个 session，而不是让所有监听者失效重取
- 一个正在跑的 PTY session 可以立刻显示它自己的结构化历史，不必等用户去 History 里找

代价：`agent_patcher` 需要多写一个 hook 条目（Claude 侧无冲突，additive）。

注意 dsh 记录的两个限制：`SessionStart` 在它那边是**分离执行**（没有点位等待它），所以到达有延迟；且 Claude 的 `transcript_path` 在第一个回合落盘前可能还不存在。ycode 这里要把它当作"迟到但权威"的绑定信息，不能当作 session 就绪的信号。

### B. `PreToolUse` / `PostToolUse` 实时工具活动流

这两个点在工具执行**前后**同步触发，比 jsonl 落盘早。可以驱动：

- session 徽章从"运行中"细化到"正在跑 Bash / 正在编辑 src/foo.ts"
- Changes 面板在 `PostToolUse` 命中写类工具时主动刷新，不靠轮询 `git status`
- checkpoint 触发点从"回合完成"细化到"首次写文件之前"

matcher 让 ycode 只订阅关心的工具（`Edit|Write|Bash`），避免每次 `Read` 都过一趟 UDS。注意上面的 matcher 语义差异：这个模式在 Claude 侧是字面量 alternation，在 Codex 侧是正则——恰好两种解释结果相同，但换成 `Edit.*` 就会分叉。

### C. 明确不用阻塞能力（non-goal）

协议允许 hook 用 exit 2 阻塞 agent、用 `additionalContext` 注入上下文、用 `permissionDecision` 代替用户批准。**ycode 不应该用这些。** 理由：ycode 是 agent 的宿主，不是 agent 的策略层；用户的 Claude 被 ycode 悄悄阻塞或注入上下文，是违反预期的行为，且会和用户自己的 hook 冲突。

`ycode-notify` "恒 exit 0" 的现有约定正是这条边界的实现。**新增任何 hook 点时这条不能松**：helper 在任何失败路径（socket 不存在、超时、ycode 没在跑）都必须 exit 0，否则用户的 agent 会因为 ycode 不在运行而被阻塞。

---

## 落地约束

1. **恒 exit 0 是硬约束**，见上。200ms 超时同理——hook 是同步阻塞 agent 的，慢 hook 等于慢 agent。
2. **新增点位放大 patcher 的冲突面。** Claude 侧 additive 无冲突。Codex 侧要区分两套机制：`config.toml` 的 `notify` 是单命令字段（已有 chain mode 处理），而 Codex 的 hook 走独立的 `hooks.json`——加 hook 点不必碰 `notify`，冲突风险更低。
3. **payload 要按方言解析，不要假设同构。** 两家字段名和嵌套不同（Codex 是 snake_case 且 stdin 不带尾换行），值得像 dsh 那样把"方言中立的编解码"和"每家的 payload 映射"分开：`ycode-notify` 侧保持哑管道，方言解析放在 `NotifyListener` 或一个新的 `ycode-hook` 模块里。
4. **`Unknown` 兜底。** 新点位的 `event_kind` 应该沿用 `UnifiedEventKind::Unknown { raw_type }` 的思路——不认识的子类型记录原始标签而不是丢弃，这样上游加字段不会让老版本 ycode 静默丢数据。

---

## 风险与开放问题

### 风险

1. **上游 hook 协议演进。** dsh 的 README 逐条记录了它实现的子集和它**没有**实现的部分，这份清单会随上游变旧。建议 ycode 同样在代码注释里冻结"我们对接的点位子集 + 依据的上游文档版本"，不追最新。
2. **用户已有 hook 冲突。** Claude 侧 additive 所以安全；但如果用户自己在 `PreToolUse` 上装了阻塞 hook，ycode 的条目和它的执行顺序（dsh 是串行、按配置顺序、most-restrictive 合并；Claude 本体是并行 + 去重）会影响观测到的时序。ycode 只观测不决策，所以影响有限，但 UI 上不能把"我看到了 PreToolUse"等同于"这个工具一定会执行"。
3. **hook 数量 × 工具调用频率 = UDS 流量。** 每次工具调用一到两次 socket 连接。matcher 收窄是主要缓解手段；必要时 helper 侧做批量合并。

### 开放问题

- **Q1**：`SessionStart` 绑定信息迟到时，UI 怎么表现？建议：session 先以 PTY-only 状态可用，绑定到达后再点亮"结构化历史"入口。
- **Q2**：`PreToolUse` 活动流要不要持久化？建议：不要单独持久化——它和 jsonl 里的同一批事实重复。当作实时 UI 提示，落盘仍以 transcript 为准。这与 [统一会话事件模型](unified-session-event-model.md) 的"一个事实一个来源"一致。
- **Q3**：Gemini CLI / Cursor 有没有等价 hook？未确认。方言中立编解码 + 每家 payload 映射的切法就是为了让第三家便宜接入。

## Non-goals

- 用 hook 阻塞、批准或改写用户 agent 的行为（见机会 C）
- 实现两家 hook 协议的完整点位集（Claude 30 个 / Codex 10 个）
- 把 hook 当作 ACP 轨的替代——ACP agent 的回合完成直接来自协议事件流，不需要 hook
