# 统一会话事件模型 — 方案

> status: draft, awaiting confirmation
> 前置：[ACP Agent Support — Plan](acp-agent-support-plan.md)
> 参考来源：`deepseek-ai/deepseek-harness` 的 session 子系统（append-only 事件日志 +
> 投影函数 + persistence seam 双后端 + "model-visible ⟺ logged" 不变量）。

## 一句话

`UnifiedEvent` 已经是正确的抽象，但 ACP plan 会在它旁边建一套平行模型；建议反过来——让 ACP 轨也投影成 `UnifiedEvent`，并把 `UnifiedEvent` 持久化，这一步同时解决 ACP 轨的真相源、搜索索引（Phase B4）和 history 的重复解析三件事。

---

## 现状

### 架构：外部 jsonl 是真相源，ycode 是只读投影器

```
~/.claude/**/*.jsonl ─┐
                      ├─ scanner::scan_workspace(home, cwd)  发现 session
~/.codex/**/*.jsonl ──┘         │
                                ├─ claude.rs / codex.rs      方言解析
                                ▼
                          UnifiedEvent 流                    规范化模型
                                ▼
                    HistoryTab / SearchHit                   前端只认一种形状
```

`UnifiedEvent`（`crates/ycode-introspect/src/unified.rs`）已经覆盖 `Message` / `Thinking` / `ToolUse` / `ToolResult` / `Plan` / `Edits` / `Permission`，并有 `Unknown { raw_type }` 兜底——**不认识的事件保留原始标签而不丢弃**。这个设计是对的，和 dsh 的做法同源（dsh 用日志信封上的 `ignorable` 标记决定未知事件是跳过还是拒绝整份日志）。

### 三处"每次重算"

| 操作 | 现在怎么做 | 代价 |
|---|---|---|
| 打开 history | `load_session_history` 全量读 + 解析整个 jsonl，`max_events` 截断（codex rollout 可达 20+ MB） | 每次打开都重解析 |
| 全文搜索 | `search_sessions` 对 project 下**每个** jsonl 重扫 + 全量解析，`ev.preview()` 做 lowercase substring 匹配 | 无索引；`service.rs` 注释已计划 Phase B4 升级 FTS5 |
| 活跃 session 跟随 | `JsonlChanged` 让 HistoryTab 缓存失效并重取 | 每次写入触发一次全量重解析 |

SQLite（`ycode-persist`）目前只有 `SessionRow` / `ProjectRow` / `TodoRow` / `CheckpointRow`——**没有事件表**。

---

## 问题：ACP 轨没有 jsonl，真相源消失

ACP agent 不写 transcript 文件。plan 的方案是新增一套平行通路：

- `UiEventKind::AcpTurnStarted / AcpMessageDelta / AcpToolCall / AcpToolResult / AcpTurnComplete`
- 前端 `store.ts` 给 ACP session 加 `turns: Turn[]`，**前端内存态，不持久化**
- history："PTY agent 沿用 introspect 扫 jsonl；ACP agent 从 ACP runtime 的 session store 取（不扫 jsonl）"

这会在四个地方分叉：

| 维度 | PTY 轨 | ACP 轨 | 后果 |
|---|---|---|---|
| 渲染 | `HistoryTab` 消费 `UnifiedEvent[]` | `AcpChatPane` 消费 `Turn[]` | 两套消息/工具调用渲染器 |
| 搜索 | `search_sessions` 扫 jsonl | 无 | FTS 只覆盖一半的 session |
| 持久 | 外部文件天然持久 | 重启丢失（plan 阶段 5 已接受） | 同一个 UI 里两种记忆语义 |
| 通知 | helper binary + hook | ACP `TurnComplete` 事件 | 两条路径喂同一个 toast |

plan 自己在"风险 4：代码量翻倍——UI 维护两套 pane、bindings 多一倍"里已经预感到了这件事。分叉的根源不是 pane 长得不一样（那是合理的），而是**同一个概念"一次 agent 对话"有了两个数据模型**。

---

## 建议

### 核心：`UnifiedEvent` 升为唯一的会话内容模型

```
                     ┌─ PTY 轨：jsonl ──> claude.rs / codex.rs ─┐
真相源                │                                          │
                     └─ ACP 轨：ycode 自己生产 ────────────────┤
                                  AcpEvent → UnifiedEvent        │
                                                                 ▼
                                                    UnifiedEvent (append-only)
                                                                 │
                          ┌──────────────────┬───────────────────┼─────────────┐
                          ▼                  ▼                   ▼             ▼
                    ConversationView    search (FTS)      turn-complete    checkpoint
                    （一个渲染器）        （一套索引）        通知             触发
```

ACP 轨的关键转变：**ycode 从"只读投影器"变成自己那条轨的真相源生产者**。ACP 事件到达时映射成 `UnifiedEvent` 并 append 落盘。前端不再持有 `turns: Turn[]`，`AcpChatPane` 退化成 `<ConversationView events={UnifiedEvent[]}/>` 加一个输入框——和 `HistoryTab` 共用同一个渲染器。

