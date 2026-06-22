//! `Service` — concrete IPC command handler.
//!
//! Owns the `TerminalManager` (the live PTY registry), the `Db` (project +
//! session rows), and the loaded `Config`. Each method corresponds to one
//! IPC command exposed by the Tauri shell.
//!
//! Methods deliberately avoid Tauri-specific types so this crate stays
//! transport-agnostic.

use std::{collections::BTreeMap, path::PathBuf, sync::Arc};

use camino::{Utf8Path, Utf8PathBuf};
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use ycode_config::{AgentLaunchProfile, Config};
use ycode_lsp::{
    builtin_manifests, manifest_by_id, path_to_file_uri, InstallSpec, LspManager,
    NotificationSink, ServerNotification,
};
use ycode_persist::{Db, NewLspInstallation, NewProject, NewSession, NewTodo, PersistError};
use ycode_terminal::{SpawnSpec, TerminalError, TerminalEvent, TerminalManager, TerminalSession};

use crate::{
    mcp_listener, notify_listener, AgentProfileView, ConfigView, CreateProjectRequest,
    CreateSessionRequest,
    DailyUsageView, DiscoveredSessionView, FileContents, FileEntry, GitFileChange, GitFileStatus,
    LspManifestView, ModelUsageView, OpenInExternalEditorRequest, ProjectUsageView, ProjectView,
    RenameSessionRequest, ResizePtyRequest, SearchHit, SessionUsageView, SessionView,
    SpawnPtyRequest, TodoView, TokenCountsView, UiEvent, UiEventKind, UnifiedEvent,
    WorkspaceUsageView, WriteFileRequest, WritePtyRequest,
};
use ycode_introspect::{scanner, usage};

/// Default PTY geometry. The frontend resizes after attaching to match the
/// actual xterm.js viewport.
const INITIAL_ROWS: u16 = 40;
const INITIAL_COLS: u16 = 120;

/// Size of the per-session output broadcast buffer at the IPC layer.
const UI_BUS_CAPACITY: usize = 4096;

pub struct Service {
    db: Db,
    terminals: Arc<TerminalManager>,
    config: RwLock<Config>,
    /// Set of agent ids whose `command` was found on PATH at startup. Other
    /// agents are surfaced to the UI as `available: false`.
    available_agents: RwLock<std::collections::HashSet<String>>,
    /// Per-project LSP fleet. Spawned lazily on the first `lsp_did_open`.
    lsp: Arc<LspManager>,
    /// Fan-in of all per-session terminal streams + membership events.
    /// Subscribers are typically the Tauri shell's emit task.
    ui_bus: broadcast::Sender<UiEvent>,
    /// Lifetime token for every background task this service owns (PTY
    /// event pipes, codex session-id watchers, jsonl watchers).
    /// Cancelled by [`Service::shutdown`]; spawned tasks select on
    /// `cancelled()` so they exit promptly. Per plan §8.21 / R18.
    shutdown: CancellationToken,
    /// Per-project jsonl watcher tokens. Replacing an entry cancels the
    /// previous watcher. Per plan §8.12 / §8.21.
    workspace_watchers: RwLock<std::collections::HashMap<String, CancellationToken>>,
    /// Path of the Unix domain socket the notify listener bound to. Injected
    /// into every spawned PTY's environment as `YCODE_NOTIFY_SOCK` so the
    /// `ycode-notify` helper invoked by agent hooks knows where to connect.
    /// `None` when the listener failed to start (Windows v1, or bind error)
    /// — in that case completion notifications are silently disabled.
    notify_sock_path: Option<PathBuf>,
    /// Stable path of the MCP control socket, injected into every spawned PTY
    /// as `YCODE_MCP_SOCK` so the `ycode-mcp` sidecar (launched by the agent
    /// CLI) can connect back. Computed deterministically here; the actual
    /// listener is bound later from the Tauri shell via
    /// [`mcp_listener::start`] (it needs an `Arc<Service>`). `None` on
    /// non-Unix targets.
    mcp_sock_path: Option<PathBuf>,
}

impl Service {
    pub fn new(db: Db, config: Config) -> Self {
        let available = compute_available_agents(&config);
        let (tx, _) = broadcast::channel(UI_BUS_CAPACITY);
        let shutdown = CancellationToken::new();
        // The LSP client crate doesn't depend on `ycode-ipc`, so we hand it
        // a closure that knows how to translate `ServerNotification` into a
        // `UiEvent`. Keeps the dependency edge one-way.
        let bus_for_sink = tx.clone();
        let sink: NotificationSink = Arc::new(move |server_id: &str, notif: ServerNotification| {
            match notif {
                ServerNotification::PublishDiagnostics { uri, params } => {
                    let _ = bus_for_sink.send(UiEvent::lsp_diagnostics(
                        server_id.to_string(),
                        uri,
                        params,
                    ));
                }
            }
        });
        let lsp = Arc::new(LspManager::new(db.clone(), sink));
        // Start the notify listener inside the current tokio runtime. Bind
        // failure (or non-Unix targets) returns `None` and disables
        // completion notifications without aborting startup.
        let notify_sock_path = if tokio::runtime::Handle::try_current().is_ok() {
            notify_listener::start(
                tx.clone(),
                shutdown.child_token(),
                notify_listener::default_socket_path(),
            )
        } else {
            warn!("Service::new called outside a tokio runtime; notify listener disabled");
            None
        };
        // Deterministic, stable path. Only meaningful on Unix; the listener
        // is bound separately by the Tauri shell (it needs `Arc<Service>`).
        let mcp_sock_path = if cfg!(unix) {
            Some(mcp_listener::default_socket_path())
        } else {
            None
        };
        Self {
            db,
            terminals: Arc::new(TerminalManager::new()),
            config: RwLock::new(config),
            available_agents: RwLock::new(available),
            lsp,
            ui_bus: tx,
            shutdown,
            workspace_watchers: RwLock::new(std::collections::HashMap::new()),
            notify_sock_path,
            mcp_sock_path,
        }
    }

    /// The MCP control socket path to bind/inject. The Tauri shell reads this,
    /// binds the listener via [`mcp_listener::start`], and the same value is
    /// injected into PTY children as `YCODE_MCP_SOCK`.
    pub fn mcp_sock_path(&self) -> Option<PathBuf> {
        self.mcp_sock_path.clone()
    }

