# ycode → pi 实现方案

> 2026-09-11 · status: draft（经一轮逐条核验修订）
> 配套 [`ycode-feature-spec.md`](ycode-feature-spec.md)（做什么，171 项验收基准）；本文回答**怎么做**
> 排期见 [`bdd-iteration-plan.md`](bdd-iteration-plan.md)（**按什么顺序做**）—— §7 的阶段划分已被它重排，本文的阶段仅作技术内容索引
> 核验依据：`@earendil-works/pi-coding-agent@0.85.1` 完整包 + ycode 实际代码。每条 pi 断言都注明出处文件与行号
>
> **早先存在一份 `pi-migration-plan.md`，从未进入版本库，不要再引用它。** 它的 §0.5 清单已被本文与 spec 取代；spec 里形如 `(A5)` `(H10)` 的来源编号是那份文档的遗留标注，保留仅为对照，已无可达出处

---

## 0. 一句话

ycode 放弃「把任意 CLI agent 塞进 PTY」的容器定位，改为只对接 pi 一个 runtime（`pi --mode rpc`，JSONL over stdio），中间栏从 xterm 换成 ycode 自己渲染的对话面板。

**角色反转是最大代价**：过去权限弹窗、模型选择、工具调用展示都是 Claude Code 自己在 PTY 里画的，ycode 只转发字节。改成 RPC 后这些全归 ycode，而 pi 刻意不做权限、不做 MCP、不做 sub-agents、不做内置 todo。

---

## 1. 前提修正（相对早先方案）

一次外部评审 + 逐条核包 + 一次实测，推翻了早先方案的五处判断。**这些是本文的出发点，不是可选项。**

### 1.1 选 pi 的三条理由（修订：订阅那条此前被读窄了）

早先版本写「订阅接入这条动机不成立」，依据是 `docs/providers.md:35` 关于 Claude Pro/Max 的那句：

> Anthropic subscription auth is active for Claude Pro/Max accounts. Third-party harness usage draws from extra usage and is billed per token, not against Claude plan limits.

**那条结论只对 Anthropic 一家成立，当成「订阅整体没用」是过度概括。** `docs/providers.md:17-25` 列的订阅登录有六个入口：

| 订阅 | 状态 |
|---|---|
| ChatGPT Plus/Pro (Codex) | OpenAI 官方背书（`providers.md:31` 链 Codex for OSS） |
| Claude Pro/Max | 按 token 计费，不吃 plan 额度 ← 唯一的例外 |
| GitHub Copilot | 可用 |
| xAI (Grok/X) | `/login xai` → Use a subscription |
| OpenRouter | OAuth 铸 API key，走 OpenRouter credits |
| Radius | 可用 |

**因此选 pi 的理由是三条**：

1. **订阅可用** —— 但**各家性质不同，Claude 那条有合规风险，见 §1.1b**。OpenAI Codex 是官方背书的；Copilot / xAI / OpenRouter 是正常第三方接入；Claude 走的是 Claude Code 的客户端身份
2. **开源可改** —— 需要的东西没有就自己加。§12 的四块（权限 / MCP / sub-agent / todo）全部建立在这条上
3. **协议级会话控制** —— steering、模型热切换、按需压缩、树形分叉。Claude Code 的 `-p --output-format stream-json` 给不了

另有两个顺手解决的缺陷，但**都能不换 runtime 就修**，不单独作为理由：`tool_execution_*` 带 `toolCallId`；`get_entries(since)` 增量读。


### 1.1b ⚠️ Claude 订阅怎么实现的 —— 必须知情

这条单独拉出来，因为它影响 ycode 要不要把「用 Claude 订阅」作为卖点。

**核验方式**：读 `pi-ai` 的实际实现，不是读文档。

`dist/auth/oauth/anthropic.js`：

```js
const decode = (s) => atob(s);
const CLIENT_ID = decode("OWQxYzI1MGEtZTYxYi00NGQ5LTg4ZWQtNTk0NGQxOTYyZjVl");
//              → 9d1c250a-e61b-44d9-88ed-5944d1962f5e
const AUTHORIZE_URL = "https://claude.ai/oauth/authorize";
const SCOPES = "... user:inference user:sessions:claude_code ...";
```

`dist/api/anthropic-messages.js`：

```js
if (isOAuthToken) features.push("claude-code-20250219", "oauth-2025-04-20");

// For OAuth tokens, we MUST include Claude Code identity
if (isOAuthToken) {
  params.system = [{ type: "text",
    text: "You are Claude Code, Anthropic's official CLI for Claude." }];
}

const normalizeToolName = isOAuthToken ? toClaudeCodeName : (n) => n;
// 把 read/bash/edit 改写成 Read/Bash/Edit 等 Claude Code 的规范工具名
```

**也就是说，pi 用 Claude 订阅时做了四件事**：

| 手法 | 证据 |
|---|---|
| 用一个 base64 混淆的 `client_id` | `anthropic.js:13`，解码即得 UUID |
| 申请 `user:sessions:claude_code` scope | `anthropic.js:20` |
| 带 `claude-code-20250219` beta header | `anthropic-messages.js:760` |
| **强制注入** "You are Claude Code, Anthropic's official CLI" 系统提示 | `anthropic-messages.js:806`，注释原文 "we MUST include Claude Code identity" |
| 把工具名改写成 Claude Code 的规范名 | `anthropic-messages.js:780` + `ccToolLookup` |

**这不是「Anthropic 开放了订阅给第三方」，是 pi 让请求看起来像是 Claude Code 发的。** `client_id` 被 base64 混淆这件事本身就说明作者知道它不该被轻易发现。

#### 对 ycode 的三条结论

1. **不能把「用你的 Claude 订阅」写进 ycode 的对外宣传。** 这等于 ycode 主动推荐用户以可能违反 Anthropic 消费者条款的方式使用账号。风险从「用户自己装了个 CLI」转移到 ycode 身上
2. **不做原生 Claude OAuth UI**（原决策 5 悬置，现**明确不做**）。ycode 自己实现这套伪装，性质比「转发用户已有的 pi 配置」严重得多
3. **但不必阻止用户自己用。** 用户在终端里跑过 `pi` 的 `/login`，凭证在 `~/.pi/agent/auth.json`，ycode 起的 pi 子进程自然会用到它。ycode 对此**不感知、不引导、不宣传**，也不特意屏蔽 —— 那是用户和 Anthropic 之间的事

#### 对外表述

ycode 的登录页只呈现两类：

- **API key**（Anthropic / OpenAI / 其他）—— 明确推荐
- **其他 provider 的订阅登录** —— 引导到终端跑 `pi`，由 pi 负责，ycode 不代理

Claude 订阅**不出现在 ycode 的登录选项里**。用户已经配好的话它照常工作，仅此而已。

