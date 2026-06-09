# ACP Agent Support — Plan

> 2026-06-03 · status: draft, awaiting confirmation

## 一句话

在保持 Claude Code / Codex 走当前 PTY 终端路径的前提下，给 ycode 增加第二种 agent 接入方式：**任何说 ACP（Agent Client Protocol）的 CLI 都能作为 agent 加入**，通过 stdio JSON-RPC 驱动一个独立的结构化对话面板。

---

## 假设（请用户先确认 / 修正）

以下两条假设是整份计划的支点，落地前必须达成共识：

1. **协议**：ACP = [`zed-industries/agent-client-protocol`](https://github.com/zed-industries/agent-client-protocol) —— JSON-RPC 2.0 over stdio，agent 子进程作为 server。**不是** Anthropic / OpenAI 的其他同名协议。
2. **UX**：ACP agent 不走 xterm 终端，而是一个独立的"结构化对话面板"——流式 markdown 消息、可折叠工具调用、agent thinking 状态等。**ycode 的 DNA 从"终端为先"演化为"终端 + 结构化对话双轨"**。Claude / Codex 保持终端不变。

若任一条不成立，下面方案要重新设计。

---

## 现状 vs 目标

| 维度 | 现状 | 目标 |
|---|---|---|
| Agent 类型 | 隐式：所有 `AgentLaunchProfile` 都走 PTY + xterm | 显式：`kind: "pty" \| "acp"` 二选一 |
| 新增 agent 路径 | 编辑 `~/.config/ycode/config.json`（已经是配置驱动） | 同左 + 多一条 `"kind": "acp"` |
| 渲染 | 单一 `TerminalPane`（xterm） | `TerminalPane`（PTY agent） + `AcpChatPane`（ACP agent），按 session.agent.kind 路由 |
| 历史回放 | `ycode-introspect` 扫各 agent 的 jsonl | PTY agent 沿用；ACP agent 从 ACP runtime 的 session store 取（不扫 jsonl） |
| 通知 hook | `agent_patcher` 写 Claude/Codex 各自 config 文件 | PTY agent 不变；ACP agent **不需要**——turn-complete 直接来自 ACP 事件流 |

---

## 架构

```
┌───────────────────────────────────────────────────────────────────┐
│ ycode-ipc (Service)                                               │
│   create_session(agent_id) → 查 AgentLaunchProfile.kind            │
│      ├── kind="pty"  → spawn_pty (已有)                            │
│      └── kind="acp"  → spawn_acp (新) → ycode-acp::Client          │
└───────────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                                           ▼
┌────────────────┐                       ┌───────────────────────┐
│ ycode-terminal │                       │ ycode-acp (新 crate)  │
│  PTY + xterm   │                       │  JSON-RPC over stdio  │
│  (无改动)       │                       │  AcpClient            │
└────────────────┘                       │  AcpSession           │
                                         │  事件 stream → UI bus │
                                         └───────────────────────┘
                              │
                              ▼
┌───────────────────────────────────────────────────────────────────┐
│ Frontend                                                          │
│   ChatLayout 根据 session.agent.kind 路由：                         │
│      ├── pty  → <TerminalPane .../>      (已有)                    │
│      └── acp  → <AcpChatPane  .../>      (新)                      │
└───────────────────────────────────────────────────────────────────┘
```

### 新增 crate：`crates/ycode-acp`

- **职责**：实现 ACP 客户端侧（编辑器侧）的 JSON-RPC 协议，向上提供异步事件 stream（与 `ycode-terminal` 的 `TerminalEvent` 对等）。
- **依赖**：`tokio`、`serde`、`tokio-util::codec`（line-delimited JSON）、`jsonrpsee-core` 或自写最小 JSON-RPC 帧解析。
- **核心类型**：

  ```rust
  pub struct AcpClient { /* 子进程 + stdin/stdout pipes + req id 分配 */ }

  impl AcpClient {
      pub fn spawn(spec: AcpSpawnSpec) -> Result<Arc<Self>>;
      pub async fn prompt(&self, text: String) -> Result<()>;
      pub async fn cancel(&self, turn_id: String) -> Result<()>;
      pub fn subscribe(&self) -> broadcast::Receiver<AcpEvent>;
      pub async fn kill(&self) -> Result<()>;
  }

  pub enum AcpEvent {
      TurnStarted { id: String },
      MessageDelta { turn_id: String, text: String },
      ToolCall { turn_id: String, tool: String, input: serde_json::Value },
      ToolResult { call_id: String, output: serde_json::Value },
      TurnComplete { id: String },
      Error { message: String },
  }
  ```

- **测试策略**：用一个写死的 echo-style ACP fake server（Rust binary in `tests/`）跑 end-to-end，避免依赖真实 agent CLI。

### `AgentLaunchProfile` schema 扩展

新增 `kind` 字段，默认 `"pty"` 兼容老配置：

```json
{
  "id": "my-acp-agent",
  "display_name": "My ACP Agent",
  "kind": "acp",
  "command": "my-acp-cli",
  "args": ["--acp-mode"],
  "env": { "API_KEY": "$MY_API_KEY" }
}
```

`kind="acp"` 时 `introspect` 字段忽略；`kind="pty"` 时保持现状。

### 新前端组件：`AcpChatPane`

最小可用版本（v1）的形态：

```
┌──────────────────────────────────────────────────────┐
│  ▎ User                                              │
│    把这段代码重构一下                                  │
│                                                      │
│  ▎ Agent                                             │
│    好，我先读一下文件...                               │
│    ▸ 🔧 read_file({ path: "src/foo.ts" })  [展开]     │
│    然后 src/foo.ts 里第 12 行有个问题...               │
│                                                      │
│  ▎ Agent · 思考中... [Cancel]                         │
├──────────────────────────────────────────────────────┤
│  ▎ 输入消息...                                  [↵]  │
└──────────────────────────────────────────────────────┘
```

v1 不做的：
- 富 markdown 表格 / 数学公式
- 工具结果的 diff 视图
- 多轮编辑/重发

事件接入复用现有的 `listenSessionEvents` 通道——后端把 `AcpEvent` 映射成新的 `UiEventKind::Acp*` 变体，前端的 `AcpChatPane` 订阅同一个 ID 过滤。

---

## 数据模型变更

### 后端

- `AgentLaunchProfile`：新增 `kind: AgentKind`（enum `Pty` / `Acp`，serde tag = `"kind"`），默认 `Pty`。
- `Session`（DB 表）：新增 `agent_kind` 列，建一次迁移把存量行刷成 `pty`。SQLite migration 走 `ycode-persist`。
- `UiEventKind` 新增：
  - `AcpTurnStarted { turn_id }`
  - `AcpMessageDelta { turn_id, text }`
  - `AcpToolCall { turn_id, tool, input_json }`
  - `AcpToolResult { call_id, output_json }`
  - `AcpTurnComplete { turn_id }`
  - 复用现有 `AgentTurnComplete` 触发通知（PTY 路径不动）
- `Service` 新增 IPC：
  - `acp_prompt(session_id, text)` → `Result<()>`
  - `acp_cancel(session_id, turn_id)` → `Result<()>`
  - `spawn_pty_raw` 不变；ACP session 不通过它

### 前端

- `bindings/AgentKind.ts`（ts-rs 生成）
- 新增 `lib/acp.ts`：`acpPrompt(...)`, `acpCancel(...)`
- `store.ts` 的 session 状态结构需要给 ACP session 加一个 `turns: Turn[]` 字段（结构化对话历史，前端内存态，**不持久化**——重启回 Init / 调 ACP 的 resume 重建）

---

## 分阶段实施

每阶段都是独立可合并 / 可发布的小步：

### 阶段 0：assumption 确认 + 协议 spike（0.5 天）

- 跑一遍 ACP 官方 example（zed 仓库里的 mock agent）确认协议方言
- 列一份"ycode 必须支持的 ACP method 子集"清单
- 出局后冻结这个子集，不追 ACP 上游变动

### 阶段 1：`ycode-acp` crate 骨架（1-2 天）

- spawn 子进程 + stdio pipe
- JSON-RPC 帧 codec（line-delimited 或 Content-Length）
- 单向 `prompt` 调用 + 单向 event 接收
- 在 `tests/` 写一个 mock ACP server 做端到端单测

### 阶段 2：`AgentLaunchProfile.kind` + Session 路由（半天）

- 加 `kind` 字段（默认 Pty 兼容旧配置）
- `ycode-persist` migration 加 `agent_kind`
- `Service::create_session` 按 kind 分叉

### 阶段 3：UiEvent + IPC 通道（半天）

- 加 `UiEventKind::Acp*` 变体
- 加 `acp_prompt` / `acp_cancel` 两个 IPC command
- ts-rs 重新生成 bindings

### 阶段 4：`AcpChatPane` 最小版（2-3 天）

- 消息流渲染（user / agent / tool_call / tool_result）
- 流式 markdown delta append
- 输入框 + 发送 + 取消按钮
- 接到 Sidebar 的"New Session"流程（agent picker 里 ACP agent 选中后切到 chat 而不是 terminal）

### 阶段 5：历史与生命周期（1-2 天）

- ACP session 重启策略：进程退出 → UI 显示"已结束 [重启]"，走 ACP 的 resume 接口或重新 prompt
- 已发送 turn 在 ycode 进程重启后丢失（v1 接受）；持久化留给 v2
- 通知 hook 复用 `AgentTurnComplete`，但来源改为 ACP 的 `TurnComplete` 事件，不需要 `agent_patcher`

### 阶段 6：文档 + ship（半天）

- README 补 ACP agent 配置示例
- `docs/` 加一份"如何配置自定义 ACP agent"
- bump minor 版本（建议 0.2.0，标志架构演进）

**合计估算**：6-9 个工作日，约一个 sprint。

---

## 风险与开放问题

### 风险

1. **ACP 上游不稳**：协议还在 active development，spec 可能小改。**缓解**：阶段 0 冻结子集，spec 变化按需追，不承诺一直跟最新。
2. **取消语义**：ACP 的 cancel 在不同 agent 实现里行为不一致（有的真的中断，有的只是停止 emit）。**缓解**：UI 上"取消"按钮变灰显示"已请求"，由用户判断是否还需要 kill 进程兜底。
3. **工具调用确认**：有些 ACP agent 会要求 user-approval（如运行 shell 命令）。v1 自动 approve 所有调用，v2 加交互式确认弹窗。**风险**：恶意 ACP agent 在 v1 下可以做未授权操作。**缓解**：v1 在 UI 显眼位置标"⚠ 此 agent 自动批准所有工具调用"。
4. **代码量翻倍**：UI 维护两套 pane、bindings 多一倍。**缓解**：尽量共用 sidebar / session list / theming，只让 pane 内部分叉。

### 开放问题（需要决策才能往前推）

- **Q1**：ACP session 重启时是否保留前几轮上下文？官方 `resume` 是 agent 自己持久化；如果 agent 不持久化，重启就是新对话。**建议**：v1 不做 ycode-侧上下文持久化，依赖 agent。
- **Q2**：ACP agent 也允许打开终端 tab 吗？比如调试时想看 stderr。**建议**：保留一个"显示 stderr"折叠面板。
- **Q3**：如果一个 ACP agent 想跑 shell 命令，是 ycode 代跑（更安全可控）还是 agent 自己跑？**建议**：v1 让 agent 自己跑（最快落地），v2 改成 ycode 代跑+审批。
- **Q4**：是否同时给 Claude Code / Codex 也加 ACP 模式？它们各自的 native CLI 都比 ACP 模式功能多。**建议**：不做，让它们继续走 PTY。

### Non-goals（明确不做）

- ACP server side（ycode 不会自己暴露 ACP server 给别的工具调用）
- 跨 agent 的统一"agent 框架"（这是另一个量级的项目）
- 把 Claude / Codex 也迁到 ACP（它们 PTY 模式跑得好好的，不动）
- ACP agent 的可视化工具调用 diff（v2）
- 多个 ACP agent 之间互相调用 / 协作（v3+）

---

## 落地后用户怎么用

config.json 里加一项：

```json
{
  "agents": [
    {
      "id": "claude-code",
      "kind": "pty",
      "command": "claude",
      "introspect": "claude"
    },
    {
      "id": "my-acp-bot",
      "kind": "acp",
      "command": "my-acp-cli",
      "args": ["--acp-mode"],
      "display_name": "My ACP Bot",
      "icon": "GenericAgent"
    }
  ]
}
```

新建 session 时选 "My ACP Bot" → 右栏出 `AcpChatPane` 而不是 xterm。其他一切（sidebar、project 切换、theming、font size）一致。