    /// Subscribe to the merged UI event stream. The Tauri shell wires this
    /// receiver to `app_handle.emit("ycode://session", event)`.
    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.ui_bus.subscribe()
    }

    /// Snapshot the cancellation token shared by every spawned background
    /// task. Child tasks call `child_token()` to scope themselves further.
    pub fn shutdown_token(&self) -> CancellationToken {
        self.shutdown.clone()
    }

    /// Trigger shutdown: cancel the shared token. Background tasks (PTY
    /// event pipes, codex session-id watchers, jsonl watchers) exit on the
    /// next `select!` poll. Idempotent.
    pub fn shutdown(&self) {
        self.shutdown.cancel();
    }

    /// Async shutdown — like [`shutdown`](Self::shutdown) but also drains the
    /// LSP fleet so we send `shutdown`/`exit` to each server instead of
    /// relying solely on `kill_on_drop` when the app quits.
    pub async fn shutdown_async(&self) {
        self.shutdown.cancel();
        self.lsp.shutdown_all().await;
    }

    pub async fn list_agents(&self) -> Vec<AgentProfileView> {
        let cfg = self.config.read().await;
        let avail = self.available_agents.read().await;
        cfg.agents
            .iter()
            .map(|p| AgentProfileView::from_profile(p, avail.contains(&p.id)))
            .collect()
    }

    /// Return the current full config so the Settings UI can edit it.
    pub async fn get_config(&self) -> ConfigView {
        let cfg = self.config.read().await;
        cfg.clone().into()
    }

    /// Cheap accessor used by the Tauri event pump on every
    /// `AgentTurnComplete`. Reading the full [`ConfigView`] would clone the
    /// whole agent list — `NotificationSettings` is `Copy`, so we hand back
    /// a value and release the lock immediately.
    pub async fn notification_settings(&self) -> ycode_config::NotificationSettings {
        self.config.read().await.notifications
    }

    /// Persist `incoming` to `~/.config/ycode/config.json`, swap the live
    /// in-memory copy, recompute PATH availability, and return the refreshed
    /// agent list so the frontend can drop its old snapshot in one round-trip.
    pub async fn save_config(
        &self,
        incoming: ConfigView,
    ) -> Result<Vec<AgentProfileView>, IpcError> {
        let new_cfg: Config = incoming.into();
        new_cfg.save()?;
        let new_avail = compute_available_agents(&new_cfg);
        {
            let mut cfg = self.config.write().await;
            *cfg = new_cfg;
        }
        {
            let mut avail = self.available_agents.write().await;
            *avail = new_avail;
        }
        Ok(self.list_agents().await)
    }

    /// Overwrite the on-disk config with `Config::default()` and return the
    /// refreshed agent list. Used by the "Reset to defaults" button.
    pub async fn reset_config(&self) -> Result<Vec<AgentProfileView>, IpcError> {
        self.save_config(Config::default().into()).await
    }

    /// True iff `command` resolves on `PATH` (or is an absolute file path
    /// that exists). Powers the Settings "Test command" button.
    pub fn probe_command(&self, command: &str) -> bool {
        use std::path::PathBuf;
        if command.is_empty() {
            return false;
        }
        let p = PathBuf::from(command);
        if p.is_absolute() {
            return p.is_file();
        }
        std::env::var_os("PATH")
            .map(|paths| std::env::split_paths(&paths).any(|d| d.join(command).is_file()))
            .unwrap_or(false)
    }

    /// Start watching the on-disk jsonl directories for this project so the
    /// UI gets `JsonlChanged` events when claude/codex writes new lines. Idempotent —
    /// calling twice for the same project replaces the previous watcher.
    /// Per plan §6.2.5 / §8.12.
    pub async fn start_workspace_watch(&self, project_id: String) -> Result<(), IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let cwd = std::path::PathBuf::from(project.repo_path);
        let home = home_dir().ok_or_else(|| IpcError::BadInput("no HOME".into()))?;

        // Cancel any prior watcher for this project.
        {
            let mut map = self.workspace_watchers.write().await;
            if let Some(prev) = map.remove(&project_id) {
                prev.cancel();
            }
        }
        let cancel = self.shutdown.child_token();
        {
            let mut map = self.workspace_watchers.write().await;
            map.insert(project_id.clone(), cancel.clone());
        }

        let bus = self.ui_bus.clone();
        let project_id_for_task = project_id.clone();
        tokio::spawn(async move {
            run_jsonl_watcher(home, cwd, project_id_for_task, bus, cancel).await;
        });
        Ok(())
    }

    /// Cancel an active workspace jsonl watcher. No-op if none registered.
    pub async fn stop_workspace_watch(&self, project_id: String) -> Result<(), IpcError> {
        let mut map = self.workspace_watchers.write().await;
        if let Some(prev) = map.remove(&project_id) {
            prev.cancel();
        }
        Ok(())
    }

    /// List every session jsonl on disk (claude + codex) for a project's
    /// cwd. Sorted by mtime descending. Per plan §6.3 (`workspace.scan_known`).
    pub async fn scan_workspace_sessions(
        &self,
        project_id: String,
    ) -> Result<Vec<DiscoveredSessionView>, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let cwd = std::path::PathBuf::from(project.repo_path);
        let home = home_dir().ok_or_else(|| IpcError::BadInput("no HOME".into()))?;
        let found = tokio::task::spawn_blocking(move || scanner::scan_workspace(&home, &cwd))
            .await
            .map_err(|e| IpcError::BadInput(format!("scan task: {e}")))?;
        let mut out = Vec::with_capacity(found.len());
        for s in found {
            let (size_bytes, modified_at_ms) = stat_session(&s.jsonl_path);
            out.push(DiscoveredSessionView {
                agent: s.agent.to_string(),
                session_id: s.session_id,
                jsonl_path: s.jsonl_path.to_string_lossy().into_owned(),
                size_bytes,
                modified_at_ms,
                title: s.title,
            });
        }
        out.sort_by(|a, b| b.modified_at_ms.cmp(&a.modified_at_ms));
        Ok(out)
    }

    /// Aggregate token usage + estimated cost across every claude + codex
    /// session for a project's cwd, grouped by session / model / day. Reads
    /// the same on-disk jsonl the history viewer uses; costs are offline
    /// estimates (see `ycode_introspect::usage`).
    pub async fn get_workspace_usage(
        &self,
        project_id: String,
    ) -> Result<WorkspaceUsageView, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let cwd = std::path::PathBuf::from(project.repo_path);
        let home = home_dir().ok_or_else(|| IpcError::BadInput("no HOME".into()))?;
        let agg = tokio::task::spawn_blocking(move || usage::aggregate_workspace(&home, &cwd))
            .await
            .map_err(|e| IpcError::BadInput(format!("usage task: {e}")))?;
        Ok(to_usage_view(agg))
    }

    /// Like [`get_workspace_usage`](Self::get_workspace_usage) but spanning
    /// *every* registered project: one global rollup plus a per-project
    /// breakdown (`by_project`). Powers the Settings → Usage screen's project
    /// split.
    pub async fn get_all_usage(&self) -> Result<WorkspaceUsageView, IpcError> {
        let rows = self.db.projects().list().await?;
        let projects: Vec<(String, String, PathBuf)> = rows
            .into_iter()
            .map(|r| (r.id, r.name, PathBuf::from(r.repo_path)))
            .collect();
        let home = home_dir().ok_or_else(|| IpcError::BadInput("no HOME".into()))?;
        let agg = tokio::task::spawn_blocking(move || usage::aggregate_all_projects(&home, &projects))
            .await
            .map_err(|e| IpcError::BadInput(format!("usage task: {e}")))?;
        Ok(to_usage_view(agg))
    }

    /// Read + parse + normalise an entire jsonl into a UnifiedEvent stream.
    /// `max_events` caps memory use for huge sessions (codex rollouts can
    /// be 20+ MB per plan R6).
    pub async fn load_session_history(
        &self,
        agent: String,
        session_id: String,
        jsonl_path: String,
        max_events: usize,
    ) -> Result<Vec<UnifiedEvent>, IpcError> {
        let path = std::path::PathBuf::from(jsonl_path);
        let events = tokio::task::spawn_blocking(move || {
            scanner::read_all_events_vec(&agent, &session_id, &path, max_events.max(1))
        })
        .await
        .map_err(|e| IpcError::BadInput(format!("history task: {e}")))?
        .map_err(|e| IpcError::BadInput(format!("history: {e}")))?;
        Ok(events)
    }

    /// Substring search across every discovered jsonl for a project. v1 is a
    /// streaming substring match — Phase B4 upgrades the claude side to FTS5
    /// and the codex side to `history.jsonl` grep per plan §8.13. The IPC
    /// shape is the same so the upgrade is transparent to the UI.
    pub async fn search_sessions(
        &self,
        project_id: String,
        query: String,
        limit: usize,
    ) -> Result<Vec<SearchHit>, IpcError> {
        if query.trim().is_empty() {
            return Ok(vec![]);
        }
        let project = self.db.projects().get(&project_id).await?;
        let cwd = std::path::PathBuf::from(project.repo_path);
        let home = home_dir().ok_or_else(|| IpcError::BadInput("no HOME".into()))?;
        let q = query.to_lowercase();
        let limit = limit.max(1);
        let hits = tokio::task::spawn_blocking(move || {
            let mut hits: Vec<SearchHit> = Vec::new();
            for s in scanner::scan_workspace(&home, &cwd) {
                let sid = s.session_id.clone().unwrap_or_default();
                let agent = s.agent.to_string();
                let path_str = s.jsonl_path.to_string_lossy().into_owned();
                let _ = scanner::read_all_events(&agent, &sid, &s.jsonl_path, |ev| {
                    if hits.len() >= limit {
                        return;
                    }
                    let preview = ev.preview();
                    if preview.to_lowercase().contains(&q) {
                        hits.push(SearchHit {
                            agent: agent.clone(),
                            session_id: sid.clone(),
                            jsonl_path: path_str.clone(),
                            seq: ev.seq,
                            ts_ms: ev.ts_ms,
                            preview: truncate_preview(&preview),
                        });
                    }
                });
                if hits.len() >= limit {
                    break;
                }
            }
            hits.sort_by(|a, b| b.ts_ms.cmp(&a.ts_ms));
            hits
        })
        .await
        .map_err(|e| IpcError::BadInput(format!("search task: {e}")))?;
        Ok(hits)
    }

    pub async fn list_projects(&self) -> Result<Vec<ProjectView>, IpcError> {
        let rows = self.db.projects().list().await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let count = self.db.projects().live_session_count(&row.id).await?;
            out.push(ProjectView::from_row(row, count));
        }
        Ok(out)
    }

    pub async fn create_project(&self, req: CreateProjectRequest) -> Result<ProjectView, IpcError> {
        let repo = Utf8Path::new(&req.repo_path);
        if !repo.as_std_path().is_dir() {
            return Err(IpcError::InvalidRepoPath(req.repo_path));
        }
        let id = ulid::Ulid::new().to_string();
        let row = self
            .db
            .projects()
            .insert(NewProject {
                id,
                name: req.name,
                repo_path: repo.to_string(),
            })
            .await?;
        let view = ProjectView::from_row(row, 0);
        let _ = self.ui_bus.send(UiEvent {
            session_id: view.id.clone(),
            kind: UiEventKind::ProjectAppeared,
        });
        Ok(view)
    }

    pub async fn delete_project(&self, project_id: String) -> Result<(), IpcError> {
        // Auto-archive any live sessions in this project so the persist-layer
        // guard passes and orphan PTY children don't keep running after the
        // project row is gone. Mirrors what the user would do by clicking
        // "archive" on each session manually.
        let live = self.db.sessions().list_for_project(&project_id).await?;
        for row in live {
            // list_for_project already filters out archived rows.
            if let Some(s) = self.terminals.remove(&row.id).await {
                let _ = s.kill().await;
            }
            if let Err(e) = self.db.sessions().archive(&row.id).await {
                warn!(session_id = %row.id, error = %e, "auto-archive on project delete failed");
            }
            let _ = self.ui_bus.send(UiEvent {
                session_id: row.id,
                kind: UiEventKind::SessionRemoved,
            });
        }

        // Stop the per-project jsonl watcher so the cancelled token frees
        // its notify handle promptly.
        {
            let mut map = self.workspace_watchers.write().await;
            if let Some(token) = map.remove(&project_id) {
                token.cancel();
            }
        }

        self.db.projects().delete(&project_id).await?;
        let _ = self.ui_bus.send(UiEvent {
            session_id: project_id,
            kind: UiEventKind::ProjectRemoved,
        });
        Ok(())
    }

    // ───────────────────────────── Todos ─────────────────────────────

    pub async fn list_todos(&self, project_id: String) -> Result<Vec<TodoView>, IpcError> {
        let rows = self.db.todos().list_for_project(&project_id).await?;
        Ok(rows.into_iter().map(TodoView::from_row).collect())
    }

    pub async fn create_todo(
        &self,
        project_id: String,
        title: String,
    ) -> Result<TodoView, IpcError> {
        let title = title.trim().to_string();
        if title.is_empty() {
            return Err(IpcError::BadInput("todo title must not be empty".into()));
        }
        // Validate the project exists so MCP callers get a clean error rather
        // than a dangling FK insert failure.
        self.db.projects().get(&project_id).await?;
        let id = ulid::Ulid::new().to_string();
        let row = self
            .db
            .todos()
            .insert(NewTodo {
                id,
                project_id: project_id.clone(),
                title,
            })
            .await?;
        self.emit_todos_changed(&project_id);
        Ok(TodoView::from_row(row))
    }

    pub async fn update_todo(
        &self,
        id: String,
        title: Option<String>,
        status: Option<String>,
    ) -> Result<TodoView, IpcError> {
        let title = title.map(|t| t.trim().to_string());
        if let Some(t) = &title {
            if t.is_empty() {
                return Err(IpcError::BadInput("todo title must not be empty".into()));
            }
        }
        let row = self
            .db
            .todos()
            .update(&id, title.as_deref(), status.as_deref())
            .await?;
        self.emit_todos_changed(&row.project_id);
        Ok(TodoView::from_row(row))
    }

    pub async fn delete_todo(&self, id: String) -> Result<(), IpcError> {
        // Read first so we know which project to signal after the delete.
        let row = self.db.todos().get(&id).await?;
        self.db.todos().delete(&id).await?;
        self.emit_todos_changed(&row.project_id);
        Ok(())
    }

    fn emit_todos_changed(&self, project_id: &str) {
        let _ = self.ui_bus.send(UiEvent {
            session_id: project_id.to_string(),
            kind: UiEventKind::TodosChanged,
        });
    }

    /// Resolve a project id from a terminal id (the `YCODE_TERMINAL_ID` we
    /// inject when spawning a PTY). Used by the MCP control socket so AI tool
    /// calls operate on the project the agent is running inside, with no
    /// explicit project argument.
    pub async fn project_id_for_terminal(&self, terminal_id: &str) -> Result<String, IpcError> {
        Ok(self.db.sessions().get(terminal_id).await?.project_id)
    }

    /// Fallback resolution by working directory: match `cwd` against known
    /// project `repo_path`s. Used when `YCODE_TERMINAL_ID` didn't propagate to
    /// the MCP server child process. Returns the project whose repo_path is a
    /// prefix of (or equal to) `cwd`, preferring the longest match.
    pub async fn project_id_for_cwd(&self, cwd: &str) -> Result<String, IpcError> {
        let rows = self.db.projects().list().await?;
        let best = rows
            .into_iter()
            .filter(|p| cwd == p.repo_path || cwd.starts_with(&format!("{}/", p.repo_path)))
            .max_by_key(|p| p.repo_path.len());
        best.map(|p| p.id)
            .ok_or_else(|| IpcError::BadInput(format!("no project matches cwd {cwd}")))
    }

    /// Walk a project's repo, honouring `.gitignore` and friends. Returns
    /// every directory and file entry (relative to repo root) so the frontend
    /// can render an expandable tree. The walk runs on a blocking thread to
    /// keep large repos from stalling the async runtime.
    pub async fn list_files(&self, project_id: String) -> Result<Vec<FileEntry>, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let root = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || walk_repo(&root))
            .await
            .map_err(|e| IpcError::BadInput(format!("walk task: {e}")))?
    }

    /// Read a file's UTF-8 contents. `file_path` is relative to the project
    /// repo root; path traversal escaping the repo is rejected. Binary files
    /// (NUL byte in the first 8 KiB) return `is_binary = true` and an empty
    /// `contents` string so the editor can refuse to render them.
    pub async fn read_file(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<FileContents, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || read_repo_file(&repo, file_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("read task: {e}")))?
    }

    /// Read a project file and return it as a base64 `data:` URL so the editor
    /// can render images/SVGs inline. Path traversal escaping the repo is
    /// rejected — same enforcement as `read_file`.
    pub async fn read_file_data_url(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<String, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || read_repo_file_data_url(&repo, file_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("read task: {e}")))?
    }

    /// Overwrite a project file's contents. Path traversal escaping the repo
    /// is rejected. Parent directories must already exist.
    pub async fn write_file(&self, req: WriteFileRequest) -> Result<(), IpcError> {
        let project = self.db.projects().get(&req.project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || write_repo_file(&repo, req.file_path, req.contents))
            .await
            .map_err(|e| IpcError::BadInput(format!("write task: {e}")))?
    }

    /// Delete a file or directory inside the repo. Directories are removed
    /// recursively. Path traversal escaping the repo is rejected.
    pub async fn delete_path(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<(), IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || delete_repo_path(&repo, file_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("delete task: {e}")))?
    }

    /// Rename / move a file or directory within the repo. Both endpoints must
    /// stay inside the repo. The destination must not already exist.
    pub async fn rename_path(
        &self,
        project_id: String,
        from_path: String,
        to_path: String,
    ) -> Result<(), IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || rename_repo_path(&repo, from_path, to_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("rename task: {e}")))?
    }

    /// Create a new empty file (`is_dir = false`) or directory (`is_dir = true`)
    /// inside the repo. Parent directories are created on demand. Fails if the
    /// target already exists.
    pub async fn create_path(
        &self,
        project_id: String,
        file_path: String,
        is_dir: bool,
    ) -> Result<(), IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || create_repo_path(&repo, file_path, is_dir))
            .await
            .map_err(|e| IpcError::BadInput(format!("create task: {e}")))?
    }

    /// List unstaged working-tree changes (modified, deleted, untracked).
    /// Staged-only changes are filtered out — the "Changes" panel reflects
    /// what you'd see in `git diff` without `--cached`.
    pub async fn git_status(&self, project_id: String) -> Result<Vec<GitFileChange>, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || git_status_blocking(&repo))
            .await
            .map_err(|e| IpcError::BadInput(format!("git_status task: {e}")))?
    }

    /// Unified-diff text for one file vs its index entry (unstaged). For
    /// untracked files the entire file content is returned as additions.
    /// Empty string if there's nothing to diff.
    pub async fn git_diff_file(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<String, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || git_diff_file_blocking(&repo, file_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("git_diff task: {e}")))?
    }

    /// Hand a file off to the user's preferred GUI editor. Resolution order:
    /// explicit `editor` arg → `$VISUAL` → `$EDITOR` → platform default
    /// (`Visual Studio Code` on macOS). On macOS we spawn `open -a <editor>
    /// <path>`; on other platforms we exec the editor binary directly. Per
    /// plan §8.15.
    pub async fn open_in_external_editor(
        &self,
        req: OpenInExternalEditorRequest,
    ) -> Result<(), IpcError> {
        tokio::task::spawn_blocking(move || open_in_external_editor_blocking(req))
            .await
            .map_err(|e| IpcError::BadInput(format!("open-in-editor task: {e}")))?
    }

    /// Reveal a file in the system file manager (Finder on macOS).
    pub async fn reveal_in_finder(&self, path: String) -> Result<(), IpcError> {
        tokio::task::spawn_blocking(move || reveal_in_finder_blocking(path))
            .await
            .map_err(|e| IpcError::BadInput(format!("reveal task: {e}")))?
    }

    /// Open a URL in the user's default browser. Used by xterm.js
    /// `WebLinksAddon`, whose default `window.open` is a no-op inside
    /// Tauri's WKWebView.
    pub async fn open_url(&self, url: String) -> Result<(), IpcError> {
        tokio::task::spawn_blocking(move || open_url_blocking(url))
            .await
            .map_err(|e| IpcError::BadInput(format!("open-url task: {e}")))?
    }

    /// Resolve a candidate path scraped from terminal output to a
    /// project-relative path. Used by the file-link provider in xterm panes
    /// so a Cmd-click on something that looks like `src/foo.ts` or
    /// `/abs/path` opens the file in the right-pane editor.
    ///
    /// Returns `Ok(None)` when the candidate isn't a regular file inside the
    /// project; the frontend treats that as "no-op". Reserving `Err` for true
    /// errors (bad project id) keeps the link provider quiet on false-positive
    /// matches.
    pub async fn resolve_terminal_path(
        &self,
        project_id: String,
        candidate: String,
    ) -> Result<Option<String>, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || resolve_terminal_path_blocking(&repo, &candidate))
            .await
            .map_err(|e| IpcError::BadInput(format!("resolve-path task: {e}")))?
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionView>, IpcError> {
        let rows = self.db.sessions().list_live().await?;
        let mut out = Vec::with_capacity(rows.len());
        for row in rows {
            let is_live = self.terminals.get(&row.id).await.is_some();
            out.push(SessionView::from_row(row, is_live));
        }
        Ok(out)
    }

    pub async fn create_session(&self, req: CreateSessionRequest) -> Result<SessionView, IpcError> {
        let profile: AgentLaunchProfile = self
            .config
            .read()
            .await
            .find(&req.agent_profile_id)
            .cloned()
            .ok_or_else(|| IpcError::UnknownAgentProfile(req.agent_profile_id.clone()))?;

        let project = self.db.projects().get(&req.project_id).await?;
        let cwd = Utf8PathBuf::from(project.repo_path);

        let id = ulid::Ulid::new().to_string();
        // Resume mode: caller (e.g. sidebar History click) already knows the
        // agent-native session id on disk. Persist it on the row so launch_args
        // picks it up, and switch the CLI launch mode so claude/codex get
        // `--resume <id>` / `resume <id>` instead of a fresh `--session-id`.
        let (agent_session_id, launch_mode) = match req.resume.as_deref() {
            Some(rid) if !rid.trim().is_empty() => (Some(rid.to_string()), LaunchMode::Resume),
            _ => (initial_agent_session_id(&profile), LaunchMode::Create),
        };
        let row = self
            .db
            .sessions()
            .insert(NewSession {
                id: id.clone(),
                title: req.title,
                agent_profile: profile.id.clone(),
                agent_session_id,
                agent_thread_name: None,
                project_id: project.id,
            })
            .await?;

        let started_at = std::time::SystemTime::now();
        let session = self
            .spawn_pty(&id, &profile, &row, cwd.clone(), launch_mode)
            .await
            .map_err(|e| {
                // Roll back the row so a failed spawn doesn't leave a phantom session.
                let db = self.db.clone();
                let id_clone = id.clone();
                tokio::spawn(async move {
                    if let Err(e) = db.sessions().archive(&id_clone).await {
                        warn!(session_id = %id_clone, error = %e, "rollback archive failed");
                    }
                });
                e
            })?;

        self.pipe_terminal_events(session);
        // Resume mode already knows the agent session id, so we skip the
        // watcher that backfills it for fresh codex/gemini sessions.
        if matches!(launch_mode, LaunchMode::Create) {
            if is_codex_profile(&profile) {
                watch_codex_session_id(self.db.clone(), id.clone(), cwd, started_at);
            } else if is_gemini_profile(&profile) {
                watch_gemini_session_id(self.db.clone(), id.clone(), cwd, started_at);
            }
        }

        let view = SessionView::from_row(row, true);
        let _ = self.ui_bus.send(UiEvent {
            session_id: id,
            kind: UiEventKind::SessionAppeared,
        });
        Ok(view)
    }

    /// Spawn a raw PTY (no project/session row). The returned id can be used
    /// with `write_pty` / `resize_pty` / `kill_pty_raw`. PTY output and exit
    /// events arrive on the same UI bus channel as session events; routing
    /// is by id on the frontend.
    pub async fn spawn_pty_raw(&self, req: SpawnPtyRequest) -> Result<String, IpcError> {
        let cwd = Utf8PathBuf::from(&req.cwd);
        if !cwd.as_std_path().is_dir() {
            return Err(IpcError::BadInput(format!(
                "cwd not a directory: {}",
                req.cwd
            )));
        }
        let id = format!("manual-{}", ulid::Ulid::new());
        // Empty `command` ⇒ user's login shell. Frontend uses this for the
        // second-terminal panel which doesn't know the host's $SHELL.
        let command = if req.command.is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
        } else {
            req.command
        };
        let mut env = terminal_env(std::env::vars());
        inject_notify_env(
            &mut env,
            &id,
            self.notify_sock_path.as_deref(),
            self.mcp_sock_path.as_deref(),
        );
        let spec = SpawnSpec {
            command,
            args: req.args,
            // Inherit the host environment so the shell gets PATH/HOME/etc.
            env,
            // Raw PTYs are user-driven shells: don't strip API_KEY vars —
            // the user may explicitly need them. Plan §8.16.
            env_remove: vec![],
            cwd,
            // Use the caller's fitted geometry when provided so the shell
            // reads the real terminal width via TIOCGWINSZ at startup. The
            // hardcoded fallbacks only kick in for older clients / tests.
            rows: req.rows.unwrap_or(INITIAL_ROWS),
            cols: req.cols.unwrap_or(INITIAL_COLS),
        };
        let session = self.terminals.spawn(id.clone(), spec).await?;
        self.pipe_raw_terminal_events(session);
        info!(pty_id = %id, "raw PTY spawned");
        Ok(id)
    }

    /// Kill a raw PTY spawned via `spawn_pty_raw`. Unlike `kill_session` this
    /// doesn't try to touch the DB — raw PTYs have no row.
    pub async fn kill_pty_raw(&self, pty_id: String) -> Result<(), IpcError> {
        if let Some(s) = self.terminals.remove(&pty_id).await {
            let _ = s.kill().await;
        }
        Ok(())
    }

    pub async fn write_pty(&self, req: WritePtyRequest) -> Result<(), IpcError> {
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(&req.data)
            .map_err(|e| IpcError::BadInput(format!("base64: {e}")))?;
        let session = self
            .terminals
            .get(&req.session_id)
            .await
            .ok_or_else(|| IpcError::SessionNotLive(req.session_id.clone()))?;
        session.write(&bytes).await?;
        Ok(())
    }

    /// Return the captured PTY scrollback for `session_id` as a base64
    /// string. Empty when the session has produced nothing yet. Used by a
    /// freshly opened webview (e.g. a detached project window) to seed its
    /// xterm.js renderer with the existing terminal state before
    /// subscribing to the live event stream. Caps at the backlog limit set
    /// inside `ycode-terminal`.
    pub async fn read_pty_backlog(&self, session_id: String) -> Result<String, IpcError> {
        use base64::Engine;
        let session = self
            .terminals
            .get(&session_id)
            .await
            .ok_or_else(|| IpcError::SessionNotLive(session_id))?;
        let bytes = session.backlog_snapshot();
        Ok(base64::engine::general_purpose::STANDARD.encode(&bytes))
    }

    pub async fn resize_pty(&self, req: ResizePtyRequest) -> Result<(), IpcError> {
        let session = self
            .terminals
            .get(&req.session_id)
            .await
            .ok_or_else(|| IpcError::SessionNotLive(req.session_id.clone()))?;
        session.resize(req.cols, req.rows).await?;
        Ok(())
    }

    pub async fn kill_session(&self, session_id: String) -> Result<(), IpcError> {
        let session = self
            .terminals
            .get(&session_id)
            .await
            .ok_or_else(|| IpcError::SessionNotLive(session_id))?;
        session.kill().await?;
        Ok(())
    }

    pub async fn archive_session(&self, session_id: String) -> Result<(), IpcError> {
        // Kill the live PTY first so the waiter doesn't race the archive
        // update. If there's no live session, that's fine — the row exists
        // and we just flip the archive flag.
        if let Some(s) = self.terminals.remove(&session_id).await {
            let _ = s.kill().await;
        }
        let row = self.db.sessions().get(&session_id).await?;
        if row.archived_at.is_none() {
            self.db.sessions().archive(&session_id).await?;
        }
        let _ = self.ui_bus.send(UiEvent {
            session_id,
            kind: UiEventKind::SessionRemoved,
        });
        Ok(())
    }

    /// Persist a new title for a session. Empty titles are allowed — the UI
    /// falls back to the live CLI title (or "New session") for display.
    pub async fn rename_session(&self, req: RenameSessionRequest) -> Result<SessionView, IpcError> {
        self.db
            .sessions()
            .update_title(&req.session_id, &req.title)
            .await?;
        let row = self.db.sessions().get(&req.session_id).await?;
        let is_live = self.terminals.get(&req.session_id).await.is_some();
        let view = SessionView::from_row(row, is_live);
        let _ = self.ui_bus.send(UiEvent {
            session_id: req.session_id,
            kind: UiEventKind::SessionTouched,
        });
        Ok(view)
    }

    pub async fn restart_session(&self, session_id: String) -> Result<SessionView, IpcError> {
        let row = self.db.sessions().get(&session_id).await?;
        if row.archived_at.is_some() {
            return Err(IpcError::Archived(session_id));
        }

        let profile: AgentLaunchProfile = self
            .config
            .read()
            .await
            .find(&row.agent_profile)
            .cloned()
            .ok_or_else(|| IpcError::UnknownAgentProfile(row.agent_profile.clone()))?;
        let project = self.db.projects().get(&row.project_id).await?;
        let cwd = Utf8PathBuf::from(project.repo_path);

        // Drop the old PTY if any.
        if let Some(s) = self.terminals.remove(&session_id).await {
            let _ = s.kill().await;
        }

        // Clear the recorded exit code — we're alive again.
        self.db.sessions().set_exit_code(&session_id, None).await?;

        let session = self
            .spawn_pty(&session_id, &profile, &row, cwd, LaunchMode::Resume)
            .await?;
        self.pipe_terminal_events(session);

        let row = self.db.sessions().get(&session_id).await?;
        let view = SessionView::from_row(row, true);
        let _ = self.ui_bus.send(UiEvent {
            session_id,
            kind: UiEventKind::SessionTouched,
        });
        Ok(view)
    }

    // ── Language server lifecycle (PR1: install / uninstall) ───────────────

    /// Snapshot of every built-in manifest merged with the user's local install
    /// state. The Settings → Languages page renders one card per entry.
    pub async fn lsp_list_manifests(&self) -> Result<Vec<LspManifestView>, IpcError> {
        let installed = self.db.lsp_installations().list().await?;
        let installed_by_id: std::collections::HashMap<String, _> =
            installed.into_iter().map(|row| (row.id.clone(), row)).collect();

        let mut out = Vec::new();
        for manifest in builtin_manifests() {
            let platform_supported = match &manifest.install {
                InstallSpec::GithubReleaseGzip { assets, .. } => {
                    assets.for_current_platform().is_some()
                }
                // npm-based installers are portable across all platforms we
                // build for — the requirement check (`npm` on PATH) is what
                // gates them, not the platform itself.
                InstallSpec::Npm { .. } => true,
            };
            let requirement_message = lsp_requirement_message(&manifest.install);
            let installation = installed_by_id.get(&manifest.id).cloned().map(Into::into);
            out.push(LspManifestView {
                manifest,
                installation,
                platform_supported,
                requirement_message,
            });
        }
        Ok(out)
    }

    /// Start an install in the background. Returns as soon as the task is
    /// spawned; progress + completion arrive on the UI bus as
    /// `LspInstallProgress` / `LspInstallFinished` events.
    pub async fn lsp_install(&self, server_id: String) -> Result<(), IpcError> {
        let manifest = manifest_by_id(&server_id)
            .ok_or_else(|| ycode_lsp::LspError::UnknownServer(server_id.clone()))?;

        let bus = self.ui_bus.clone();
        let db = self.db.clone();
        let cancel = self.shutdown.clone();
        tokio::spawn(async move {
            let (tx, mut rx) = tokio::sync::mpsc::channel::<ycode_lsp::InstallProgress>(32);

            // Pump per-step progress onto the UI bus until the installer drops
            // its sender.
            let bus_for_pump = bus.clone();
            let pump = tokio::spawn(async move {
                while let Some(progress) = rx.recv().await {
                    let _ = bus_for_pump.send(UiEvent::lsp_install_progress(progress));
                }
            });

            let outcome = tokio::select! {
                _ = cancel.cancelled() => Err(ycode_lsp::LspError::InstallCommand(
                    "install".into(),
                    "cancelled".into(),
                )),
                result = ycode_lsp::install(&manifest, tx) => result,
            };

            // Drop the sender's other half via task join so the pump exits.
            let _ = pump.await;

            match outcome {
                Ok(record) => {
                    if let Err(e) = db
                        .lsp_installations()
                        .upsert(NewLspInstallation {
                            id: record.server_id.clone(),
                            version: record.version.clone(),
                            binary_path: record.binary_path,
                        })
                        .await
                    {
                        warn!(server_id = %record.server_id, error = %e, "persist lsp install failed");
                        let _ = bus.send(UiEvent::lsp_install_failed(
                            record.server_id,
                            format!("persist: {e}"),
                        ));
                        return;
                    }
                    let _ = bus.send(UiEvent::lsp_install_finished(
                        record.server_id,
                        record.version,
                    ));
                }
                Err(e) => {
                    warn!(server_id = %server_id, error = %e, "lsp install failed");
                    let _ = bus.send(UiEvent::lsp_install_failed(server_id, e.to_string()));
                }
            }
        });
        Ok(())
    }

    /// Remove the install directory and forget the DB row. Idempotent.
    pub async fn lsp_uninstall(&self, server_id: String) -> Result<(), IpcError> {
        if manifest_by_id(&server_id).is_none() {
            return Err(ycode_lsp::LspError::UnknownServer(server_id).into());
        }
        ycode_lsp::uninstall(&server_id).await?;
        self.db.lsp_installations().delete(&server_id).await?;
        let _ = self.ui_bus.send(UiEvent::lsp_uninstalled(server_id));
        Ok(())
    }

    // ── Language server document sync + queries (PR2) ──────────────────────

    /// Open a document with the appropriate language server. Returns `true`
    /// iff a server is actually handling the file (manifest matched + server
    /// installed). Errors only on hard failures — "no manifest" / "not
    /// installed" are silent `Ok(false)` so the editor can call this on
    /// every open without sprinkling try/catch.
    pub async fn lsp_did_open(
        &self,
        project_id: String,
        file_path: String,
        content: String,
        version: i64,
    ) -> Result<bool, IpcError> {
        let Some((session, uri, language_id)) = self
            .lsp_session_for(&project_id, &file_path)
            .await?
        else {
            return Ok(false);
        };
        session
            .did_open(&uri, &language_id, version, &content)
            .await?;
        Ok(true)
    }

    pub async fn lsp_did_change(
        &self,
        project_id: String,
        file_path: String,
        version: i64,
        content: String,
    ) -> Result<bool, IpcError> {
        // Don't spawn on `didChange` — if the editor never sent `didOpen`,
        // there's nothing to update. Look up by file routing instead.
        let Some(manifest) = LspManager::manifest_for_file(&file_path) else {
            return Ok(false);
        };
        let Some(session) = self.lsp.get(&project_id, &manifest.id).await else {
            return Ok(false);
        };
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        let abs = repo.as_std_path().join(&file_path);
        let uri = path_to_file_uri(&abs);
        session.did_change_full(&uri, version, &content).await?;
        Ok(true)
    }

    pub async fn lsp_did_close(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<(), IpcError> {
        let Some(manifest) = LspManager::manifest_for_file(&file_path) else {
            return Ok(());
        };
        let Some(session) = self.lsp.get(&project_id, &manifest.id).await else {
            return Ok(());
        };
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        let abs = repo.as_std_path().join(&file_path);
        let uri = path_to_file_uri(&abs);
        session.did_close(&uri).await?;
        Ok(())
    }

    /// `textDocument/definition`. Returns the raw LSP payload — either a
    /// `Location`, `Location[]`, or `LocationLink[]`. The frontend already
    /// understands all three so we forward instead of normalising.
    pub async fn lsp_definition(
        &self,
        project_id: String,
        file_path: String,
        line: u32,
        character: u32,
    ) -> Result<serde_json::Value, IpcError> {
        let Some((session, uri, _)) = self.lsp_session_for(&project_id, &file_path).await? else {
            return Ok(serde_json::Value::Null);
        };
        Ok(session.definition(&uri, line, character).await?)
    }

    /// `textDocument/semanticTokens/full`. Forwarded raw — the frontend maps
    /// the pinned token type legend (`ycode_lsp::TOKEN_TYPES`) to CSS classes.
    pub async fn lsp_semantic_tokens_full(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<serde_json::Value, IpcError> {
        let Some((session, uri, _)) = self.lsp_session_for(&project_id, &file_path).await? else {
            return Ok(serde_json::Value::Null);
        };
        Ok(session.semantic_tokens_full(&uri).await?)
    }

    /// Helper: spawn-or-return the session that should drive `file_path`.
    /// `Ok(None)` means "no LSP for this file" — either extension isn't
    /// covered by any manifest, or the matching server isn't installed.
    async fn lsp_session_for(
        &self,
        project_id: &str,
        file_path: &str,
    ) -> Result<Option<(Arc<ycode_lsp::LspSession>, String, String)>, IpcError> {
        let Some(manifest) = LspManager::manifest_for_file(file_path) else {
            return Ok(None);
        };
        let project = self.db.projects().get(project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        let abs = repo.as_std_path().join(file_path);
        let uri = path_to_file_uri(&abs);
        let language_id = LspManager::language_id_for(&manifest, file_path).to_string();
        match self
            .lsp
            .get_or_spawn(project_id, repo.as_std_path(), manifest)
            .await
        {
            Ok(session) => Ok(Some((session, uri, language_id))),
            // Not installed → silent skip. Caller treats as "no LSP for this
            // file" and the editor keeps working without LSP features.
            Err(ycode_lsp::LspError::UnknownServer(_)) => Ok(None),
            Err(e) => Err(e.into()),
        }
    }

    async fn spawn_pty(
        &self,
        id: &str,
        profile: &AgentLaunchProfile,
        row: &ycode_persist::SessionRow,
        cwd: Utf8PathBuf,
        mode: LaunchMode,
    ) -> Result<Arc<TerminalSession>, IpcError> {
        let mut env = terminal_env(
            std::env::vars().chain(profile.env.iter().map(|(k, v)| (k.clone(), v.clone()))),
        );
        inject_notify_env(
            &mut env,
            id,
            self.notify_sock_path.as_deref(),
            self.mcp_sock_path.as_deref(),
        );
        let env_remove = env_keys_to_strip(profile)
            .iter()
            .map(|s| (*s).to_string())
            .collect();
        // Wrap the agent invocation in the user's interactive login shell so
        // `~/.zshrc` (etc.) is sourced before the agent — version managers
        // like fnm/nvm/asdf inject themselves there, and without this layer
        // the agent (and any subprocesses it spawns, e.g. Claude Code's bash
        // tool) only sees the GUI-launched PATH and can't find the user's
        // chosen node/python/etc. The right-side ManualTerminal already gets
        // this for free because it spawns $SHELL directly.
        let (command, args) =
            wrap_in_login_shell(profile.command.clone(), launch_args(profile, row, mode));
        let spec = SpawnSpec {
            command,
            args,
            env,
            env_remove,
            cwd,
            rows: INITIAL_ROWS,
            cols: INITIAL_COLS,
        };
        let session = self.terminals.spawn(id.to_string(), spec).await?;
        info!(session_id = %id, profile = %profile.id, "PTY spawned");
        Ok(session)
    }

    /// Like `pipe_terminal_events` but for raw PTYs that have no DB row.
    /// Emits PtyOutput/PtyExit only — no SessionTouched, no exit-code persist.
    fn pipe_raw_terminal_events(&self, session: Arc<TerminalSession>) {
        let bus = self.ui_bus.clone();
        let terminals = self.terminals.clone();
        let id = session.id().to_string();
        let mut rx = session.subscribe();
        let _session_keepalive = session;
        let cancel = self.shutdown.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => break,
                    ev = rx.recv() => match ev {
                        Ok(TerminalEvent::Output(bytes)) => {
                            let _ = bus.send(UiEvent::pty_output(&id, &bytes));
                        }
                        Ok(TerminalEvent::TitleChanged(_)) => {
                            // Raw PTYs aren't backed by a session row; the UI has
                            // no surface for a title here, so drop it.
                        }
                        Ok(TerminalEvent::Exited { code }) => {
                            let _ = terminals.remove(&id).await;
                            let _ = bus.send(UiEvent::pty_exit(&id, code));
                            break;
                        }
                        Ok(TerminalEvent::Error(msg)) => {
                            warn!(pty_id = %id, error = %msg, "raw terminal error");
                            let _ = terminals.remove(&id).await;
                            let _ = bus.send(UiEvent::pty_exit(&id, None));
                            break;
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            warn!(pty_id = %id, lagged = n, "raw terminal subscriber lagged");
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
            drop(_session_keepalive);
        });
    }

    /// Subscribe to a terminal session's event stream and forward each
    /// event into the merged UI bus. Spawned once per session — typically
    /// inside `create_session` / `restart_session`.
    fn pipe_terminal_events(&self, session: Arc<TerminalSession>) {
        let bus = self.ui_bus.clone();
        let db = self.db.clone();
        let terminals = self.terminals.clone();
        let id = session.id().to_string();
        let mut rx = session.subscribe();
        // Hold the session strongly for the lifetime of the pipe so the
        // PTY isn't dropped just because the manager evicted it.
        let _session_keepalive = session;
        let cancel = self.shutdown.clone();
        tokio::spawn(async move {
            loop {
                tokio::select! {
                    biased;
                    _ = cancel.cancelled() => break,
                    ev = rx.recv() => match ev {
                        Ok(TerminalEvent::Output(bytes)) => {
                            let _ = bus.send(UiEvent::pty_output(&id, &bytes));
                        }
                        Ok(TerminalEvent::TitleChanged(title)) => {
                            if let Err(e) = db.sessions().update_agent_thread_name(&id, &title).await {
                                warn!(session_id = %id, error = %e, "update agent thread name failed");
                            }
                            let _ = bus.send(UiEvent::title_changed(&id, title));
                        }
                        Ok(TerminalEvent::Exited { code }) => {
                            if let Err(e) = db.sessions().set_exit_code(&id, code).await {
                                warn!(session_id = %id, error = %e, "set_exit_code failed");
                            }
                            // Drop the entry from the live registry now that the
                            // child is gone. If `archive_session` already removed
                            // it, this is a no-op.
                            let _ = terminals.remove(&id).await;
                            let _ = bus.send(UiEvent::pty_exit(&id, code));
                            let _ = bus.send(UiEvent {
                                session_id: id.clone(),
                                kind: UiEventKind::SessionTouched,
                            });
                            break;
                        }
                        Ok(TerminalEvent::Error(msg)) => {
                            warn!(session_id = %id, error = %msg, "terminal error");
                            let _ = bus.send(UiEvent::pty_exit(&id, None));
                            let _ = terminals.remove(&id).await;
                            let _ = bus.send(UiEvent {
                                session_id: id.clone(),
                                kind: UiEventKind::SessionTouched,
                            });
                            break;
                        }
                        Err(broadcast::error::RecvError::Lagged(n)) => {
                            warn!(session_id = %id, lagged = n, "terminal subscriber lagged");
                        }
                        Err(broadcast::error::RecvError::Closed) => break,
                    }
                }
            }
            drop(_session_keepalive);
        });
    }
}

#[derive(Clone, Copy)]
enum LaunchMode {
    Create,
    Resume,
}

fn initial_agent_session_id(profile: &AgentLaunchProfile) -> Option<String> {
    if is_claude_profile(profile) {
        Some(uuid::Uuid::new_v4().to_string())
    } else {
        None
    }
}

fn launch_args(
    profile: &AgentLaunchProfile,
    row: &ycode_persist::SessionRow,
    mode: LaunchMode,
) -> Vec<String> {
    let mut args = profile.args.clone();
    if is_claude_profile(profile) {
        if let Some(id) = row.agent_session_id.as_deref() {
            match mode {
                LaunchMode::Create => {
                    args.push("--session-id".into());
                    args.push(id.into());
                }
                LaunchMode::Resume => {
                    args.push("--resume".into());
                    args.push(id.into());
                }
            }
        }
    } else if is_codex_profile(profile) && matches!(mode, LaunchMode::Resume) {
        if let Some(id) = row.agent_session_id.as_deref() {
            args.push("resume".into());
            args.push(id.into());
        } else if let Some(thread) = row.agent_thread_name.as_deref() {
            if !thread.trim().is_empty() {
                args.push("resume".into());
                args.push(thread.to_string());
            }
        }
    } else if is_gemini_profile(profile) && matches!(mode, LaunchMode::Resume) {
        if let Some(id) = row.agent_session_id.as_deref() {
            args.push("--resume".into());
            args.push(id.into());
        }
    }
    args
}

fn is_claude_profile(profile: &AgentLaunchProfile) -> bool {
    profile.id == "claude-code" || command_basename(&profile.command) == "claude"
}

/// Environment variables to remove from the child's environment when spawning
/// an agent CLI. The defaults catch the API_KEY variables that would hijack
/// each provider's OAuth subscription path (plan §8.2 / R4) — the highest
/// likelihood × impact risk in the plan.
fn env_keys_to_strip(profile: &AgentLaunchProfile) -> &'static [&'static str] {
    if is_claude_profile(profile) {
        &["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
    } else if is_codex_profile(profile) {
        &["OPENAI_API_KEY"]
    } else if is_gemini_profile(profile) {
        &["GEMINI_API_KEY", "GOOGLE_API_KEY"]
    } else {
        &[]
    }
}

fn is_codex_profile(profile: &AgentLaunchProfile) -> bool {
    profile.id == "codex" || command_basename(&profile.command) == "codex"
}

fn is_gemini_profile(profile: &AgentLaunchProfile) -> bool {
    profile.id == "gemini-cli" || command_basename(&profile.command) == "gemini"
}

fn command_basename(command: &str) -> &str {
    command.rsplit(['/', '\\']).next().unwrap_or(command)
}

/// Wrap an agent invocation in the user's `$SHELL -l -i -c "exec …"` on Unix
/// so rc files get sourced before the agent starts. `exec` replaces the
/// shell so signals / process tree behave as if the agent were spawned
/// directly. Falls back to `/bin/sh` if `$SHELL` is unset. On Windows we
/// spawn the agent directly — there's no analogous rc-sourcing layer.
#[cfg(unix)]
fn wrap_in_login_shell(command: String, args: Vec<String>) -> (String, Vec<String>) {
    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string());
    let mut script = String::from("exec ");
    script.push_str(&posix_shell_quote(&command));
    for arg in &args {
        script.push(' ');
        script.push_str(&posix_shell_quote(arg));
    }
    (shell, vec!["-l".into(), "-i".into(), "-c".into(), script])
}

#[cfg(windows)]
fn wrap_in_login_shell(command: String, args: Vec<String>) -> (String, Vec<String>) {
    (command, args)
}

/// POSIX single-quote escape: wrap in `'…'` and turn each embedded `'` into
/// `'\''`. Safe for use inside a `sh -c` script.
fn posix_shell_quote(s: &str) -> String {
    if s.is_empty() {
        return "''".into();
    }
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for ch in s.chars() {
        if ch == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(ch);
        }
    }
    out.push('\'');
    out
}