> 这条会损失一部分「省钱」卖点。但 ycode 是开源桌面应用，不是匿名 CLI —— 它有可被追溯的发布主体，风险承担方式不一样。

### 1.2 权限超时的机制读反了 — 早先设计的地基是错的

`docs/rpc.md:1193`：

> If a dialog method includes a `timeout` field, the agent-side will auto-resolve with a default value when the timeout expires. **The client does not need to track timeouts.**

三层后果：

| 早先方案以为 | 实际 |
|---|---|
| ycode 负责倒计时 | pi 侧兜底，客户端不参与 |
| 超时能带出 `reason` + `terminate` | auto-resolve 的默认值是 `confirm → false`、`select → undefined`（`docs/rpc.md:1213`），**两个都带不出来** |
| `timeout` 是协议自带的语义 | 它是**扩展作者调用时传的参数**，不传就无限等待。没有默认值 |

正确做法见 §4。

### 1.3 项目信任整条链路缺失 — 用户会真实撞上

`docs/security.md:29`、`docs/settings.md:16`、`docs/usage.md:126` 三处同文：

> Non-interactive modes (`-p`, `--mode json`, and **`--mode rpc`**) do not show a trust prompt. Without an applicable saved trust decision, `defaultProjectTrust: "ask"` and `"never"` **ignore such resources**.

ycode 跑的正是 `--mode rpc`。**默认配置下会静默忽略**项目里的 `.pi/settings.json`、`.pi/extensions/`、`.pi/skills/`、project packages。用户体验是「我在项目里配的东西 agent 就是不认」，且无任何提示。见 §5。

### 1.4 官方扩展现成，权限的工期归因错了

`examples/extensions/` 里有四份直接相关的实现：

| 文件 | 行数 | 作用 |
|---|---|---|
| `permission-gate.ts` | 34 | `tool_call` 拦截 + `ctx.ui.select` 确认 |
| `protected-paths.ts` | 30 | 路径保护，返回 `{block, reason}` |
| `project-trust.ts` | 64 | `project_trust` 事件的完整用法 |
| `timed-confirm.ts` | 70 | 三种超时写法，其中 `/timed-signal` 是 §4.2 要用的那一种 |
| `sandbox/` | — | 隔离方案 |

**pi 侧的管道近乎免费**（核心逻辑十来行）。早先给「权限系统」排 3–4 天是把成本记错了地方：真正的成本全在 **ycode 侧的产品设计** —— 规则存储、记住选择的粒度、撤销界面、路由到侧栏。

### 1.5 N 个 pi 进程的内存 — 已实测，比估计更糟

早先列为「阶段 0 的唯一 go/no-go gate」。2026-09-11 在 macOS 上实测，`pi 0.85.1` + Node 24.15：起四个并发 `pi --mode rpc`，各发一条 `get_state`，**不载入任何会话内容、不装扩展**。

| 进程 | RSS |
|---|---|
| 1 | 134 MB |
| 2 | 135 MB |
| 3 | 135 MB |
| 4 | 140 MB |
| **合计** | **544 MB** |

这是**空载地板价**。装上 `ycode-bridge.ts`、载入真实会话历史、跑起工具调用之后只会更高。

三层后果：

1. **「四会话并排」在用户敲第一个字之前就要吃掉半个 G。** 而多会话并排是 §2 决策 1 之后仅剩的核心卖点（见 §8 风险 1）
2. **一会话一进程的架构要重新论证。** 可选项：进程池 + 会话复用（pi 协议是否支持一个进程多会话需核实）、后台会话降级为「休眠不保活」、或接受上限（比如同时最多 3 个活进程，其余按 LRU 回收）
3. **`keepPty` 的新语义（spec 2.11）不再只是命名问题。** 「关闭面板后进程是否继续跑」现在直接等价于「每个后台会话常驻 135 MB」

> **这条不再是待办，是前提。** 阶段 0.3 从「实测」改为「定架构」：在写 `crates/ycode-pi` 之前，先决定进程生命周期策略，否则阶段 3 的会话路由要返工。

---

## 2. 决策记录（12 条，全部生效）

| # | 议题 | 决定 |
|---|---|---|
| 1 | Runtime | 只对接 pi；删 Claude Code / Codex 的 PTY 轨；右栏 `$SHELL` 保留 |
| 2 | 项目管理 | 保留轻量项目分组；删项目总览页与 per-project 设置 |
| 3 | 会话心智 | 会话式，不引入「任务」实体 |
| 4 | 老 Claude/Codex 数据 | **归它们自己的 CLI 管**。ycode 无入口、不碰文件、parser 删 |
| 5 | 登录 | 原生 OAuth UI **不做**（§1.1b，非悬置）；v1 只做 API key + 终端降级路径。Claude 订阅不出现在登录选项里 |
| 6 | 权限请求 | **内联在输入区**、数字键选择（像 Claude Code），不是模态框 |
| 7 | 全文搜索 | FTS5 降到 **v1.1** |
| 8 | pi 分发 | 检测 + 引导安装，不打进 bundle |
| 9 | 扩展生态 | v1 只做只读列表 |
| 10 | 顶栏 | 不显示项目 tab；不显示执行位置 chip |
| 11 | 注意力管理 | 取消收件箱，统一在左栏（过滤条 + 行内说明 + 按紧急度排序） |
| 12 | 编辑器 | **降级为只读预览** —— 文件树 + 语法高亮保留，删编辑能力与整个 LSP |

---

## 3. 架构

### 3.0 一次使用的完整路径

架构图按功能分层容易漏掉真正决定体验的东西 —— **接缝**。下面按用户实际走过的路径组织，每一步标出它和别处的耦合。标「接缝」的地方做砸了，单个功能仍然能通过验收，但整体用起来是散的。