直接消掉的工作量：plan 的阶段 3（新增 5 个 `Acp*` UiEvent 变体）缩成"1 个 `SessionEventAppended` 通知 + 一次增量读"；阶段 4 的消息流渲染变成复用；阶段 5 的"重启丢失"消失。

### 落盘选哪个

| 方案 | 优点 | 缺点 |
|---|---|---|
| **SQLite 事件表**（建议） | 已有 `ycode-persist`；直接支撑 Phase B4 的 FTS5；增量读不用重解析 | 需要 migration；事件表会变大，要定保留策略 |
| 自写 jsonl | 和现有 scanner 同构；外部可检查/可 grep；实现最简单 | 搜索仍要扫；要自己管文件命名和清理 |

建议 SQLite，因为它同时兑现 B4。dsh 在这里的做法是把持久化做成一个 seam，JSONL 和 SQLite 两个后端都实现它——如果 ycode 想保留"用户能直接看到 transcript 文件"这个性质，可以照这个形状留双后端，但 v1 没必要。

### `UnifiedEvent` 需要的三处调整

1. **`seq` 语义放宽。** 现在的文档注释是"jsonl 行号（0-indexed）"。ACP 轨没有行号，应改为"该 session 内单调递增序号"，PTY 轨继续用行号填充（保持现有行为，只改语义描述）。
2. **加可选 turn 边界。** ACP 协议有显式 `turn_id`；jsonl 轨没有显式回合概念。加 `turn_id: Option<String>` 而不是强制字段——PTY 轨留 `None`，ACP 轨填。UI 的回合分组对 ACP 轨可用，对 PTY 轨降级为按时间分组。
3. **`ToolUse.status` 的实时更新问题。** append-only 日志不能改已写事件，但工具状态会从 `Pending` 变成 `Ok`/`Error`。不要回写——沿用 dsh 的做法：原始事件全部保留，由**投影函数**在读取时按 call id 折叠成 UI 想要的状态。这需要给 `ToolUse` / `ToolResult` 加一个关联 id（现在只有 `tool` 名字，同一回合调用两次同名工具无法配对）。

第 3 点独立于 ACP 也值得做——现在的 `ToolUse { tool, input_json, status }` 在 PTY 轨上已经有同名工具配对不了的问题。

### 加一个格式版本号

事件一旦落盘就是历史数据。建议在事件表/文件上带一个 `format_version`。dsh 的经验：它把 `SESSION_FORMAT_VERSION` 停在 `0` 并明确声明**不做兼容承诺**（预发布阶段），只在结构性格式变化时才 bump。ycode 已发布到 0.4.4，取舍不同——但至少要能识别"这份数据是旧版本写的"，否则加字段时只能靠 serde 默认值猜。

---

## 分阶段（对齐 ACP plan 的阶段）

这个方案不是在 ACP plan 之外另开工程，而是替换它的阶段 3-5：

| 阶段 | 原 plan | 本方案 |
|---|---|---|
| 1 | `ycode-acp` crate 骨架 | 不变 |
| 2 | `AgentLaunchProfile.kind` + Session 路由 | 不变 |
| 3 | 5 个 `UiEventKind::Acp*` + 2 个 IPC | **改为**：`UnifiedEvent` 三处调整 + SQLite 事件表 migration + `AcpEvent → UnifiedEvent` 映射 |
| 4 | `AcpChatPane` 最小版（2-3 天） | **改为**：从 `HistoryTab` 抽出 `ConversationView`，`AcpChatPane` = 它 + 输入框（应显著更短） |
| 5 | 历史与生命周期（含"v1 接受重启丢失"） | **改为**：无需特殊处理，重启从事件表读回 |
| 追加 | — | `search_sessions` 切到事件表（兑现 Phase B4） |

阶段 3 的成本上升，阶段 4、5 下降，B4 顺带完成。净工作量估计接近，但少了一套需要长期维护的平行模型。

## 这个方案如何回答 plan 的开放问题

- **Q1（ACP session 重启是否保留上下文）**：plan 的建议是"v1 不做 ycode-侧持久化，依赖 agent 的 resume"。有了事件表后，**ycode 侧有完整历史**。注意区分两件事：ycode 能**显示**完整历史（本方案解决），和 agent 能**恢复**上下文（仍然取决于 agent 的 resume）。至少 UI 上不再是"重启后空白"。
- **Q2（ACP agent 要不要终端 tab 看 stderr）**：stderr 可以作为 `UnifiedEventKind::Unknown` 或新增的 `Diagnostic` 变体进同一条流，不必单开面板。
- **风险 4（代码量翻倍）**：主要缓解手段就是本方案——共用数据模型使共用渲染器成为可能。

## Non-goals

- 把 PTY 轨也改成 ycode 生产事件（jsonl 是 CLI 自己的产物，ycode 继续只读投影）
- 用事件表**替代**外部 jsonl（它是投影缓存 + ACP 轨真相源，不是 Claude/Codex transcript 的替代品）
- 持久化 hook 来的实时工具活动（和 transcript 里同一批事实重复，见 [hook 规格](agent-hook-integration-spec.md) Q2）
- 跨 agent 的统一 agent 框架（沿用 ACP plan 的 non-goal）