fn watch_codex_session_id(
    db: Db,
    app_session_id: String,
    cwd: Utf8PathBuf,
    started_at: std::time::SystemTime,
) {
    tokio::spawn(async move {
        for _ in 0..20 {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let cwd = cwd.clone();
            let found =
                tokio::task::spawn_blocking(move || find_latest_codex_session_id(&cwd, started_at))
                    .await
                    .ok()
                    .flatten();
            if let Some(agent_session_id) = found {
                if let Err(e) = db
                    .sessions()
                    .update_agent_session_id(&app_session_id, &agent_session_id)
                    .await
                {
                    warn!(session_id = %app_session_id, error = %e, "update Codex session id failed");
                }
                break;
            }
        }
    });
}

fn find_latest_codex_session_id(
    cwd: &Utf8Path,
    started_at: std::time::SystemTime,
) -> Option<String> {
    let home = std::env::var_os("HOME")?;
    let root = std::path::PathBuf::from(home)
        .join(".codex")
        .join("sessions");
    find_latest_codex_session_id_in(&root, cwd, started_at)
}

fn find_latest_codex_session_id_in(
    root: &std::path::Path,
    cwd: &Utf8Path,
    started_at: std::time::SystemTime,
) -> Option<String> {
    let mut files = Vec::new();
    collect_jsonl_files(root, &mut files);
    files.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|m| m.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH)
    });
    files.reverse();

    for path in files.into_iter().take(200) {
        let Some(modified) = std::fs::metadata(&path).and_then(|m| m.modified()).ok() else {
            continue;
        };
        if modified < started_at {
            continue;
        }
        let Some(first) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|s| s.lines().next().map(str::to_string))
        else {
            continue;
        };
        if let Some(id) = parse_codex_session_meta(&first, cwd.as_str()) {
            return Some(id);
        }
    }
    None
}