```
┌──────────────────────────────────────────────────────────────────────────┐
│ ① 起一件事                                                               │
├──────────────────────────────────────────────────────────────────────────┤
│   Cmd-N → 选模型 / 权限模式 / 要不要 worktree → 描述任务                 │
│                                                                          │
│   接缝：这里选的权限模式，决定了 ③ 会不会打断你                          │
│         这里选的 worktree，决定了 ④ 敢不敢让它直接改                     │
└──────────────────────────────────────────────────────────────────────────┘
                                 │  输入框还在，可以继续打字
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ② 它在干活，你在看                                                       │
├──────────────────────────────────────────────────────────────────────────┤
│   流式文字 · 思考块 · 工具调用（折叠）· 内联 diff                        │
│                                                                          │
│   接缝：长输出要虚拟化，否则一次 read 5000 行就卡死                      │
│         滚动要能停住，否则你想读的那段一直被冲走                         │
│         想插话就直接打字 → steering，不用等它停                          │
└──────────────────────────────────────────────────────────────────────────┘
                                 │  撞到需要许可的操作
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ③ 它要动手，先问你                                                       │
├──────────────────────────────────────────────────────────────────────────┤
│   内联在输入区，不是弹窗 —— 弹窗会抢走另一个会话的焦点                   │
│   看到的是「在 src/ 里搜 foo」，不是「rg -n foo src/」                   │
│   要改文件时，直接看到 diff，就在问句下面                                │
│                                                                          │
│   1 允许    2 本会话不再问    3 拒绝并说明     Esc 拒绝并停下            │
│   一开始打字，焦点自动回输入框 —— 拒绝理由有地方写                       │
│                                                                          │
│   接缝：这里的 diff 和 ⑤ 的变更面板必须是同一套渲染                      │
│         不然同一个改动在两个地方长得不一样                               │
│   接缝：会话在后台时，这个请求必须在左栏冒出来                           │
│         否则它就在那儿静静挂着，你以为它在干活                           │
└──────────────────────────────────────────────────────────────────────────┘
                                 │  你批准了
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ④ 它改了代码                                                             │
├──────────────────────────────────────────────────────────────────────────┤
│   改动前自动打 checkpoint —— 由 tool_call 触发，比 hook 准               │
│   worktree 开着的话，改动落在分支上，主仓没动                            │
│                                                                          │
│   接缝：回滚代码但不告诉它，下一轮它必然基于旧假设乱来                   │
│         所以回滚要往会话里注入一条「代码已回滚」                         │
└──────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ⑤ 你审，然后决定要不要                                                   │
├──────────────────────────────────────────────────────────────────────────┤
│   右栏变更面板 · 并排 diff · 逐 hunk 应用 / 丢弃                         │
│   不满意 → 回滚到任一 checkpoint                                         │
│   满意 → stage / commit，worktree 的话再 merge                           │
│                                                                          │
│   接缝：从 ② 的某个工具调用，要能跳到这里对应的改动                      │
│         这条链路断了，「它改了什么」就得自己找                           │
└──────────────────────────────────────────────────────────────────────────┘
                                 │
                                 ▼
┌──────────────────────────────────────────────────────────────────────────┐
│ ⑥ 同时你还有另外三件事在跑                                               │
├──────────────────────────────────────────────────────────────────────────┤
│   并排布局 · 左栏按紧急度排序 · 谁在等你一眼看出                         │
│                                                                          │
│   接缝：③ 的请求、失败、跑完，都要汇到左栏                               │
│   接缝：四个会话 = 四个 pi 进程 = 544 MB（实测）                         │
│         这个数字如果不解决，⑥ 就是空头支票                               │
└──────────────────────────────────────────────────────────────────────────┘
```

**七条接缝，是这次重构的实际难点**，也是验收时最该盯的地方：

| # | 接缝 | 做砸的后果 |
|---|---|---|
| 1 | ①的权限模式 → ③是否打断 | 模式形同虚设，用户不知道自己选了什么 |
| 2 | ②长输出虚拟化 | 一次 read 5000 行卡死，整个会话废掉 |
| 3 | ③的 diff 与⑤同一套渲染 | 同一改动两个地方不一样，用户不信任任何一个 |
| 4 | ③后台请求 → 左栏 | 会话静静挂着，用户以为在干活 |
| 5 | ④回滚 → 注入会话 | agent 基于旧假设继续，越跑越错 |
| 6 | ②工具调用 → ⑤对应改动 | 「它改了什么」要自己找 |
| 7 | ⑥四进程 544 MB | 多会话并排是空头支票 |

单个功能的完成度不构成产品，这七条连起来才是。

### 3.0b 数据流

```
┌──────────────────────────────────────────────────────────────┐
│ ycode-ipc (Service)                                          │
│   create_session()  → spawn pi --mode rpc                    │
│   spawn_pty_raw()   → 右栏 $SHELL（不变）                     │
└──────────────────────────────────────────────────────────────┘
        │                                    │
        ▼                                    ▼
┌──────────────────────┐        ┌──────────────────────────┐
│ crates/ycode-pi (新) │        │ ycode-terminal（保留）    │
│  子进程 + JSONL stdio│        │  PTY，仅右栏 $SHELL       │
│  PiClient/PiSession  │        └──────────────────────────┘
│  事件 → UnifiedEvent │
└──────────────────────┘
        │  ▲
        │  │ extension_ui_request / _response
        │  │
        │  └── ~/.pi/agent/extensions/ycode-bridge.ts
        │         on("tool_call")     → 权限（§12.1 语义化预解析）
        │         on("project_trust") → 信任
        │         registerTool()      → todo + MCP 桥（§12.2）
        ▼
  UnifiedEvent (append-only, SQLite)
        │
   ┌────┼──────────┬──────────┬─────────┐
   ▼    ▼          ▼          ▼         ▼
对话面板  搜索    通知    checkpoint   usage
```

### 3.1 为什么扩展必须装在全局目录

`examples/extensions/project-trust.ts` 的注释写明安装位置是 `~/.pi/agent/extensions/` 或 `pi -e`。原因在 `docs/security.md`：项目未被信任时**项目级扩展根本不加载**，而 `project_trust` 事件只有 user/global 扩展与 CLI `-e` 扩展能参与。

> **硬约束**：ycode 的桥接扩展必须写到 `~/.pi/agent/extensions/`，或每次启动用 `-e` 传。不能放项目里。

### 3.2 JSONL 分帧

`docs/rpc.md:28-37`：只按 `\n` 切；容忍并剥掉尾部 `\r`；**不能用会在 `U+2028`/`U+2029` 处切分的通用行读取器**（点名 Node 的 `readline`）；流结束时 flush 残余缓冲。

Rust 侧 `tokio_util::codec::LinesCodec` 只按 `\n`，**符合要求**（早先方案标的「必须确认」可结案）。仍需在 `tests/` 里锁一条 `U+2028` 用例。

---

## 4. 权限机制（重做）

### 4.1 协议事实

```ts
// examples/extensions/permission-gate.ts — 核心就这么多
pi.on("tool_call", async (event, ctx) => {
  if (event.toolName !== "bash") return undefined;
  const choice = await ctx.ui.select(`⚠️ ${event.input.command}\n\nAllow?`, ["Yes","No"]);
  if (choice !== "Yes") return { block: true, reason: "Blocked by user" };
  return undefined;
});
```

- 返回 `{ block, reason?, terminate? }`；`reason` 作为工具结果回给 LLM
- `terminate` — `docs/extensions.md:793`：**只有当该批次全部 finalized 结果都是 terminating 时**，agent 才提前停
- `event.input` 可原地修改且影响真实执行，不会重新做 schema 校验
- RPC 下 `ctx.hasUI` 仍为 `true`，`ctx.mode === "rpc"`（`docs/rpc.md:1195+`）

### 4.2 超时：ycode 自己计时，用 `AbortSignal` 而不是 `Promise.race`

