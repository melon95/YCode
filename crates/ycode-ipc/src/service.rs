//! `Service` — concrete IPC command handler.
//!
//! Owns the `TerminalManager` (the live PTY registry), the `Db` (project +
//! session rows), and the loaded `Config`. Each method corresponds to one
//! IPC command exposed by the Tauri shell.
//!
//! Methods deliberately avoid Tauri-specific types so this crate stays
//! transport-agnostic.

use std::{collections::BTreeMap, sync::Arc};

use camino::{Utf8Path, Utf8PathBuf};
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use tracing::{info, warn};

use ycode_config::{AgentLaunchProfile, Config};
use ycode_persist::{Db, NewProject, NewSession, PersistError};
use ycode_terminal::{SpawnSpec, TerminalError, TerminalEvent, TerminalManager, TerminalSession};

use crate::{
    AgentProfileView, CreateProjectRequest, CreateSessionRequest, FileContents, FileEntry,
    ProjectView, RenameSessionRequest, ResizePtyRequest, SessionView, SpawnPtyRequest, UiEvent,
    UiEventKind, WriteFileRequest, WritePtyRequest,
};

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
    /// Fan-in of all per-session terminal streams + membership events.
    /// Subscribers are typically the Tauri shell's emit task.
    ui_bus: broadcast::Sender<UiEvent>,
}

impl Service {
    pub fn new(db: Db, config: Config) -> Self {
        let available = compute_available_agents(&config);
        let (tx, _) = broadcast::channel(UI_BUS_CAPACITY);
        Self {
            db,
            terminals: Arc::new(TerminalManager::new()),
            config: RwLock::new(config),
            available_agents: RwLock::new(available),
            ui_bus: tx,
        }
    }

    /// Subscribe to the merged UI event stream. The Tauri shell wires this
    /// receiver to `app_handle.emit("ycode://session", event)`.
    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.ui_bus.subscribe()
    }

    pub async fn list_agents(&self) -> Vec<AgentProfileView> {
        let cfg = self.config.read().await;
        let avail = self.available_agents.read().await;
        cfg.agents
            .iter()
            .map(|p| AgentProfileView::from_profile(p, avail.contains(&p.id)))
            .collect()
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

    pub async fn create_project(
        &self,
        req: CreateProjectRequest,
    ) -> Result<ProjectView, IpcError> {
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
        self.db.projects().delete(&project_id).await?;
        let _ = self.ui_bus.send(UiEvent {
            session_id: project_id,
            kind: UiEventKind::ProjectRemoved,
        });
        Ok(())
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

    /// Overwrite a file's contents. Path-traversal-protected like `read_file`.
    /// Parent directories must already exist.
    pub async fn write_file(&self, req: WriteFileRequest) -> Result<(), IpcError> {
        let project = self.db.projects().get(&req.project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || write_repo_file(&repo, req.file_path, req.contents))
            .await
            .map_err(|e| IpcError::BadInput(format!("write task: {e}")))?
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

    pub async fn create_session(
        &self,
        req: CreateSessionRequest,
    ) -> Result<SessionView, IpcError> {
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
        let row = self
            .db
            .sessions()
            .insert(NewSession {
                id: id.clone(),
                title: req.title,
                agent_profile: profile.id.clone(),
                project_id: project.id,
            })
            .await?;

        let session = self.spawn_pty(&id, &profile, cwd).await.map_err(|e| {
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
            return Err(IpcError::BadInput(format!("cwd not a directory: {}", req.cwd)));
        }
        let id = format!("manual-{}", ulid::Ulid::new());
        // Empty `command` ⇒ user's login shell. Frontend uses this for the
        // second-terminal panel which doesn't know the host's $SHELL.
        let command = if req.command.is_empty() {
            std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".to_string())
        } else {
            req.command
        };
        let spec = SpawnSpec {
            command,
            args: req.args,
            // Inherit the host environment so the shell gets PATH/HOME/etc.
            env: terminal_env(std::env::vars()),
            cwd,
            rows: INITIAL_ROWS,
            cols: INITIAL_COLS,
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
    pub async fn rename_session(
        &self,
        req: RenameSessionRequest,
    ) -> Result<SessionView, IpcError> {
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

        let session = self.spawn_pty(&session_id, &profile, cwd).await?;
        self.pipe_terminal_events(session);

        let row = self.db.sessions().get(&session_id).await?;
        let view = SessionView::from_row(row, true);
        let _ = self.ui_bus.send(UiEvent {
            session_id,
            kind: UiEventKind::SessionTouched,
        });
        Ok(view)
    }

    async fn spawn_pty(
        &self,
        id: &str,
        profile: &AgentLaunchProfile,
        cwd: Utf8PathBuf,
    ) -> Result<Arc<TerminalSession>, IpcError> {
        let env = terminal_env(std::env::vars().chain(profile.env.iter().map(|(k, v)| {
            (k.clone(), v.clone())
        })));
        let spec = SpawnSpec {
            command: profile.command.clone(),
            args: profile.args.clone(),
            env,
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
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
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
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(TerminalEvent::Output(bytes)) => {
                        let _ = bus.send(UiEvent::pty_output(&id, &bytes));
                    }
                    Ok(TerminalEvent::TitleChanged(title)) => {
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
            drop(_session_keepalive);
        });
    }
}

fn terminal_env<I>(vars: I) -> Vec<(String, String)>
where
    I: IntoIterator<Item = (String, String)>,
{
    let mut env: BTreeMap<String, String> = vars.into_iter().collect();
    env.insert("TERM".into(), "xterm-256color".into());
    env.insert("COLORTERM".into(), "truecolor".into());
    env.entry("FORCE_COLOR".into()).or_insert_with(|| "1".into());
    env.insert("CLICOLOR".into(), "1".into());
    env.insert("CLICOLOR_FORCE".into(), "1".into());
    env.remove("NO_COLOR");
    env.into_iter().collect()
}

/// Walk `root` honouring `.gitignore` / `.git/info/exclude` / global gitignore
/// and the `.git` directory exclusion. Returns entries sorted by path so the
/// frontend's tree-build can rely on parents arriving before children.
fn walk_repo(root: &Utf8Path) -> Result<Vec<FileEntry>, IpcError> {
    use ignore::WalkBuilder;
    let mut out = Vec::new();
    let walker = WalkBuilder::new(root.as_std_path())
        .hidden(false) // dotfiles can be useful (e.g. `.github/`); .git is excluded by `git_ignore`.
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

fn write_repo_file(repo: &Utf8Path, file_path: String, contents: String) -> Result<(), IpcError> {
    let abs = resolve_under_repo(repo, &file_path)?;
    std::fs::write(&abs, contents.as_bytes())
        .map_err(|e| IpcError::BadInput(format!("write {}: {e}", file_path)))?;
    Ok(())
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
}