fn collect_jsonl_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_jsonl_files(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("jsonl") {
            out.push(path);
        }
    }
}

fn parse_codex_session_meta(line: &str, cwd: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(line).ok()?;
    if value.get("type")?.as_str()? != "session_meta" {
        return None;
    }
    let payload = value.get("payload")?;
    if payload.get("originator").and_then(|v| v.as_str()) == Some("Codex Desktop") {
        return None;
    }
    if payload.get("cwd")?.as_str()? != cwd {
        return None;
    }
    payload.get("id")?.as_str().map(str::to_string)
}

fn watch_gemini_session_id(
    db: Db,
    app_session_id: String,
    cwd: Utf8PathBuf,
    started_at: std::time::SystemTime,
) {
    tokio::spawn(async move {
        for _ in 0..20 {
            tokio::time::sleep(std::time::Duration::from_millis(500)).await;
            let cwd = cwd.clone();
            let found = tokio::task::spawn_blocking(move || {
                find_latest_gemini_session_id(&cwd, started_at)
            })
            .await
            .ok()
            .flatten();
            if let Some(agent_session_id) = found {
                if let Err(e) = db
                    .sessions()
                    .update_agent_session_id(&app_session_id, &agent_session_id)
                    .await
                {
                    warn!(session_id = %app_session_id, error = %e, "update Gemini session id failed");
                }
                break;
            }
        }
    });
}