```
ycode-bridge.ts 的 tool_call handler
  ├─ 不给 ctx.ui.select 传 timeout        ← 否则 pi 会用带不出 reason 的默认值兜底
  ├─ 传 opts.signal，自己的计时器到点 controller.abort()
  └─ abort 后 select 返回 undefined → 自己构造 { block: true, reason: "用户未响应", terminate: <见下> }
```

**不要用 `Promise.race`。** `dist/modes/rpc/rpc-mode.js:44-78` 的 `createDialogPromise` 对三条退出路径都挂了同一个 `cleanup()`，它会把这次请求从 `pendingExtensionRequests` 表里摘掉：

| 退出路径 | 是否 cleanup |
|---|---|
| 用户正常响应 | ✅ |
| `opts.timeout` 到点 | ✅（但默认值带不出 reason，所以不用它） |
| `opts.signal` abort | ✅ |
| 外部 `Promise.race` 先赢 | ❌ **请求永久留在表里** |

`Promise.race` 赢了之后，输的那一支还挂着。用户事后真点了按钮，响应会落到一个已经没人等的 resolve 上，而表项直到进程退出都不释放。`signal` 既满足「不传 timeout」的核心诉求，又走完整清理。官方 `examples/extensions/timed-confirm.ts` 的 `/timed-signal` 命令就是这个写法。

```ts
const controller = new AbortController();
const t = setTimeout(() => controller.abort(), timeoutMs);
const choice = await ctx.ui.select(title, options, { signal: controller.signal });
clearTimeout(t);
if (controller.signal.aborted) return { block: true, reason: "用户未响应" };
```

`terminate` 的取值**不能按单个调用决定**。`docs/extensions.md:780-790`：并行工具是顺序预检、并发执行。要让 agent 真停，得整批都终止。所以扩展要维护「本批次未决调用计数」，只有在**最后一个未决调用也超时**时才把整批标 terminate。

> 这条如果做不干净，退而求其次：超时只 `block` 不 `terminate`，agent 会继续但每个工具都被拒，最终自己停下。较吵但正确。**v1 建议先用这个保守解法。**

### 4.3 超时默认值：不是 18 秒

早先原型写的 18 秒是错的默认：

- 人不在 → 太短，离开工位倒杯水回来会话就停了
- 人在但要读 diff → 也太短，而「批准前看 diff」正是 v1 的差异化锚点

**v1 默认不超时。** 超时做成可选项，按分钟计，或只在窗口不在前台时启用。这是**唯一一个会主动终止用户工作的自动行为**，默认值必须保守。

### 4.4 「拒绝并说明理由」要有地方输入

早先原型在 `s.pending` 时把整个输入区替换成了确认卡，于是选项「拒绝，并告诉 pi 该怎么做」**没有地方打字**。

这是内联形态的中心难题：保留输入框 → 数字键 1/2/3 与打字冲突；删掉输入框 → 拒不出理由。

**解法**（跟 Claude Code 一致）：焦点默认在选项列表，数字键直选；**一旦开始打字就自动把焦点移回输入框**并取消数字键绑定。选项 3 选中后展开输入行。

### 4.5 九种 `extension_ui_request`，不止 select

`dist/modes/rpc/rpc-types.d.ts` 是一个判别联合：

| 需要响应 | `select` · `confirm` · `input` · `editor`（无 timeout） |
|---|---|
| **不需要响应** | `notify` · `setStatus` · `setWidget` · `setTitle` · `set_editor_text` |

后 5 种 ycode **必须至少静默消费**，否则装了任何第三方扩展就会对着不需要响应的请求傻等。`notify` 建议接进 toast，`setStatus` 接进会话状态条。

---

## 5. 项目信任（新增，早先方案零覆盖）

### 5.1 事件

```ts
// examples/extensions/project-trust.ts
pi.on("project_trust", async (event, ctx): Promise<ProjectTrustEventResult> => {
  // event.cwd
  // 返回 { trusted: "yes" | "no" | "undecided", remember?: boolean }
  // 第一个返回 yes/no 的 handler 获胜，并抑制内置提示
});
```

### 5.2 ycode 的处理

在 `ycode-bridge.ts` 里接管，弹 ycode 自己的信任提示：

```
首次在某项目建会话 →  project_trust 触发
   → ycode 弹：「这个项目里有 .pi 配置和 2 个扩展。要加载吗？」
      · 信任并记住   → { trusted:"yes", remember:true }  写入 trust.json
      · 只信任本次   → { trusted:"yes" }
      · 不信任       → { trusted:"no" }
```

设置页「权限与信任」里要能查看和撤销 `~/.pi/agent/trust.json` 里已保存的决定（按目录记，最近的父目录生效）。

### 5.3 不要默认 `--approve`

`--approve`/`-a` 能一把跳过，但那等于替用户把所有项目标为可信。**这是安全决策，必须由用户显式做。**

---

## 6. 事件表：这是第三次

migration 实况：

| 版本 | 动作 |
|---|---|
| `0001_init.sql:25` | `CREATE TABLE events` |
| `0003_terminal_first.sql:36` | **`DROP TABLE events`** — 理由「xterm.js 的 scrollback 就是 transcript」 |
| `0004` | 建 `session_transcript_chunks` |
| `0006` | 又删掉 |

**这次凭什么不一样**：前两次删除的理由都是「PTY 已经有 transcript 了，事件表是重复存储」。改成 RPC 之后**没有 PTY scrollback 了** —— ycode 自己成为对话内容的唯一真相源，事件表从「重复」变成「必需」。

这段历史必须写进 migration 的注释，否则第四个人还会删它。

---

## 7. 分阶段

> ⚠️ **本节的顺序已被 [`bdd-iteration-plan.md`](bdd-iteration-plan.md) 取代。** 按模块切会把接缝切在阶段边界上（§3.0 的七条），BDD 计划改为按用户路径切。本节保留作**技术内容索引** —— 每个阶段写的东西仍然准确，只是被打散重排进八个迭代，映射见 BDD 计划 §5。

工期按单人估。**括号里是现实系数** —— 早先方案的 16–21 天没有算调试、产品设计反复、从 0.5.0 到 1.0 的回归。

### 阶段 0 · 结论落定与正交先修（3 天）

不写迁移代码，先把与 pi 无关、早该做的事清掉，并把 §1.5 实测结果转成架构决定：

