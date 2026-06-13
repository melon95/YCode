# LSP（Language Server Protocol）功能开发文档

> 状态：已实现（PR1 安装/卸载 + PR2 client/编辑器集成）
> 适用范围：ycode 内部接入，以及在其它项目复用本套 LSP 客户端骨架

## 一句话

ycode 以「插件化下载」的方式接入语言服务器：用户在 **设置 → Languages** 里点击安装某个语言的 LSP（二进制下载或 npm 安装），安装后编辑器自动获得**语义高亮**（semantic tokens）和**跳转到定义**（go-to-definition，⌘/Ctrl + 点击）。

整套实现自己手写了 JSON-RPC 2.0 over stdio 的客户端，**不依赖** `tower-lsp` / `lsp-types` 等第三方库，协议面尽量小、依赖少。

---

## 目录

- [整体架构](#整体架构)
- [后端：ycode-lsp crate](#后端ycode-lsp-crate)
- [持久化：lsp_installations 表](#持久化lsp_installations-表)
- [IPC 层：Service + Tauri commands + 事件](#ipc-层service--tauri-commands--事件)
- [前端集成](#前端集成)
- [端到端数据流](#端到端数据流)
- [扩展指南：新增一个语言服务器](#扩展指南新增一个语言服务器)
- [复用指南：在其它地方接入这套 LSP 客户端](#复用指南在其它地方接入这套-lsp-客户端)
- [已知限制 / TODO](#已知限制--todo)

---

## 整体架构

```
┌─────────────────────────── 前端 (React + CodeMirror 6) ───────────────────────────┐
│ LanguagesSettings.tsx   设置页：列出 manifest、安装/卸载、进度条                       │
│ EditorPanel.tsx         文件 open/change/close → LSP；⌘+click → 跳转；语义高亮         │
│ lib/lspExtension.ts     CM6 扩展：semantic token 解码 + goto-def + cmd-hover 下划线    │
│ lib/ipc.ts              invoke() 包装：lspInstall / lspDidOpen / lspDefinition ...     │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                         │ Tauri invoke / event
┌───────────────────────────────────────▼───────────────────────────────────────────┐
│ src-tauri/src/commands.rs   #[tauri::command] 薄包装，转发到 Service                  │
│ src-tauri/src/lib.rs        invoke_handler! 注册 + 事件 pump（broadcast → webview）   │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                         │
┌───────────────────────────────────────▼───────────────────────────────────────────┐
│ ycode-ipc::Service          持有 Arc<LspManager>；暴露 lsp_* 业务方法                  │
│                             把 ServerNotification 翻译成 UiEvent 发到 ui_bus           │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                         │
        ┌────────────────────────────────┼────────────────────────────────┐
        ▼                                                                  ▼
┌──────────────────────────┐                              ┌──────────────────────────────┐
│ ycode-lsp (新 crate)     │                              │ ycode-persist                │
│  manifest  内置服务器清单 │                              │  lsp_installations 表         │
│  installer 下载/解压/npm  │                              │  LspInstallationRepo          │
│  protocol  JSON-RPC 帧    │                              └──────────────────────────────┘
│  client    LspSession     │
│  manager   LspManager     │
│  dirs      安装目录布局    │
└──────────────────────────┘
```

依赖方向是单向的：`ycode-lsp` 不认识 `ycode-ipc`，通过一个回调（`NotificationSink`）把服务器主动推送的消息（如诊断）交回给 `Service`，由后者翻译成 `UiEvent`。

---

## 后端：ycode-lsp crate

路径：`crates/ycode-lsp/`。`Cargo.toml` 关键依赖：`tokio`（process/io）、`reqwest`（rustls，下载）、`flate2`（gunzip）、`serde_json`、`ts-rs`（前端类型）、`ycode-persist`（查安装记录）。

模块一览（`src/lib.rs` 导出）：

| 模块 | 职责 |
|------|------|
| `manifest` | 内置语言服务器清单（`ServerManifest`），描述如何下载、如何启动 |
| `installer` | 执行安装：GitHub release 二进制 或 npm 包；流式进度 |
| `dirs` | 安装目录布局（`<data_dir>/lsp/<server_id>/`） |
| `protocol` | JSON-RPC 2.0 `Content-Length` 帧编解码（裸字节层） |
| `client` | `LspSession`：一个运行中的语言服务器进程 + 握手 + 请求/响应路由 |
| `manager` | `LspManager`：按 `(project_id, server_id)` 缓存 session，按扩展名路由 |
| `error` | `LspError` 统一错误类型 |

### manifest.rs — 内置清单

核心结构（均派生 `ts-rs::TS`，前端类型自动生成到 `crates/ycode-ipc/bindings/`）：

```rust
pub struct ServerManifest {
    pub id: String,                  // 稳定 id，也是安装目录名，如 "rust-analyzer"
    pub display_name: String,
    pub description: String,
    pub language_ids: Vec<String>,   // LSP languageId，如 ["typescript", "typescriptreact", ...]
    pub file_extensions: Vec<String>,// 路由用，如 [".ts", ".tsx"]（含点，小写）
    pub homepage: Option<String>,
    pub install: InstallSpec,        // 怎么装
    pub command: CommandSpec,        // 装好后怎么启动（binary/args 支持 ${SERVER_DIR} 占位）
}

pub enum InstallSpec {
    GithubReleaseGzip { repo, assets: AssetPattern, binary_name },  // 拉 GitHub release 的 .gz 单文件
    Npm { packages: Vec<String> },                                  // 在隔离目录跑 npm install
}
```

目前内置两条：`rust-analyzer`（GitHub release，无依赖）和 `typescript-language-server`（npm，需要 `npm` 在 PATH）。

- `builtin_manifests() -> Vec<ServerManifest>`：返回清单（顺序即 UI 展示顺序）。
- `manifest_by_id(id) -> Option<ServerManifest>`：按 id 查。
- `AssetPattern::for_current_platform()`：按 `darwin-aarch64 / darwin-x86_64 / linux-x86_64 / linux-aarch64 / windows-x86_64` 选 release 资产名。

### installer.rs — 安装

```rust
pub async fn install(
    manifest: &ServerManifest,
    progress: mpsc::Sender<InstallProgress>,   // 进度回调，接收方掉线不影响安装完成
) -> Result<InstallOutcome, LspError>;          // 返回 { server_id, version, binary_path }

pub async fn uninstall(server_id: &str) -> Result<(), LspError>;  // 删安装目录
```

- **GithubReleaseGzip**：打 `/repos/<repo>/releases/latest`，按平台匹配资产 → 流式下载 `.gz`（边下边发 `InstallProgress`，含百分比，字节数格式化为 MB）→ gunzip 到 `<server_dir>/<binary_name>` → `chmod 755`。
- **Npm**：先检查 `npm` 在 PATH，在 `<server_dir>` 写最小 `package.json`，跑 `npm install --no-audit --no-fund <packages>`，再从 `node_modules/<pkg>/package.json` 读版本号。
- `InstallProgress { server_id, stage: InstallStage, percent: Option<u8>, message }`，`InstallStage` = `Resolving | Downloading | Extracting | RunningNpm | Finalizing`。

### protocol.rs — JSON-RPC 帧

LSP 的传输格式是 `Content-Length: N\r\n\r\n<json>`。本模块只管裸字节：

```rust
pub async fn read_message<R>(r: &mut BufReader<R>) -> io::Result<Option<Vec<u8>>>;  // None = EOF
pub async fn write_message<W>(w: &mut W, body: &[u8]) -> io::Result<()>;
```

`IncomingMessage` 用「字段是否存在」来区分 请求/响应/通知（有 `id` 无 `method` = 响应；有 `method` 无 `id` = 通知；都有 = 服务器发起的请求，目前忽略）。

### client.rs — LspSession（一个运行中的服务器）

```rust
pub async fn LspSession::spawn(
    manifest: &ServerManifest,
    project_id: String,
    project_root: &Path,
    sink: NotificationSink,          // 服务器主动推送（如诊断）的回调
) -> Result<Arc<LspSession>, LspError>;
```

`spawn` 做的事：
1. 用 `tokio::process::Command` 启动 `command.binary`（替换 `${SERVER_DIR}` 占位），`kill_on_drop(true)`，stdin/stdout/stderr 全 piped。
2. 起三个后台 task：
   - **writer**：从 `mpsc` 队列取 body，逐帧写 stdin（调用方发消息无需加锁）。
   - **reader**：逐帧读 stdout，响应按 id 路由到 `pending: HashMap<RequestId, oneshot::Sender>`；通知交给 `sink`。
   - **stderr drain**：避免 stderr 管道写满阻塞子进程，顺便把服务器日志写进 tracing。
3. 起一个 task `child.wait()` 回收进程，避免僵尸。
4. 完成 `initialize` / `initialized` 握手（**阻塞到握手完成**，所以 `spawn` 返回时服务器已就绪）。握手里声明了客户端能力：`definition`、`semanticTokens`（带固定的 token 类型表）、`publishDiagnostics`。

对外方法（都返回原始 `serde_json::Value`，不做归一化，交给前端）：

```rust
session.did_open(uri, language_id, version, text)
session.did_change_full(uri, version, text)   // 全量同步（不是增量）
session.did_close(uri)
session.definition(uri, line, character) -> Value
session.semantic_tokens_full(uri) -> Value
session.shutdown()                            // 发 shutdown + exit，best-effort
```

**Token 类型表**：`client::TOKEN_TYPES`（23 项：namespace/type/class/.../decorator）。这张表是前后端约定，**必须**和前端 `src/lib/lspExtension.ts` 的 `LSP_TOKEN_TYPES` 顺序一致，否则语义高亮颜色会错位。

**`path_to_file_uri(path) -> String`**：把 OS 路径转 `file://` URI，对空格/非 ASCII 做百分号编码，保留 `/` 和 `:`。

### manager.rs — LspManager（per-project 集群）

```rust
LspManager::new(db: Db, sink: NotificationSink)

// 按文件扩展名找 manifest（大小写不敏感）
LspManager::manifest_for_file(file_path) -> Option<ServerManifest>
// 该文件对应的 languageId
LspManager::language_id_for(manifest, file_path) -> &str

// 取或起 session（按 (project_id, server_id) 缓存）。未安装 → Err(UnknownServer)
manager.get_or_spawn(project_id, project_root, manifest) -> Result<Arc<LspSession>, LspError>
manager.get(project_id, server_id) -> Option<Arc<LspSession>>   // 只取不起
manager.shutdown_all()                                           // 退出时优雅关闭
```

`get_or_spawn` 会先查 `lsp_installations` 表确认已安装、且二进制文件还在磁盘上；没装就返回 `UnknownServer`，上层据此「静默跳过」（编辑器照常工作，只是没有 LSP 能力）。

---

## 持久化：lsp_installations 表

迁移文件：`crates/ycode-persist/migrations/0007_lsp_installations.sql`

```sql
CREATE TABLE lsp_installations (
    id           TEXT PRIMARY KEY,   -- 对应 ServerManifest.id
    version      TEXT NOT NULL,      -- 如 "2024-08-01" / "v4.2.0"
    binary_path  TEXT NOT NULL,      -- 安装后的绝对路径
    installed_at INTEGER NOT NULL    -- unix ms
);
```

仓库类型 `ycode_persist::LspInstallationRepo`（`db.lsp_installations()`）：`upsert`（重装覆盖）、`list`、`get(id)`、`delete(id)`。

---

## IPC 层：Service + Tauri commands + 事件

### Service（`crates/ycode-ipc/src/service.rs`）

`Service` 持有 `lsp: Arc<LspManager>`。构造时注入一个 `NotificationSink` 闭包，把 `ServerNotification::PublishDiagnostics` 翻译成 `UiEvent::lsp_diagnostics(...)` 发到 `ui_bus`（这样 `ycode-lsp` 不必依赖 `ycode-ipc` 的事件类型）。

业务方法：

```rust
service.lsp_list_manifests() -> Vec<LspManifestView>   // 清单 + 本地安装状态 + 平台支持 + 依赖提示
service.lsp_install(server_id)                          // 后台跑，进度走事件
service.lsp_uninstall(server_id)
service.lsp_did_open(project_id, file_path, content, version) -> bool   // true=有 server 接管
service.lsp_did_change(project_id, file_path, version, content) -> bool // 不会按需 spawn
service.lsp_did_close(project_id, file_path)
service.lsp_definition(project_id, file_path, line, character) -> Value
service.lsp_semantic_tokens_full(project_id, file_path) -> Value
service.shutdown_async()                                // 退出时 = cancel token + lsp.shutdown_all()
```

私有助手 `lsp_session_for(project_id, file_path)`：按扩展名找 manifest → 算绝对路径与 `file://` URI → `get_or_spawn`；未安装返回 `Ok(None)`，让上层静默跳过。

### Tauri commands（`src-tauri/src/commands.rs` + 注册在 `lib.rs`）

8 个命令：`lsp_list_manifests`、`lsp_install`、`lsp_uninstall`、`lsp_did_open`、`lsp_did_change`、`lsp_did_close`、`lsp_definition`、`lsp_semantic_tokens_full`。都是一行转发到 `Service`。

### 事件（`crates/ycode-ipc/src/events.rs`，`UiEventKind`）

通过 `"ycode://session"` channel 发到 webview：

| 事件 | 字段 | 用途 |
|------|------|------|
| `LspInstallProgress` | `stage, percent, message` | 安装进度条（`session_id` 携带 server_id） |
| `LspInstallFinished` | `ok, version, error` | 安装结束（成功/失败），UI 刷新列表 + toast |
| `LspUninstalled` | — | 卸载完成，UI 刷新 |
| `LspDiagnostics` | `server_id, uri, params` | 透传 `publishDiagnostics`（前端暂未消费） |

> 所有跨 Rust↔TS 的结构体都派生 `ts-rs::TS`，运行 `cargo test -p ycode-lsp`（或 ipc）会把 `.ts` binding 生成到 `crates/ycode-ipc/bindings/`，前端通过 `@bindings/*` 别名引用。

---

## 前端集成

### lib/ipc.ts

`invoke()` 的薄包装，命名对应每个 command：`lspListManifests`、`lspInstall`、`lspUninstall`、`lspDidOpen`、`lspDidChange`、`lspDidClose`、`lspDefinition`、`lspSemanticTokensFull`。事件通过既有的 `listenSessionEvents` 监听。

### lib/types.ts

把 ts-rs 生成的 binding 重导出，并把 `i64`（被 ts-rs 标为 `bigint`，但 Tauri 实际传 number）的字段（`installed_at_ms`）retype 成 `number`：`LspManifestView` / `LspInstallationView`。

### lib/lspExtension.ts — CodeMirror 6 扩展

- `LSP_TOKEN_TYPES`：**必须与 Rust `TOKEN_TYPES` 同序**。
- `applyLspTokens(view, response)`：把 LSP 的 delta 编码（每 5 个数字一组：deltaLine/deltaCol/len/typeIdx/modifiers）解码成 CM6 `Decoration`，class 为 `lsp-token-<type>`（颜色在 `styles.css` 里，依赖 `--syntax-*` 变量）。
- `createLspExtension({ onGotoDef })`：返回扩展数组，包含
  - semantic token 的 `StateField`；
  - `mousedown`：⌘/Ctrl+左键 → 调 `onGotoDef(line, ch)`（0-indexed，LSP 约定）；
  - `mousemove` / `mouseleave` / `keyup`：⌘/Ctrl 悬停时给单词加下划线（`.cm-lsp-goto-link`），松开/移开清除——可点击提示。

### components/EditorPanel.tsx

- 文件加载完成（非二进制）→ `lspDidOpen`，返回 `true` 才继续后续调用，并拉一次 semantic tokens。
- `onChange` → 300ms 防抖的 `lspDidChange`（版本号自增），随后重新拉 semantic tokens。
- 关闭 tab → `lspDidClose` + 清理防抖 timer。
- ⌘+点击 → `lspDefinition` → `pickLspLocation` 归一化三种返回（`Location` / `Location[]` / `LocationLink[]`）→ `parseFileUri` 解析 `file://` → 复用既有的 `ycode:editor-goto` 事件跳转。

### components/LanguagesSettings.tsx

设置页 **Languages** tab（注册在 `SettingsModal.tsx` 的 `SECTIONS`）。每个 manifest 一张卡：名称/id/描述/支持扩展名/状态徽章（未安装 / 安装中+进度条 / 已安装+版本）/安装或卸载按钮。订阅 `LspInstallProgress` / `LspInstallFinished` / `LspUninstalled` 事件刷新。平台不支持或缺依赖（npm 不在 PATH）时禁用安装并给提示。

---

## 端到端数据流

**安装：**
```
LanguagesSettings 点击 Install
  → lspInstall(id)  → command  → Service.lsp_install
  → tokio::spawn { installer::install(manifest, tx) }
       progress 经 mpsc → UiEvent::LspInstallProgress → webview 进度条
  → 成功：写 lsp_installations 表 → UiEvent::LspInstallFinished → UI 刷新 + toast
```

**语义高亮 / 跳转：**
```
打开 .rs 文件
  → EditorPanel: lspDidOpen → Service.lsp_did_open
       → LspManager.get_or_spawn（首次会 spawn rust-analyzer + initialize 握手）
       → session.did_open(...)
  → lspSemanticTokensFull → session.semantic_tokens_full → 原始 data 数组
       → applyLspTokens 解码 → CM6 Decoration 上色

⌘+点击符号
  → lspDefinition → session.definition(uri,line,ch) → Location(s)
  → pickLspLocation + parseFileUri → ycode:editor-goto → 编辑器跳转
```

---

## 扩展指南：新增一个语言服务器

绝大多数情况下**只改一个文件**：`crates/ycode-lsp/src/manifest.rs` 的 `builtin_manifests()`，加一条 `ServerManifest`。

**例：加 gopls（GitHub release 二进制场景）**
```rust
ServerManifest {
    id: "gopls".into(),
    display_name: "Go (gopls)".into(),
    description: "Go language server.".into(),
    language_ids: vec!["go".into()],
    file_extensions: vec![".go".into()],
    homepage: Some("https://...".into()),
    install: InstallSpec::GithubReleaseGzip {
        repo: "owner/repo".into(),
        assets: AssetPattern {
            darwin_aarch64: Some("gopls-darwin-arm64.gz".into()),
            // ... 其它平台
            ..Default 各平台 Option
        },
        binary_name: "gopls".into(),
    },
    command: CommandSpec { binary: "${SERVER_DIR}/gopls".into(), args: vec![] },
}
```

**例：npm 场景**（如 `pyright`）
```rust
install: InstallSpec::Npm { packages: vec!["pyright".into()] },
command: CommandSpec {
    binary: "${SERVER_DIR}/node_modules/.bin/pyright-langserver".into(),
    args: vec!["--stdio".into()],
},
```

注意：
- `file_extensions` 与 `language_ids` 的**顺序对应**（第 i 个扩展名用第 i 个 languageId；不够则回退到第一个）。
- 加完跑一次 `cargo test -p ycode-lsp` 重新生成 binding，前端无需改动即可在设置页看到新卡片。
- 如果该 server 需要新的语义 token 类型 / 想支持新能力（hover/completion 等），才需要动 `client.rs`（握手能力声明 + 新方法）和前端。

---

## 复用指南：在其它地方接入这套 LSP 客户端

`ycode-lsp` 设计上**与 ycode 业务解耦**，可以单独拿去用。最小接入：

```rust
use std::sync::Arc;
use ycode_lsp::{manifest_by_id, LspManager, ServerNotification, NotificationSink};

// 1) 提供一个回调，处理服务器主动推送（诊断等）
let sink: NotificationSink = Arc::new(|server_id, notif| match notif {
    ServerNotification::PublishDiagnostics { uri, params } => {
        // 自己的分发逻辑（推 UI、记录等）
    }
});

// 2) 建 manager（需要一个 ycode_persist::Db 来查安装记录）
let manager = LspManager::new(db, sink);

// 3) 取/起 session 并调用
if let Some(manifest) = LspManager::manifest_for_file("src/main.rs") {
    let session = manager.get_or_spawn("proj-1", project_root, manifest).await?;
    let uri = ycode_lsp::path_to_file_uri(&abs_path);
    session.did_open(&uri, "rust", 1, &content).await?;
    let defs = session.definition(&uri, 10, 4).await?;   // 原始 LSP Value
}
```

如果不需要 ycode 的安装体系，也可以**只用 `protocol` + `client`**：
- `protocol::{read_message, write_message}` 是通用的 LSP 帧编解码。
- `LspSession::spawn` 需要一个 `ServerManifest`（主要用其 `command`），可以构造一个最小 manifest 指向已有二进制；它会自动完成握手、起 reader/writer，之后用 `request(method, params)` / `notify(method, params)` 调任意 LSP 方法。
- `get_or_spawn` 依赖 `lsp_installations` 表确认安装；若脱离 ycode 的 DB，直接用 `LspSession::spawn` 绕过 manager 即可。

要点：
- **全量同步**：`did_change_full` 发整篇文本，没做增量。文档大时有开销，但实现简单、不易错位。
- **请求路由**：靠递增的数字 id + `oneshot`，服务器退出会把所有 pending 请求以错误结束，调用方不会挂死。
- **进程回收**：`kill_on_drop(true)` + 独立 `wait` task；`session` 被 drop 即杀子进程。

---

## 已知限制 / TODO

- **能力范围**：当前只做了 definition + semantic tokens（+ 诊断透传未消费）。hover / completion / rename / formatting / references 均**未实现**——要加需在 `client.rs` 握手里声明能力、加方法，并在前端接 CM6 扩展。
- **诊断未渲染**：后端已透传 `LspDiagnostics` 事件，前端尚未画下划线/错误列表。
- **单 server / 文件**：`manifest_for_file` 第一个匹配的扩展名即胜出，不处理一个文件多 server。
- **无增量同步**：见上。
- **npm 安装依赖宿主 Node**：`typescript-language-server` 需要 `npm` 在 PATH；GUI 启动的 macOS app 的 PATH 由 `src-tauri/src/lib.rs` 的 `augment_path()` 补过常见目录。
- **服务器发起的请求**：`client.rs` 目前忽略服务器→客户端的请求（如 `window/workDoneProgress/create`），只记日志。需要时再补回应逻辑。

---

## 相关文件清单

| 层 | 文件 |
|----|------|
| 后端 crate | `crates/ycode-lsp/src/{lib,manifest,installer,protocol,client,manager,dirs,error}.rs` |
| 持久化 | `crates/ycode-persist/migrations/0007_lsp_installations.sql`、`crates/ycode-persist/src/lsp_repo.rs` |
| IPC | `crates/ycode-ipc/src/{service,events,lib}.rs` |
| Tauri | `src-tauri/src/{commands,lib}.rs` |
| 前端 | `src/lib/{ipc,types,lspExtension}.ts`、`src/components/{EditorPanel,LanguagesSettings,SettingsModal}.tsx`、`src/styles.css`（`.lsp-token-*` / `.lsp-card-*` / `.cm-lsp-goto-link`） |
| 类型 binding | `crates/ycode-ipc/bindings/{ServerManifest,InstallSpec,AssetPattern,CommandSpec,InstallStage,InstallProgress,LspManifestView,LspInstallationView}.ts` |