fn find_latest_gemini_session_id(
    cwd: &Utf8Path,
    started_at: std::time::SystemTime,
) -> Option<String> {
    let home = std::path::PathBuf::from(std::env::var_os("HOME")?);
    let project_key = gemini_project_key(&home, cwd)?;
    let chats_dir = home
        .join(".gemini")
        .join("tmp")
        .join(project_key)
        .join("chats");
    find_latest_gemini_session_id_in(&chats_dir, started_at)
}

fn gemini_project_key(home: &std::path::Path, cwd: &Utf8Path) -> Option<String> {
    let projects_path = home.join(".gemini").join("projects.json");
    let value: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(projects_path).ok()?).ok()?;
    value
        .get("projects")?
        .get(cwd.as_str())?
        .as_str()
        .map(str::to_string)
}

fn find_latest_gemini_session_id_in(
    chats_dir: &std::path::Path,
    started_at: std::time::SystemTime,
) -> Option<String> {
    let mut files = Vec::new();
    collect_json_files(chats_dir, &mut files);
    files.retain(|path| {
        path.file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("session-") && name.ends_with(".json"))
    });
    files.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|m| m.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH)
    });
    files.reverse();

    for path in files.into_iter().take(50) {
        let Some(modified) = std::fs::metadata(&path).and_then(|m| m.modified()).ok() else {
            continue;
        };
        if modified < started_at {
            continue;
        }
        let Some(id) = std::fs::read_to_string(&path)
            .ok()
            .and_then(|contents| parse_gemini_session_file(&contents))
        else {
            continue;
        };
        return Some(id);
    }
    None
}

fn parse_gemini_session_file(contents: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(contents).ok()?;
    if value.get("kind").and_then(|v| v.as_str()) == Some("subagent") {
        return None;
    }
    value.get("sessionId")?.as_str().map(str::to_string)
}

fn collect_json_files(dir: &std::path::Path, out: &mut Vec<std::path::PathBuf>) {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_json_files(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("json") {
            out.push(path);
        }
    }
}

fn terminal_env<I>(vars: I) -> Vec<(String, String)>
where
    I: IntoIterator<Item = (String, String)>,
{
    let mut env: BTreeMap<String, String> = vars.into_iter().collect();
    env.insert("TERM".into(), "xterm-256color".into());
    env.insert("COLORTERM".into(), "truecolor".into());
    env.entry("FORCE_COLOR".into())
        .or_insert_with(|| "1".into());
    env.insert("CLICOLOR".into(), "1".into());
    env.insert("CLICOLOR_FORCE".into(), "1".into());
    env.remove("NO_COLOR");
    // macOS launchd-launched .app processes inherit a minimal environment with
    // no LANG/LC_*, so the spawned shell falls back to the POSIX C locale and
    // zle treats UTF-8 multi-byte sequences as 8-bit Latin-1 — every byte in
    // 0x80-0x9F renders as a literal `<00xx>` reverse-video marker, so pasted
    // or IME-typed CJK turns into garbage. dev mode is fine because it
    // inherits the user's terminal LANG. Default to en_US.UTF-8 here only
    // when the user hasn't already set a locale (their shell rc still wins).
    env.entry("LANG".into())
        .or_insert_with(|| "en_US.UTF-8".into());
    env.entry("LC_CTYPE".into())
        .or_insert_with(|| "UTF-8".into());
    env.into_iter().collect()
}

/// Inject `YCODE_TERMINAL_ID` (always), `YCODE_NOTIFY_SOCK` (when the notify
/// listener bound) and `YCODE_MCP_SOCK` (the MCP control socket) into a
/// spawned PTY's environment. These flow down to the agent CLI and, in turn,
/// to any MCP server child it spawns — that's how `ycode-mcp` learns which
/// terminal/project it's running inside and where to connect back. Existing
/// entries for these keys are stripped first so a misbehaving host shell can't
/// override what the helpers expect.
fn inject_notify_env(
    env: &mut Vec<(String, String)>,
    terminal_id: &str,
    sock_path: Option<&std::path::Path>,
    mcp_sock_path: Option<&std::path::Path>,
) {
    env.retain(|(k, _)| {
        k != "YCODE_TERMINAL_ID" && k != "YCODE_NOTIFY_SOCK" && k != "YCODE_MCP_SOCK"
    });
    env.push(("YCODE_TERMINAL_ID".into(), terminal_id.to_string()));
    if let Some(p) = sock_path {
        env.push(("YCODE_NOTIFY_SOCK".into(), p.to_string_lossy().into_owned()));
    }
    if let Some(p) = mcp_sock_path {
        env.push(("YCODE_MCP_SOCK".into(), p.to_string_lossy().into_owned()));
    }
}