| # | 事项 | 工期 |
|---|---|---|
| 0.1 | **接遥测** — 当前 `DataSettings.tsx:5` 注释写着 "ycode collects nothing"，开关是摆设。所有优先级判断都在零数据下做的 | 1 天 |
| 0.2 | **`UnifiedEvent::ToolUse` 加 `call_id`** — `claude.rs:265` 已经读到 `tool_use_id`，是数据模型扔的。与 pi 无关 | 0.5 天 |
| 0.3 | **定进程生命周期策略** — §1.5 已实测 4 进程空载 544 MB，不必再测。改为决定：一会话一进程是否成立、后台会话保活还是回收、活进程上限是多少。**这是阶段 3 会话路由的前置输入，不定会返工** | 1 天 |
| 0.4 | **探针扩展验证 RPC 下的事件触达** — 20 行扩展装进 `~/.pi/agent/extensions/`，确认 `tool_call` 与 `project_trust` 在 `--mode rpc` 下真能触达。`project_trust` 在 `docs/rpc.md` 里零出现，只有 `docs/extensions.md` 定义过，这条路径的 RPC 侧文档是空白的 | 0.5 天 |

同时（零成本）：往 `~/Library/Application Support/dev.ycode.ycode/config.json`（注意：**不是** `~/.config/ycode/`，路径由 `ProjectDirs::from("dev","ycode","ycode")` 决定，见 `ycode-config/src/lib.rs:487`）加一条 pi 的 PTY profile，用现有终端轨跑一周体感。

### 阶段 1 · `crates/ycode-pi`（3 天）

- 子进程 + stdio + JSONL codec（§3.2 的分帧约束进单测）
- 命令层：`prompt` / `steer` / `follow_up` / `abort` / `clear_queue` / `get_state` / `get_entries` / `set_model` / `set_thinking_level` / `compact`
- 事件层：broadcast stream
- `tests/` 写 mock pi server，端到端不依赖真实 pi

### 阶段 2 · 事件模型 + 持久化（2 天）

- `UnifiedEvent` 三处调整：`seq` 语义放宽、加 `turn_id: Option<String>`、`call_id`（0.2 已做）
- SQLite 事件表 migration + `format_version`，**注释写清 §6 的历史**
- pi 事件 → `UnifiedEvent` 映射
- ❌ 不做 FTS5（决策 7，降 v1.1）

### 阶段 3 · 会话路由（1.5 天）

- `create_session` 从 `spawn_pty` 改为 spawn pi RPC
- `spawn_pty_raw` 不动
- 会话状态改由 `agent_start` / `agent_settled` 驱动，**删掉 `sessionStatus.ts` 里数 PTY 字节的启发式**
- 注意 `agent_settled` ≠ `agent_end`：后者只是一次运行结束，后面可能还有重试、压缩、队列续跑

### 阶段 4 · `ycode-bridge.ts` 桥接扩展（3 天）

一个 TS 扩展，装到 `~/.pi/agent/extensions/`（§3.1 硬约束）：

- `on("tool_call")` → 权限（§4），含 §12.1 的命令语义化预解析
- `on("project_trust")` → 信任（§5）
- `registerTool()` → todo，直连现有 UDS 控制 socket
- 九种 `extension_ui_request` 的完整消费（§4.5）

参照 `permission-gate.ts` / `protected-paths.ts` / `project-trust.ts` / `timed-confirm.ts` 四份官方实现，共 198 行。

### 阶段 4b · MCP 客户端扩展（3 天，新增）

pi 不支持 MCP，官方指路是写扩展（README:499）。这一块独立于 4，可并行：

- MCP 客户端（stdio + SSE），服务清单读 `~/.claude.json` 或 ycode 自己的配置
- 发现的 MCP 工具经 `pi.registerTool()` 注册进 pi，对 LLM 透明
- 状态机按 §12.2：`starting` / `ready` / `failed` / `cancelled` + `reauthenticationRequired`
- 复用 `crates/ycode-mcp` 的 UDS 桥接（§12.5 改判为保留）
- ⚠️ MCP 的 OAuth 登录 v1 不做，只支持无认证与 API key 两种

### 阶段 5 · `ConversationPane`（5 天）

- 从 `HistoryTab` 抽出 `ConversationView`，与历史共用
- 流式 markdown、可折叠工具调用、思考块、内联 diff
- **长输出虚拟化滚动**（一次 read 可能吐 5000 行）
- 滚动语义：自动跟随 / 上滚暂停 / 跳到最新
- 输入框三种回车语义 + `Esc` = `clear_queue` → `abort`（顺序不能反）
- `@` 文件补全 / `/` 命令补全（`get_commands`）
- 模型 + 思考等级选择器 — **档位 per-model，必须调 `get_available_thinking_levels`**，不是固定七档（`docs/rpc.md:312,341`）
- 上下文用量条 — 注意 `contextUsage` 有两种缺失态：无模型时整个字段省略；刚压缩完 `tokens`/`percent` 为 `null`（`docs/rpc.md:593`）

### 阶段 6 · 权限与信任的 ycode 侧 UI（4 天）

pi 侧管道在阶段 4 就通了，这里全是产品设计：

- 内联确认卡 + §4.4 的焦点切换
- 权限模式分级、按工具/路径规则
- 记住选择 + **撤销界面**（误点「不再问」要有后悔药）
- 项目信任提示 + trust.json 查看/撤销
- 左栏注意力：过滤条、按紧急度**跨项目组**排序、已读状态

### 阶段 7 · 清理与迁移（3 天）

- 删代码（§9）
- 老会话数据处置（决策 4：无入口、不碰文件）
- 升级到 1.0 的一次性说明页 + SQLite migration 回滚策略
- README 重写 —— 顺带修掉一条现存的**虚假宣称**："full-text search across past runs"，实际是 `service.rs:464` 的 substring 全扫，全库零 FTS5

### 合计

| 阶段 | 天 |
|---|---|
| 0 · 结论落定与正交先修 | 3 |
| 1 · `crates/ycode-pi` | 3 |
| 2 · 事件模型 + 持久化 | 2 |
| 3 · 会话路由 | 1.5 |
| 4 · `ycode-bridge.ts` | 3 |
| 4b · MCP 客户端扩展 | 3 |
| 5 · `ConversationPane` | 5 |
| 6 · 权限与信任 UI | 4 |
| 7 · 清理与迁移 | 3 |
| **合计** | **27.5** |

**27.5 天理想工期。** 单人项目按 1.8–2 倍算，**实际 50–55 天**。期间不发其他功能。

> 比早先版本多 4 天，全部来自 §12：MCP 自建 3 天（早先记为「不做」），权限的语义化预解析 1 天。换来的是四块能力有成熟设计可抄，而不是边做边想。

---

## 8. 风险