/// Walk `root` honouring `.gitignore` / `.git/info/exclude` / global gitignore
/// and the `.git` directory exclusion. Returns entries sorted by path so the
/// frontend's tree-build can rely on parents arriving before children.
fn walk_repo(root: &Utf8Path) -> Result<Vec<FileEntry>, IpcError> {
    use ignore::WalkBuilder;
    let mut out = Vec::new();
    let walker = WalkBuilder::new(root.as_std_path())
        // Dotfiles can be useful (`.github/`, `.gitignore`, `.env.example`),
        // so we keep them visible by default. `.git` is the one exception —
        // the bare repo internals are never something the user wants to
        // browse, and `ignore` doesn't filter it out unless `hidden(true)`.
        // We strip it explicitly via `filter_entry` so the rest of the
        // dotfile policy stays unchanged.
        .hidden(false)
        .filter_entry(|entry| entry.file_name() != ".git")
        .build();
    for result in walker {
        let entry = match result {
            Ok(e) => e,
            Err(e) => {
                tracing::warn!(error = %e, "walk entry error; skipping");
                continue;
            }
        };
        let p = entry.path();
        if p == root.as_std_path() {
            continue;
        }
        let rel = match p.strip_prefix(root.as_std_path()) {
            Ok(r) => r,
            Err(_) => continue,
        };
        let rel_str = rel.to_string_lossy().replace('\\', "/");
        let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
        out.push(FileEntry {
            path: rel_str,
            is_dir,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(out)
}

/// Resolve a project-relative path to an absolute path under `repo`, rejecting
/// any input that escapes the repo (via `..` segments, absolute paths, or
/// symlinks pointing outside). Returns the canonicalized absolute path.
fn resolve_under_repo(repo: &Utf8Path, rel: &str) -> Result<std::path::PathBuf, IpcError> {
    let rel_path = std::path::Path::new(rel);
    if rel_path.is_absolute() {
        return Err(IpcError::BadInput(format!("path must be relative: {rel}")));
    }
    for comp in rel_path.components() {
        use std::path::Component;
        match comp {
            Component::Normal(_) => {}
            _ => return Err(IpcError::BadInput(format!("invalid path: {rel}"))),
        }
    }
    let abs = repo.as_std_path().join(rel_path);
    // For reads / writes through symlinks we don't canonicalize the leaf (it
    // may not exist yet for writes). Verify the parent is inside the repo.
    let repo_canon = repo
        .as_std_path()
        .canonicalize()
        .map_err(|e| IpcError::BadInput(format!("repo canonicalize: {e}")))?;
    let parent = abs.parent().unwrap_or(&abs);
    let parent_canon = parent
        .canonicalize()
        .map_err(|e| IpcError::BadInput(format!("parent canonicalize: {e}")))?;
    if !parent_canon.starts_with(&repo_canon) {
        return Err(IpcError::BadInput(format!("path escapes repo: {rel}")));
    }
    Ok(abs)
}

/// Run `git status --porcelain=v1 -z --untracked-files=all` and parse out
/// the working-tree (Y) side. We zip in numstat counts for tracked-modified
/// files; untracked files get a synthesized `+N / -0` from a line count.
///
/// `=all` (not `normal`) so a wholly-untracked directory lists each file
/// individually (`docs/assets/logo.png`) instead of collapsing to a single
/// `docs/assets/` entry — the latter has an empty basename and renders as a
/// nameless row in the panel. Ignored files are still excluded.
fn git_status_blocking(repo: &Utf8Path) -> Result<Vec<GitFileChange>, IpcError> {
    use std::process::Command;

    let out = Command::new("git")
        .arg("-C")
        .arg(repo.as_std_path())
        .args(["status", "--porcelain=v1", "-z", "--untracked-files=all"])
        .output()
        .map_err(|e| IpcError::BadInput(format!("spawn git status: {e}")))?;
    if !out.status.success() {
        let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
        return Err(IpcError::BadInput(format!("git status failed: {stderr}")));
    }

    // numstat is cheap and lets us avoid per-file `git diff --numstat` calls.
    // It only covers tracked changes; untracked files we count separately.
    let numstat_out = Command::new("git")
        .arg("-C")
        .arg(repo.as_std_path())
        .args(["diff", "--numstat", "-z"])
        .output()
        .map_err(|e| IpcError::BadInput(format!("spawn git diff: {e}")))?;
    let numstat = parse_numstat_z(&numstat_out.stdout);

    let mut changes = Vec::new();
    for entry in split_status_z(&out.stdout) {
        if entry.len() < 3 {
            continue;
        }
        let xy = &entry[..2];
        let path_part = &entry[3..];
        // Working-tree side only — skip staged-only changes (Y = ' ').
        let y = xy.as_bytes()[1];
        let x = xy.as_bytes()[0];

        let (status, path) = if x == b'?' && y == b'?' {
            (GitFileStatus::Untracked, path_part.to_string())
        } else if y == b'M' {
            (GitFileStatus::Modified, path_part.to_string())
        } else if y == b'D' {
            (GitFileStatus::Deleted, path_part.to_string())
        } else if y == b' ' {
            // staged-only — skip
            continue;
        } else {
            (GitFileStatus::Other, path_part.to_string())
        };

        let (additions, deletions) = match status {
            GitFileStatus::Untracked => (count_file_lines(repo, &path), 0),
            _ => numstat.get(&path).copied().unwrap_or((0, 0)),
        };

        changes.push(GitFileChange {
            path,
            status,
            additions,
            deletions,
        });
    }
    changes.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(changes)
}

/// Split NUL-terminated `git status -z` output into one entry per file. Each
/// returned slice is the raw entry including the 2-char XY prefix + space +
/// path. Renames produce two NUL-separated tokens; we drop the "old" half
/// since the panel only cares about the new path.
fn split_status_z(bytes: &[u8]) -> Vec<String> {
    let mut out = Vec::new();
    let s = String::from_utf8_lossy(bytes);
    let mut iter = s.split('\0');
    while let Some(entry) = iter.next() {
        if entry.is_empty() {
            continue;
        }
        // R/C status: next token is the old path — discard.
        if entry.len() >= 2 {
            let x = entry.as_bytes()[0];
            if x == b'R' || x == b'C' {
                let _ = iter.next();
            }
        }
        out.push(entry.to_string());
    }
    out
}

/// Parse `git diff --numstat -z` output into a map of path → (additions, deletions).
fn parse_numstat_z(bytes: &[u8]) -> std::collections::HashMap<String, (u32, u32)> {
    let mut map = std::collections::HashMap::new();
    let s = String::from_utf8_lossy(bytes);
    // `-z` makes numstat NUL-terminate records; renames emit three fields
    // (added, deleted, "old\0new") but we treat the file as a non-rename here
    // because numstat for unstaged renames is exceedingly rare.
    let mut iter = s.split('\0');
    while let Some(line) = iter.next() {
        if line.is_empty() {
            continue;
        }
        let mut parts = line.splitn(3, '\t');
        let add = parts.next().unwrap_or("0");
        let del = parts.next().unwrap_or("0");
        let path = parts.next().unwrap_or("");
        if path.is_empty() {
            continue;
        }
        let additions = add.parse::<u32>().unwrap_or(0);
        let deletions = del.parse::<u32>().unwrap_or(0);
        map.insert(path.to_string(), (additions, deletions));
    }
    map
}

fn count_file_lines(repo: &Utf8Path, rel: &str) -> u32 {
    let abs = repo.as_std_path().join(rel);
    let Ok(bytes) = std::fs::read(&abs) else {
        return 0;
    };
    if bytes.is_empty() {
        return 0;
    }
    // Treat a file with N lines (newline-terminated or not) as N additions.
    let mut count = bytes.iter().filter(|&&b| b == b'\n').count() as u32;
    if !bytes.ends_with(b"\n") {
        count += 1;
    }
    count
}

/// Run `git diff -- <path>` for tracked files or synthesize a "new file" diff
/// for untracked files. Returns empty string when the file is unchanged.
fn git_diff_file_blocking(repo: &Utf8Path, file_path: String) -> Result<String, IpcError> {
    use std::process::Command;

    // Reject path traversal — same enforcement as `read_repo_file`.
    let _ = resolve_under_repo(repo, &file_path)?;

    // Tracked vs untracked: `git ls-files --error-unmatch` exits 0 iff tracked.
    let tracked = Command::new("git")
        .arg("-C")
        .arg(repo.as_std_path())
        .args(["ls-files", "--error-unmatch", "--"])
        .arg(&file_path)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);

    if tracked {
        let out = Command::new("git")
            .arg("-C")
            .arg(repo.as_std_path())
            .args(["diff", "--no-color", "--no-ext-diff", "--"])
            .arg(&file_path)
            .output()
            .map_err(|e| IpcError::BadInput(format!("spawn git diff: {e}")))?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr).into_owned();
            return Err(IpcError::BadInput(format!("git diff failed: {stderr}")));
        }
        return Ok(String::from_utf8_lossy(&out.stdout).into_owned());
    }

    // Untracked: synthesize a "new file" diff so the frontend's gitdiff-parser
    // sees a normal-looking patch. `git diff --no-index` would work but exits
    // 1 on differences which the caller would have to whitelist.
    let abs = repo.as_std_path().join(&file_path);
    let bytes = std::fs::read(&abs)
        .map_err(|e| IpcError::BadInput(format!("read untracked {file_path}: {e}")))?;
    if bytes.contains(&0u8) {
        // Binary new file — render a stub patch the parser can still display.
        let body = format!(
            "diff --git a/{p} b/{p}\nnew file mode 100644\n--- /dev/null\n+++ b/{p}\nBinary file (untracked)\n",
            p = file_path
        );
        return Ok(body);
    }
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<&str> = text.split_inclusive('\n').collect();
    let line_count = if text.ends_with('\n') {
        lines.len()
    } else if text.is_empty() {
        0
    } else {
        lines.len()
    };

    let mut body = String::new();
    body.push_str(&format!("diff --git a/{p} b/{p}\n", p = file_path));
    body.push_str("new file mode 100644\n");
    body.push_str("--- /dev/null\n");
    body.push_str(&format!("+++ b/{p}\n", p = file_path));
    body.push_str(&format!("@@ -0,0 +1,{line_count} @@\n"));
    for line in &lines {
        body.push('+');
        body.push_str(line);
        if !line.ends_with('\n') {
            body.push('\n');
        }
    }
    Ok(body)
}

fn read_repo_file(repo: &Utf8Path, file_path: String) -> Result<FileContents, IpcError> {
    let abs = resolve_under_repo(repo, &file_path)?;
    let bytes =
        std::fs::read(&abs).map_err(|e| IpcError::BadInput(format!("read {}: {e}", file_path)))?;
    let head = &bytes[..bytes.len().min(8192)];
    let is_binary = head.contains(&0u8);
    let contents = if is_binary {
        String::new()
    } else {
        String::from_utf8_lossy(&bytes).into_owned()
    };
    Ok(FileContents {
        path: file_path,
        contents,
        is_binary,
    })
}

/// Read a file and return it as a `data:` URL (base64-encoded). The MIME type
/// is inferred from the extension; unknown types fall back to
/// `application/octet-stream`, which is still a valid (if non-rendering) URL.
fn read_repo_file_data_url(repo: &Utf8Path, file_path: String) -> Result<String, IpcError> {
    use base64::Engine;
    let abs = resolve_under_repo(repo, &file_path)?;
    let bytes =
        std::fs::read(&abs).map_err(|e| IpcError::BadInput(format!("read {}: {e}", file_path)))?;
    let mime = mime_for_path(&file_path);
    let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
    Ok(format!("data:{mime};base64,{encoded}"))
}

/// Map a file path's extension to an image MIME type for inline preview.
fn mime_for_path(path: &str) -> &'static str {
    let ext = path.rsplit('.').next().unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "bmp" => "image/bmp",
        "ico" => "image/x-icon",
        "svg" => "image/svg+xml",
        "avif" => "image/avif",
        "apng" => "image/apng",
        _ => "application/octet-stream",
    }
}

fn write_repo_file(repo: &Utf8Path, file_path: String, contents: String) -> Result<(), IpcError> {
    let abs = resolve_under_repo(repo, &file_path)?;
    std::fs::write(&abs, contents.as_bytes())
        .map_err(|e| IpcError::BadInput(format!("write {}: {e}", file_path)))?;
    Ok(())
}

fn delete_repo_path(repo: &Utf8Path, file_path: String) -> Result<(), IpcError> {
    if file_path.is_empty() {
        return Err(IpcError::BadInput("path is empty".into()));
    }
    let abs = resolve_under_repo(repo, &file_path)?;
    let meta = std::fs::symlink_metadata(&abs)
        .map_err(|e| IpcError::BadInput(format!("stat {}: {e}", file_path)))?;
    if meta.is_dir() {
        std::fs::remove_dir_all(&abs)
            .map_err(|e| IpcError::BadInput(format!("delete dir {}: {e}", file_path)))?;
    } else {
        std::fs::remove_file(&abs)
            .map_err(|e| IpcError::BadInput(format!("delete {}: {e}", file_path)))?;
    }
    Ok(())
}

fn rename_repo_path(
    repo: &Utf8Path,
    from_path: String,
    to_path: String,
) -> Result<(), IpcError> {
    if from_path.is_empty() || to_path.is_empty() {
        return Err(IpcError::BadInput("path is empty".into()));
    }
    if from_path == to_path {
        return Ok(());
    }
    let from_abs = resolve_under_repo(repo, &from_path)?;
    let to_abs = resolve_under_repo(repo, &to_path)?;
    if to_abs.exists() {
        return Err(IpcError::BadInput(format!("destination exists: {}", to_path)));
    }
    std::fs::rename(&from_abs, &to_abs)
        .map_err(|e| IpcError::BadInput(format!("rename {} → {}: {e}", from_path, to_path)))?;
    Ok(())
}

fn create_repo_path(repo: &Utf8Path, file_path: String, is_dir: bool) -> Result<(), IpcError> {
    if file_path.is_empty() {
        return Err(IpcError::BadInput("path is empty".into()));
    }
    let abs = resolve_under_repo(repo, &file_path)?;
    if abs.exists() {
        return Err(IpcError::BadInput(format!("already exists: {}", file_path)));
    }
    if is_dir {
        std::fs::create_dir(&abs)
            .map_err(|e| IpcError::BadInput(format!("create dir {}: {e}", file_path)))?;
    } else {
        // `create_new` so a race with another writer fails loudly rather than
        // truncating their file.
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&abs)
            .map_err(|e| IpcError::BadInput(format!("create {}: {e}", file_path)))?;
    }
    Ok(())
}

fn open_in_external_editor_blocking(req: OpenInExternalEditorRequest) -> Result<(), IpcError> {
    let path_str = req.path;
    if path_str.is_empty() {
        return Err(IpcError::BadInput("path is empty".into()));
    }

    let editor = req
        .editor
        .filter(|s| !s.trim().is_empty())
        .or_else(|| std::env::var("VISUAL").ok())
        .or_else(|| std::env::var("EDITOR").ok())
        .unwrap_or_else(default_editor);

    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg("-a").arg(&editor).arg(&path_str);
        c
    };
    #[cfg(not(target_os = "macos"))]
    let mut cmd = {
        let mut c = std::process::Command::new(&editor);
        c.arg(&path_str);
        c
    };

    cmd.spawn()
        .map(|_| ())
        .map_err(|e| IpcError::BadInput(format!("spawn editor {editor:?}: {e}")))
}

fn reveal_in_finder_blocking(path: String) -> Result<(), IpcError> {
    if path.is_empty() {
        return Err(IpcError::BadInput("path is empty".into()));
    }
    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg("-R").arg(&path);
        c
    };
    #[cfg(not(target_os = "macos"))]
    let mut cmd = std::process::Command::new("xdg-open");
    #[cfg(not(target_os = "macos"))]
    cmd.arg(&path);

    cmd.spawn()
        .map(|_| ())
        .map_err(|e| IpcError::BadInput(format!("reveal {path}: {e}")))
}

/// Try to map a terminal-scraped candidate to a project-relative path.
///
/// Resolution order:
///   1. Direct: absolute, or relative joined to the project root.
///   2. Bare-filename fallback: if the candidate has no `/`, walk the project
///      tree (honouring `.gitignore`) and return the first match. Covers
///      `ls` output where the shell's cwd ≠ the project root (or the file
///      lives in a subdir we have no way to know about).
///
/// Returns `None` (not an error) when nothing resolves — the link provider
/// matches optimistically and lets the backend filter out false positives.
fn resolve_terminal_path_blocking(
    repo: &Utf8Path,
    candidate: &str,
) -> Result<Option<String>, IpcError> {
    let trimmed = candidate.trim();
    if trimmed.is_empty() {
        return Ok(None);
    }

    let repo_canon = repo
        .as_std_path()
        .canonicalize()
        .map_err(|e| IpcError::BadInput(format!("repo canonicalize: {e}")))?;

    // ── 1. Direct resolve ────────────────────────────────────────────────
    let raw = std::path::PathBuf::from(trimmed);
    let abs_candidate = if raw.is_absolute() {
        raw
    } else {
        repo.as_std_path().join(&raw)
    };
    if let Ok(canon) = abs_candidate.canonicalize() {
        if canon.is_file() && canon.starts_with(&repo_canon) {
            return Ok(Some(rel_under_repo(&repo_canon, &canon)?));
        }
    }

    // ── 2. Bare-filename fallback ────────────────────────────────────────
    //
    // Only fire when there's no `/` in the candidate. With a slash, the
    // user (or shell) gave us an explicit path; silently rewriting that to
    // a same-named file elsewhere in the tree would be surprising.
    if !trimmed.contains('/') {
        if let Some(rel) = find_first_by_name(&repo_canon, trimmed) {
            return Ok(Some(rel));
        }
    }

    Ok(None)
}

fn rel_under_repo(
    repo_canon: &std::path::Path,
    file_canon: &std::path::Path,
) -> Result<String, IpcError> {
    let rel = file_canon
        .strip_prefix(repo_canon)
        .map_err(|e| IpcError::BadInput(format!("strip prefix: {e}")))?;
    // Editor expects forward-slash project-relative paths (same format the
    // file tree emits). On Unix that's already the case; the explicit
    // conversion keeps Windows builds honest if/when we ship there.
    Ok(rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join("/"))
}

/// Walk `repo_canon` honouring `.gitignore` (same filters as `walk_repo`) and
/// return the first regular file whose basename matches `name`.
///
/// Uses early-return on the first hit. Re-walks per click; project trees are
/// usually small enough for this to be fine, and a stale cache would be a
/// worse UX than a few extra ms.
fn find_first_by_name(repo_canon: &std::path::Path, name: &str) -> Option<String> {
    use ignore::WalkBuilder;
    let walker = WalkBuilder::new(repo_canon)
        .hidden(false)
        .filter_entry(|entry| entry.file_name() != ".git")
        .build();
    for result in walker {
        let entry = match result {
            Ok(e) => e,
            Err(_) => continue,
        };
        if !entry.file_type().map(|t| t.is_file()).unwrap_or(false) {
            continue;
        }
        if entry.file_name() != name {
            continue;
        }
        let path = entry.path();
        if let Ok(rel) = path.strip_prefix(repo_canon) {
            return Some(
                rel.components()
                    .map(|c| c.as_os_str().to_string_lossy().into_owned())
                    .collect::<Vec<_>>()
                    .join("/"),
            );
        }
    }
    None
}

fn open_url_blocking(url: String) -> Result<(), IpcError> {
    // Restrict to web schemes so a malicious URL in PTY output can't be turned
    // into an arbitrary local-app launch via `open <url>` (which on macOS will
    // happily dispatch e.g. `file://`, `vscode://`, `x-apple-…://` handlers).
    let trimmed = url.trim();
    let lower = trimmed.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Err(IpcError::BadInput(format!("refusing non-http url: {url}")));
    }

    #[cfg(target_os = "macos")]
    let mut cmd = {
        let mut c = std::process::Command::new("open");
        c.arg(trimmed);
        c
    };
    #[cfg(target_os = "linux")]
    let mut cmd = {
        let mut c = std::process::Command::new("xdg-open");
        c.arg(trimmed);
        c
    };
    #[cfg(target_os = "windows")]
    let mut cmd = {
        // `start` is a cmd builtin, not a standalone exe; the empty title arg
        // keeps `start` from interpreting a quoted URL as the window title.
        let mut c = std::process::Command::new("cmd");
        c.args(["/C", "start", "", trimmed]);
        c
    };

    cmd.spawn()
        .map(|_| ())
        .map_err(|e| IpcError::BadInput(format!("open url {url}: {e}")))
}

fn default_editor() -> String {
    #[cfg(target_os = "macos")]
    {
        "Visual Studio Code".into()
    }
    #[cfg(not(target_os = "macos"))]
    {
        "code".into()
    }
}

fn home_dir() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(std::path::PathBuf::from)
}

fn token_counts_view(t: &usage::TokenCounts) -> TokenCountsView {
    TokenCountsView {
        input: t.input as f64,
        output: t.output as f64,
        cache_creation: t.cache_creation as f64,
        cache_read: t.cache_read as f64,
        reasoning: t.reasoning as f64,
        total: t.total() as f64,
    }
}

fn to_usage_view(agg: usage::WorkspaceUsage) -> WorkspaceUsageView {
    WorkspaceUsageView {
        totals: token_counts_view(&agg.totals),
        total_cost_usd: agg.total_cost_usd,
        sessions: agg
            .sessions
            .into_iter()
            .map(|s| SessionUsageView {
                agent: s.agent,
                session_id: s.session_id,
                title: s.title,
                jsonl_path: s.jsonl_path,
                model: s.model,
                tokens: token_counts_view(&s.tokens),
                cost_usd: s.cost_usd,
                first_ts_ms: s.first_ts_ms as f64,
                last_ts_ms: s.last_ts_ms as f64,
                message_count: s.message_count as f64,
            })
            .collect(),
        by_model: agg
            .by_model
            .into_iter()
            .map(|m| ModelUsageView {
                model: m.model,
                tokens: token_counts_view(&m.tokens),
                cost_usd: m.cost_usd,
            })
            .collect(),
        by_day: agg
            .by_day
            .into_iter()
            .map(|d| DailyUsageView {
                date: d.date,
                tokens: token_counts_view(&d.tokens),
                cost_usd: d.cost_usd,
            })
            .collect(),
        by_project: agg
            .by_project
            .into_iter()
            .map(|p| ProjectUsageView {
                project_id: p.project_id,
                name: p.name,
                tokens: token_counts_view(&p.tokens),
                cost_usd: p.cost_usd,
                session_count: p.session_count as f64,
            })
            .collect(),
    }
}

/// Background task driving one workspace's jsonl notify watcher. Watches the
/// claude project directory (when present) and the codex sessions root. Per
/// plan §8.12. Stops when `cancel` is triggered or the channel closes.
async fn run_jsonl_watcher(
    home: std::path::PathBuf,
    cwd: std::path::PathBuf,
    project_id: String,
    bus: broadcast::Sender<UiEvent>,
    cancel: CancellationToken,
) {
    use notify::{Config as NotifyConfig, EventKind, RecursiveMode, Watcher};

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<notify::Result<notify::Event>>();
    let watcher_result = notify::RecommendedWatcher::new(
        move |res| {
            // ignore send errors — receiver gone means we're shutting down
            let _ = tx.send(res);
        },
        NotifyConfig::default(),
    );
    let mut watcher = match watcher_result {
        Ok(w) => w,
        Err(e) => {
            warn!(project_id = %project_id, error = %e, "notify watcher init failed");
            return;
        }
    };

    // Claude: per-workspace, non-recursive.
    use ycode_introspect::{claude, codex, AgentBackend};
    if let Some(dir) = (claude::ClaudeBackend).workspace_dir(&home, &cwd) {
        if dir.is_dir() {
            if let Err(e) = watcher.watch(&dir, RecursiveMode::NonRecursive) {
                warn!(path = %dir.display(), error = %e, "claude watcher failed");
            }
        }
    }
    // Codex: recursive on the sessions root (date-sharded).
    if let Some(root) = (codex::CodexBackend).sessions_root(&home) {
        if root.is_dir() {
            if let Err(e) = watcher.watch(&root, RecursiveMode::Recursive) {
                warn!(path = %root.display(), error = %e, "codex watcher failed");
            }
        }
    }

    let cwd_str = cwd.to_string_lossy().into_owned();
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            ev = rx.recv() => match ev {
                Some(Ok(event)) => {
                    if !matches!(event.kind, EventKind::Create(_) | EventKind::Modify(_)) {
                        continue;
                    }
                    for path in event.paths {
                        if path.extension().and_then(|s| s.to_str()) != Some("jsonl") {
                            continue;
                        }
                        let (agent, session_id) = classify_jsonl(&path, &cwd_str);
                        let Some(agent) = agent else { continue };
                        let sid = session_id.unwrap_or_else(|| project_id.clone());
                        let _ = bus.send(UiEvent::jsonl_changed(sid, agent, path.to_string_lossy().into_owned()));
                    }
                }
                Some(Err(e)) => warn!(error = %e, "notify recv error"),
                None => break,
            }
        }
    }
    drop(watcher);
}