1. **迁移动机的强度**（中，较早先版本下调）。三条理由里订阅可用与开源可改都是硬的（§1.1）；`toolCallId` 和增量读能不换 runtime 就修，不计入。风险在于协议级会话控制的实际价值要用起来才知道。
2. **生态断裂**（高）。Claude Code 的 subagents / skills、Codex 的沙箱都不再继承。用户要为了 ycode 的 UI 换掉他们已经在用的 agent。
3. **N 个 Node 进程的内存**（高，**已实测坐实**）。四进程空载 544 MB，见 §1.5。不再是风险判断而是已知约束，处置方式在阶段 0.3 定。
4. **pi 上游变动**（中）。`ycode-pi` 只依赖协议稳定子集，mock server 锁行为，锁 pi 版本区间。
5. **pi + Node 的分发**（中）。pi 可经 homebrew / volta / bunx 到手，`node` 不一定在 PATH、不一定 ≥22.19。「装了 pi 就有 Node」这个推论不成立，检测要分开做。
6. **settings.json 的双编辑器问题**（中）。ycode 的扩展开关映射 `~/.pi/agent/settings.json` 的数组，但那些数组支持 glob、`!排除`、`+强制包含`、`-强制排除`（`docs/settings.md:292`），开关式 UI 表达不了。用户手写的模式会被 ycode 写回时抹掉。而 `pi config` 是同一份文件的官方编辑器，右栏终端里随时能跑。**已由 §13.5 解决**：装/卸调 `pi install`/`pi remove`，由 pi 自己写文件；其余配置引导 `pi config`。ycode 永不直接编辑这个文件，用户手写的模式就不会被抹掉。
7. **没有 E2E 回归**（中）。0.5.0 → 1.0 的架构断代，没有自动化保障。

---

## 9. 删除清单

| 项 | 行数 |
|---|---|
| `ycode-config/src/agent_patcher.rs` | 1556 |
| `crates/ycode-lsp` | 1949 |
| `introspect/{claude,codex}.rs` | 1143 |
| `IntegrationsSettings.tsx` | 565 |
| `ProjectsOverview.tsx` | 416 |
| `AgentsSettings.tsx` | 353 |
| `LanguagesSettings.tsx` | 346 |
| `crates/ycode-notify` | 273 |
| `lspExtension.ts` | 223 |
| `IconPicker.tsx` | 63 |
| `notify_listener.rs` 大部分 | ~700 / 889 |
| `TerminalPane.tsx` 的 agent 用途 | ~800 / 1167 |
| `EditorPanel.tsx` 的编辑/保存部分 | ~600 / 1393 |
| 8 个 LSP IPC 命令 | — |

**8987 行**（上表逐项求和，非估数）。`crates/ycode-mcp` 234 行**已从本清单移出** —— 既然要自建 MCP（§12.2），它的 UDS 桥接是现成资产。新增约 3000–3500 行（`ycode-pi` + `ConversationPane` + 权限 UI + 桥接扩展）。

> 行数已按实际文件核准：`IconPicker.tsx` 是 63 行不是 180；LSP 的 IPC 命令是 8 个不是 28 个（`lsp_definition` / `lsp_did_change` / `lsp_did_close` / `lsp_did_open` / `lsp_install` / `lsp_list_manifests` / `lsp_semantic_tokens_full` / `lsp_uninstall`，前后端一致）。

---

## 10. 开放问题

- **Q1 · 会话文件双写一致性**（新，早先方案没有）。决策用 pi 默认的 `~/.pi/agent/sessions/`，与 pi CLI 共享。用户在右栏终端 `pi -c` 续了同一个会话之后，ycode 的事件表怎么办？`get_entries(since)` 的 cursor 还有效吗（`docs/rpc.md:745`：id 匹配不上直接 `success: false`）？
- **Q2 · 一会话一进程是否成立** — 内存部分已实测回答（§1.5：四进程空载 544 MB）。剩下的问题变成架构选型：pi 协议是否支持单进程多会话？若不支持，后台会话是保活还是 LRU 回收？阶段 0.3 定。
- **Q3 · 超时的 `terminate` 整批语义** — §4.2 给了保守解法，做不做完整版看阶段 6 的实际情况。
- **Q4 · 原生 OAuth** — ⚠️ **已由 §1.1b 定案：不做。** 不是「悬置待议」——核了 `pi-ai` 的实现后确认，Claude 订阅路径依赖混淆的 client_id + 强制注入 Claude Code 身份 + 工具名改写。ycode 自己实现这套的性质，比转发用户已有配置严重得多。其他 provider 的订阅登录一律引导到终端跑 `pi`。
- **Q5 · `project_trust` 在 RPC 下的实际行为** — `docs/rpc.md` 里这个事件零出现，只有 `docs/extensions.md:353-368` 定义过。§5 的设计是对的，但 RPC 侧无文档背书，阶段 0.4 用探针扩展先验证再动工。

---

## 11. Non-goals

- 会话树 / fork UI（v2 —— 但注意 `fork` / `get_tree` / `clone` 是**现成 RPC 命令**，成本比「编辑上一条并重发」低，优先级排序可能要反过来）
- 语音输入、远程执行（v2+）
- FTS5 全文搜索（v1.1）
- 原生 OAuth 登录（悬置）
- 「任务」实体（决策 3）
- ycode 自己实现 LLM 调用（永远经 pi）
- Codex 式 sandbox（pi 明确不做，ycode 靠 worktree 隔离，见 §12.6）

**从 Non-goals 移出**：MCP 支持。早先按「pi 不支持 MCP」记为不做，现改为**自建**（§12.2）—— pi 官方 README:499 指的路就是写扩展。

---

## 12. 借鉴 Codex app-server 的四块能力

pi 刻意不做权限、不做 MCP、不做 sub-agents、不做内置 todo（`docs/usage.md:309`）。这四块 ycode 必须自建，而**设计不必从零想** —— Codex 的 app-server 把这四块都做成了协议一等公民，可以直接抄它的模型。

> 核验依据：`codex 0.149.1`，用 `codex app-server generate-json-schema` 导出的 **252 个 v2 类型**。下文每条都注明类型名，可自行复查。
>
> **只抄设计，不抄实现。** runtime 仍然是 pi（理由见 §1.1）。Codex 在这里的角色是「已经踩过坑的参考实现」。

### 12.0 先记一个架构事实

实测 codex app-server：**一个进程开 4 个 thread，总 RSS 164 MB**。对比 §1.5 实测的 pi：四个 `pi --mode rpc` 子进程 544 MB。三个项目（Codex、OpenCode、pi SDK）独立收敛到同一个模型 —— **一个常驻服务进程，内部多会话**。

这不改变 v1 的子进程选型（阶段 0.3 定），但记下来：如果后面内存成为瓶颈，pi SDK 的进程内多会话是有先例的正解。

### 12.1 权限：抄它的「语义化预解析」与「决策词汇」

Codex 的 `ExecCommandApprovalParams` 里有一个 `ParsedCommand` 判别联合，把命令**先解析成语义类型再问用户**：

| 类型 | 含义 |
|---|---|
| `read` | 读文件，带 best-effort 的 `path` |
| `list_files` | 列目录 |
| `search` | 搜索，带 `query` |
| `unknown` | 兜底 |