/// Best-effort routing of a touched jsonl path to (agent, session_id). Returns
/// `(None, _)` if the path isn't recognised so the watcher can ignore it.
fn classify_jsonl(
    path: &std::path::Path,
    workspace_cwd: &str,
) -> (Option<&'static str>, Option<String>) {
    let path_str = path.to_string_lossy();
    if path_str.contains("/.claude/projects/") {
        let session_id = path
            .file_stem()
            .and_then(|s| s.to_str())
            .map(|s| s.to_string());
        return (Some("claude"), session_id);
    }
    if path_str.contains("/.codex/sessions/") {
        // Codex paths are date-sharded; only emit when the rollout's first
        // line confirms it belongs to this workspace.
        use std::io::{BufRead, BufReader};
        let Ok(f) = std::fs::File::open(path) else {
            return (None, None);
        };
        let mut reader = BufReader::new(f);
        let mut first = String::new();
        let _ = reader.read_line(&mut first);
        let Ok(v) = serde_json::from_str::<serde_json::Value>(&first) else {
            return (None, None);
        };
        let payload_cwd = v
            .pointer("/payload/cwd")
            .and_then(|s| s.as_str())
            .unwrap_or("");
        if payload_cwd != workspace_cwd {
            return (None, None);
        }
        let session_id = v
            .pointer("/payload/id")
            .and_then(|s| s.as_str())
            .map(|s| s.to_string());
        return (Some("codex"), session_id);
    }
    (None, None)
}

fn stat_session(path: &std::path::Path) -> (u64, i64) {
    let meta = match std::fs::metadata(path) {
        Ok(m) => m,
        Err(_) => return (0, 0),
    };
    let size = meta.len();
    let modified_at_ms = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0);
    (size, modified_at_ms)
}

fn truncate_preview(s: &str) -> String {
    const MAX: usize = 200;
    if s.len() <= MAX {
        return s.replace('\n', " ");
    }
    let mut idx = MAX;
    while !s.is_char_boundary(idx) && idx > 0 {
        idx -= 1;
    }
    let mut out = s[..idx].replace('\n', " ");
    out.push('…');
    out
}

fn compute_available_agents(config: &Config) -> std::collections::HashSet<String> {
    use std::path::PathBuf;
    let path_dirs: Vec<PathBuf> = std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default();
    let mut out = std::collections::HashSet::new();
    for agent in &config.agents {
        let resolved = if PathBuf::from(&agent.command).is_absolute() {
            PathBuf::from(&agent.command).is_file()
        } else {
            path_dirs.iter().any(|d| d.join(&agent.command).is_file())
        };
        if resolved {
            out.insert(agent.id.clone());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use ycode_persist::SessionRow;

    fn profile(id: &str, command: &str) -> AgentLaunchProfile {
        AgentLaunchProfile {
            id: id.into(),
            display_name: None,
            command: command.into(),
            args: vec!["--existing".into()],
            env: Default::default(),
            icon: None,
            icon_variant: None,
            color: None,
            introspect: None,
        }
    }

    fn row(agent_session_id: Option<&str>, agent_thread_name: Option<&str>) -> SessionRow {
        SessionRow {
            id: "app-session".into(),
            title: "".into(),
            agent_profile: "test".into(),
            agent_session_id: agent_session_id.map(str::to_string),
            agent_thread_name: agent_thread_name.map(str::to_string),
            project_id: "project".into(),
            last_exit_code: None,
            created_at: 1,
            updated_at: 1,
            archived_at: None,
        }
    }

    #[test]
    fn claude_create_and_resume_use_native_session_id() {
        let profile = profile("claude-code", "claude");
        let row = row(Some("11111111-1111-4111-8111-111111111111"), None);

        assert_eq!(
            launch_args(&profile, &row, LaunchMode::Create),
            vec![
                "--existing",
                "--session-id",
                "11111111-1111-4111-8111-111111111111"
            ]
        );
        assert_eq!(
            launch_args(&profile, &row, LaunchMode::Resume),
            vec![
                "--existing",
                "--resume",
                "11111111-1111-4111-8111-111111111111"
            ]
        );
    }

    #[test]
    fn codex_resume_prefers_id_then_thread_name() {
        let profile = profile("codex", "codex");

        assert_eq!(
            launch_args(
                &profile,
                &row(Some("22222222-2222-4222-8222-222222222222"), Some("thread")),
                LaunchMode::Resume,
            ),
            vec![
                "--existing",
                "resume",
                "22222222-2222-4222-8222-222222222222"
            ]
        );
        assert_eq!(
            launch_args(
                &profile,
                &row(None, Some("Generated title")),
                LaunchMode::Resume,
            ),
            vec!["--existing", "resume", "Generated title"]
        );
    }

    #[test]
    fn gemini_resume_uses_native_session_id() {
        let profile = profile("gemini-cli", "gemini");

        assert_eq!(
            launch_args(
                &profile,
                &row(Some("33333333-3333-4333-8333-333333333333"), None),
                LaunchMode::Resume,
            ),
            vec![
                "--existing",
                "--resume",
                "33333333-3333-4333-8333-333333333333"
            ]
        );
    }

    #[test]
    fn env_keys_to_strip_targets_provider_api_keys() {
        // Per plan §8.2 / R4 the highest-likelihood × impact risk is a stray
        // ANTHROPIC_API_KEY / OPENAI_API_KEY silently hijacking the OAuth
        // subscription path. Lock the behaviour down here so any future
        // refactor of the launch path has to consciously break this test.
        assert_eq!(
            env_keys_to_strip(&profile("claude-code", "claude")),
            &["ANTHROPIC_API_KEY", "CLAUDE_API_KEY"]
        );
        assert_eq!(
            env_keys_to_strip(&profile("codex", "codex")),
            &["OPENAI_API_KEY"]
        );
        assert_eq!(
            env_keys_to_strip(&profile("gemini-cli", "gemini")),
            &["GEMINI_API_KEY", "GOOGLE_API_KEY"]
        );
        let shell: &[&str] = &[];
        assert_eq!(env_keys_to_strip(&profile("shell", "bash")), shell);
    }

    #[test]
    fn posix_shell_quote_escapes_single_quotes_and_empties() {
        assert_eq!(posix_shell_quote(""), "''");
        assert_eq!(posix_shell_quote("hello"), "'hello'");
        assert_eq!(posix_shell_quote("a b"), "'a b'");
        // Single quote inside: close, escape with backslash, reopen.
        assert_eq!(posix_shell_quote("it's"), "'it'\\''s'");
        // Path with spaces and a quote.
        assert_eq!(
            posix_shell_quote("/Users/me/it's/path"),
            "'/Users/me/it'\\''s/path'"
        );
        // Shell metacharacters stay literal inside single quotes.
        assert_eq!(posix_shell_quote("$(rm -rf /)"), "'$(rm -rf /)'");
    }

    #[cfg(unix)]
    #[test]
    fn wrap_in_login_shell_builds_shell_dash_lic_with_exec() {
        // Pin $SHELL so the test isn't environment-dependent.
        let prev = std::env::var_os("SHELL");
        // SAFETY: tests in this crate are run single-threaded enough that
        // mutating SHELL here is fine; the assertion runs before any other
        // shell-env reader.
        unsafe { std::env::set_var("SHELL", "/bin/zsh") };
        let (cmd, args) = wrap_in_login_shell(
            "claude".to_string(),
            vec!["--resume".into(), "abc def".into()],
        );
        // Restore before any assertion in case it panics.
        match prev {
            Some(v) => unsafe { std::env::set_var("SHELL", v) },
            None => unsafe { std::env::remove_var("SHELL") },
        }
        assert_eq!(cmd, "/bin/zsh");
        assert_eq!(args[0], "-l");
        assert_eq!(args[1], "-i");
        assert_eq!(args[2], "-c");
        // The script must `exec` (so signals/PIDs behave as if direct-spawned)
        // and properly quote args that contain spaces.
        assert_eq!(args[3], "exec 'claude' '--resume' 'abc def'");
    }

    #[test]
    fn parses_codex_cli_session_meta() {
        let line = r#"{"type":"session_meta","payload":{"id":"019e5794-57d2-7493-a762-a1fc7c1a5040","cwd":"/repo","originator":"Codex CLI"}}"#;
        assert_eq!(
            parse_codex_session_meta(line, "/repo").as_deref(),
            Some("019e5794-57d2-7493-a762-a1fc7c1a5040")
        );
        assert!(parse_codex_session_meta(line, "/other").is_none());
    }

    #[test]
    fn ignores_codex_desktop_session_meta() {
        let line = r#"{"type":"session_meta","payload":{"id":"019e5794-57d2-7493-a762-a1fc7c1a5040","cwd":"/repo","originator":"Codex Desktop"}}"#;
        assert!(parse_codex_session_meta(line, "/repo").is_none());
    }

    #[test]
    fn parses_gemini_session_file() {
        let contents =
            r#"{"sessionId":"44444444-4444-4444-8444-444444444444","kind":"main","messages":[]}"#;
        assert_eq!(
            parse_gemini_session_file(contents).as_deref(),
            Some("44444444-4444-4444-8444-444444444444")
        );
        let subagent = r#"{"sessionId":"sub","kind":"subagent","messages":[]}"#;
        assert!(parse_gemini_session_file(subagent).is_none());
    }

    #[test]
    fn codex_session_scan_ignores_files_older_than_launch() {
        let tmp = tempfile::tempdir().unwrap();
        let old = tmp.path().join("old.jsonl");
        std::fs::write(
            &old,
            r#"{"type":"session_meta","payload":{"id":"old","cwd":"/repo","originator":"Codex CLI"}}"#,
        )
        .unwrap();
        let cutoff = std::time::SystemTime::now();

        assert!(
            find_latest_codex_session_id_in(tmp.path(), Utf8Path::new("/repo"), cutoff).is_none()
        );

        let new = tmp.path().join("new.jsonl");
        std::fs::write(
            &new,
            r#"{"type":"session_meta","payload":{"id":"new","cwd":"/repo","originator":"Codex CLI"}}"#,
        )
        .unwrap();
        assert_eq!(
            find_latest_codex_session_id_in(tmp.path(), Utf8Path::new("/repo"), cutoff).as_deref(),
            Some("new")
        );
    }

    #[test]
    fn gemini_session_scan_ignores_files_older_than_launch() {
        let tmp = tempfile::tempdir().unwrap();
        let old = tmp.path().join("session-2026-01-01T00-00-old.json");
        std::fs::write(&old, r#"{"sessionId":"old","kind":"main","messages":[]}"#).unwrap();
        let cutoff = std::time::SystemTime::now();

        assert!(find_latest_gemini_session_id_in(tmp.path(), cutoff).is_none());

        let new = tmp.path().join("session-2026-01-01T00-01-new.json");
        std::fs::write(&new, r#"{"sessionId":"new","kind":"main","messages":[]}"#).unwrap();
        assert_eq!(
            find_latest_gemini_session_id_in(tmp.path(), cutoff).as_deref(),
            Some("new")
        );
    }
}

/// External-tool gating message for an `InstallSpec`. `None` means "no
/// prerequisites the user needs to install themselves" — the UI shows the
/// install button as fully enabled.
fn lsp_requirement_message(spec: &InstallSpec) -> Option<String> {
    match spec {
        InstallSpec::GithubReleaseGzip { .. } => None,
        InstallSpec::Npm { .. } => {
            if std::env::var_os("PATH")
                .map(|paths| {
                    std::env::split_paths(&paths).any(|d| {
                        d.join("npm").is_file()
                            || d.join("npm.cmd").is_file()
                            || d.join("npm.exe").is_file()
                    })
                })
                .unwrap_or(false)
            {
                None
            } else {
                Some("Requires npm on PATH. Install Node.js first.".into())
            }
        }
    }
}

#[derive(Error, Debug)]
pub enum IpcError {
    #[error("unknown agent profile `{0}`")]
    UnknownAgentProfile(String),

    #[error("session `{0}` is archived")]
    Archived(String),

    #[error("session `{0}` is not live")]
    SessionNotLive(String),

    #[error("invalid repo path `{0}`")]
    InvalidRepoPath(String),

    #[error("bad input: {0}")]
    BadInput(String),

    #[error("terminal: {0}")]
    Terminal(#[from] TerminalError),

    #[error("persist: {0}")]
    Persist(#[from] PersistError),

    #[error("config: {0}")]
    Config(#[from] ycode_config::ConfigError),

    #[error("lsp: {0}")]
    Lsp(#[from] ycode_lsp::LspError),
}