**这一条最值得抄。** 「要执行 `rg -n foo src/`，允许吗」对用户是噪音；「要在 `src/` 里搜 `foo`」才是人能一眼判断的。ycode 的内联确认卡（§4）应该显示语义化结果，原始命令收在折叠区。

决策词汇也比「允许/拒绝」两档细，`ExecCommandApprovalResponse` 的取值：

| 值 | 语义 |
|---|---|
| `approved` | 这一次 |
| `approved_for_session` | 本会话内不再问 ← 对应 spec 5.5 |
| `approved_execpolicy_amendment` | 顺手改写执行策略 |
| `approved_mcp_policy_amendment` | 顺手改写 MCP 策略 |
| `denied` | 拒绝 |
| `abort` | 拒绝并终止整轮 ← **正是 §4.2 纠结的 `terminate`** |

`abort` 独立成一个决策值，而不是 `denied` 上的一个布尔标志。ycode 应照此设计：**「拒绝」和「拒绝并停下」是两个选项**，不是一个选项加参数。这比 §4.2 维护「本批次未决调用计数」干净得多。

分级模式用 `AskForApproval`：三档 `untrusted` / `on-request` / `never`，外加一个 `granular` 对象单独开关 `mcp_elicitations` / `rules` / `sandbox_approval` / `skill_approval` / `request_permissions`。对应 spec 5.2，比「需确认 / 跳过确认」两档合理。

还有一条结构上的讲究：`FileChangeRequestApprovalParams` 里**不带 diff 内容**，只有 `itemId` + `threadId` + `turnId` + `startedAtMs`，diff 由客户端拿 id 去取。审批消息保持小而稳，大载荷走另一条路。ycode 做 spec 5.11（批准前 diff 预览）时应照抄：审批事件只带 id，diff 从事件表读。

`startedAtMs` 也值得抄 —— 有了它，「这条请求等了多久」是客户端算出来的，不需要协议里有 timeout 字段。正好契合 §4.2「不传 timeout」的结论。

**落点**：§4 的 `ycode-bridge.ts` 与阶段 6 的权限 UI。

### 12.2 MCP：pi 官方指路就是「写个扩展」

pi 的 README:499 原文：**"Build ... an extension that adds MCP support"**。这是官方认可的路径，不是 hack。

抄 Codex 的状态模型 `McpServerStatusUpdatedNotification`：

```
McpServerStartupState: starting | ready | failed | cancelled
McpServerStartupFailureReason: reauthenticationRequired
```

四态加一个专门的失败原因。`reauthenticationRequired` 单独成因，因为它的处置方式和别的失败完全不同 —— 要跳登录，不是重试。ycode 的 MCP 面板照此建模，别用 bool 表示「连上了没」。

另外 Codex 把 MCP 的 OAuth 登录也做进了协议（`McpServerOauthLoginParams` / `...CompletedNotification`），说明这是真实会撞上的场景。

**落点**：新增一节，`crates/ycode-mcp` 的处置要从「整个作废」改判 —— 见 §12.5。

### 12.3 sub-agent：抄它的 reviewer 概念，别抄 pi 示例的进程模型

pi 官方有 `examples/extensions/subagent/`（1195 行），但**它给每个 subagent 起一个独立 pi 进程**（`index.ts:300` 用 `--mode json -p --no-session` spawn）。按 §1.5 实测的 135 MB/进程，三个 subagent 并行就是 400 MB+。**这个示例可以读，不能照抄。**

Codex 那边值得抄的是一个概念：`ApprovalsReviewer`。

```
user | auto_review | guardian_subagent
```

原文说明 `auto_review` 是「用一个精心提示的 subagent 先收集上下文、按风险框架判断，再批准或拒绝」。**这是 sub-agent 和权限两块的交汇点** —— subagent 不只是「并行干活」，还可以是「替你看权限请求」。

对 ycode 的意义：spec 3.36 把 sub-agents 排在 P2，但如果 sub-agent 的第一个用途是**自动审批低风险请求**，它就直接服务于 v1 的差异化锚点（spec 5.11 批准前 diff 预览）。优先级可能要重排。

**落点**：v1 不做，但权限层的接口设计要预留「审批人可以不是用户」这个维度，别把 `reviewer` 写死成人。

### 12.4 todo：Codex 分成了两个概念，ycode 现在混在一起

这是四块里最容易忽略的一条。Codex 有两套：

| 类型 | 语义 | 状态机 |
|---|---|---|
| `ThreadGoal` | **会话级目标**，用户设的 | `active` / `paused` / `blocked` / `usageLimited` / `budgetLimited` / `complete` |
| `TurnPlan` | **本轮计划**，agent 自己列的 | 每步 `pending` / `inProgress` / `completed` |

ycode 现在只有一个 `project_todos` 表（三态 todo/doing/done），承担的是 `ThreadGoal` 的角色。而 spec 7.6「agent 自己的 plan/todo 展示归属」标着 P1 悬而未决 —— **它对应的就是 `TurnPlan`，是另一个东西**，不该塞进同一张表。

`ThreadGoal` 的状态机里 `usageLimited` / `budgetLimited` 尤其值得抄：会话停下来的原因是「额度用完」还是「被阻塞」，对用户是完全不同的两件事。ycode 的 AttentionInbox（spec 7.1）按这个分类排序会准得多。

`ThreadGoal` 还带 `tokenBudget`，把预算绑在目标上而不是全局设置里。对应 spec 9.4 的预算告警。

**落点**：`project_todos` 保持不动（那是 ThreadGoal）；`TurnPlan` 走 pi 的 `registerTool()` + 事件表，在对话流内联渲染，不进 todo 面板。

### 12.5 连带的改判

| 原结论 | 改判 |
|---|---|
| `crates/ycode-mcp` 234 行整个作废（spec 7.5） | **不删。** 既然要自建 MCP（12.2），这 234 行的 UDS 桥接逻辑是现成资产，从「给 Claude Code 用」改成「给 pi 的 MCP 扩展用」 |
| sub-agents 排 P2（spec 3.36） | 维持 P2，但接口预留 reviewer 维度（12.3） |
| 权限 `terminate` 要维护批次计数（§4.2） | **简化。** 改成 `denied` / `abort` 两个独立决策值（12.1） |
| §9 删除清单合计 9221 行 | 减去 `ycode-mcp` 的 234，**改为 8987 行** |

### 12.6 不抄的部分

- **Codex 的 sandbox** —— pi 明确不做沙箱（`docs/security.md`「No Built-in Sandbox」），ycode 也不做，靠 worktree 隔离
- **252 个类型的协议规模** —— ycode 的 `UnifiedEvent` 保持小，只抄语义分类不抄类型数量
- **app-server 的 daemon 架构** —— v1 维持一会话一进程（阶段 0.3 定），12.0 只是记录先例

---

## 13. 扩展安装：UI 点一下，后台跑命令

用户在 ycode 里点「安装」，ycode 后台执行 `pi install <source>`。这是 spec 11.11 从 P2 升到 **P1** 的那一条，也是「可自定义」这条选型理由的落点 —— 否则用户只能在终端里手敲，ycode 的可扩展性等于零。

### 13.1 先看清楚点一下到底发生什么

实测 `pi install npm:pi-spark`（`pi 0.85.1`，隔离 HOME）：

```
Installing npm:pi-spark...
added 40 packages, and audited 42 packages in 8s
Installed npm:pi-spark
```

**一次点击拉了 40 个包。** 链路是：`pi install` → 写 `settings.json` 的 `packages` 数组 → 在 `~/.pi/agent/npm/` 跑 `npm install`。

三个必须正视的事实：

1. **`npm install` 会执行 `postinstall` 脚本** —— 安装时就跑任意代码，早于任何人审阅源码
2. **扩展本身以完整用户权限运行**（`docs/packages.md:20` 原文："Pi packages run with full system access. Extensions execute arbitrary code... Review source code before installing third-party packages."）
3. **卸载不干净** —— 实测 `pi remove` 之后 `settings.json` 的数组清空了，但 `~/.pi/agent/npm/node_modules/` 里的文件**还在**

抽查 npm 上现有的 4 个 `pi-package`，`postinstall` 类脚本目前都是空的。**但这是当下的运气，不是机制保证。**

> **结论**：这个功能的难点不是调 `pi install`（一行 `Command::new`），是**让用户在点之前知道自己在装什么**。UI 做得越顺滑，风险越大。

### 13.2 安装前能拿到什么（不执行任何代码）

好消息：`npm view <pkg> --json` 在**不安装、不执行**的前提下就能拿到足够做预览的元数据。实测 `pi-spark`：

| 字段 | 值 | 给用户看什么 |
|---|---|---|
| `name` / `version` | pi-spark 0.22.3 | 标题 |
| `description` | Pi package that polishes... | 一句话说明 |
| `license` | MIT | 许可证 |
| `homepage` | github.com/zlliang/pi-spark | **「查看源码」链接** |
| `scripts` | `{typecheck}` | ⚠️ **有无 postinstall，红字标出** |
| `dependencies` | 7 个 | 「将额外安装 N 个依赖」 |
| `pi` manifest | `{extensions, themes}` | **它会注册什么**：扩展？主题？技能？ |

`pi` manifest 那条最有用 —— 它直接告诉用户这个包会往 agent 里塞什么。只装主题和装一个能拦所有工具调用的扩展，风险完全不是一回事。

### 13.3 安装流程设计

```
扩展市场（读 npm keyword: pi-package）
   │
   ├─ 列表：名称 · 描述 · 作者 · 周下载量 · 许可证
   │
   ▼ 点「安装」
┌─────────────────────────────────────────────┐
│ 安装 pi-spark 0.22.3                        │
│                                             │
│ 它会注册：扩展 × 1 · 主题 × 1               │
│ 额外安装 7 个依赖                           │
│ 许可证 MIT ·「查看源码 ↗」                  │
│                                             │
│ ⚠️ 扩展以你的完整权限运行，可读写任何文件、  │
│    执行任何命令。只装你信任的来源。          │
│                                             │
│ [ 查看源码 ]  [ 取消 ]  [ 我了解风险，安装 ] │
└─────────────────────────────────────────────┘
   │
   ▼ 确认后
后台执行 pi install npm:pi-spark
   ├─ 实时把 stdout/stderr 流到 UI（8 秒不是瞬间，不能装没发生）
   ├─ 失败 → 原样展示错误 + 「复制命令手动重试」
   └─ 成功 → 刷新列表，提示「重启会话后生效」
```

**有 `postinstall` 脚本时，确认框换一套更强的措辞**，并默认折叠安装按钮。这是唯一一个 ycode 主动帮用户执行第三方代码的地方，摩擦是特性不是缺陷。

### 13.4 边界：装什么、不装什么

| 来源 | v1 | 理由 |
|---|---|---|
| `npm:<pkg>` | ✅ | 有 registry 元数据可预览 |
| `git:<url>@<ref>` | ✅ 但需手输 | 无 registry 元数据，只能显示 URL + ref。**必须钉 ref**，不接受浮动分支 |
| 本地路径 | ✅ | 用户自己的代码，风险自负 |
| 裸 `https://` | ❌ v1 | 和 git 同源但更容易误粘贴 |

**作用域**：v1 只写**全局**（`~/.pi/agent/settings.json`）。项目级安装（`pi install -l`）意味着「打开某个项目就装它指定的包」，那是另一条信任链，和 §5 的项目信任耦合，v1 不做。

### 13.5 和「settings.json 只读」的冲突 —— 改判

风险 6 和 spec 11.10 都写着 **v1 对 `settings.json` 只读不写**，理由是那些数组支持 glob / `!排除` / `+强制包含`，开关式 UI 表达不了，写回会抹掉用户手写的模式。

**安装功能要求写 `packages` 数组，和这条直接冲突。** 改判如下：

| 操作 | v1 |
|---|---|
| 装 / 卸包 | ✅ **不由 ycode 写文件**，调 `pi install` / `pi remove`，由 pi 自己改 —— 它是这个文件的官方编辑器 |
| 启用 / 禁用单个资源 | ❌ 引导跑 `pi config` |
| 编辑 glob / 排除模式 | ❌ 引导跑 `pi config` |

关键是**不绕过 pi 直接改文件**。ycode 只发命令，写文件的永远是 pi。这样用户手写的 glob 不会被抹掉，冲突自然消解。

### 13.6 卸载要说实话

实测：`pi remove` 清空了 settings 数组，但 `node_modules/` 里的文件还在。

UI 上不能说「已删除」，要说「**已停用，磁盘文件保留**」，并给一个「清理残留文件」的二级操作，显示实际占用。用户以为卸干净了而实际没有，是信任问题。

### 13.7 落到 BDD

新增场景，归入 [`bdd-iteration-plan.md`](bdd-iteration-plan.md) 迭代 8：

| 场景 | 层 |
|---|---|
| Given 我在扩展市场, When 点某个包的安装, Then 先看到它会注册什么、装多少依赖、许可证与源码链接 | L2 |
| Given 某包带 `postinstall` 脚本, When 我点安装, Then 确认框显式警示且措辞升级 | L2 |
| Given 我确认安装, When 后台执行, Then 命令输出实时流到 UI，不是转圈后突然完成 | L2 + L3 |
| Given 安装失败, When 查看, Then 看到原始错误和可复制的手动命令 | L2 |
| Given 我卸载一个包, When 完成, Then 提示「已停用，磁盘文件保留」而非「已删除」 | L2 |
| Given ycode 装了包, When 检查 settings.json, Then 用户手写的 glob 模式原样保留 | L1 + L3 |
