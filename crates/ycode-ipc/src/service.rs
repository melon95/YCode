//! `Service` — concrete IPC command handler.
//!
//! Owns the `TerminalManager` (the live PTY registry), the `Db` (project +
//! session rows), and the loaded `Config`. Each method corresponds to one
//! IPC command exposed by the Tauri shell.
//!
//! Methods deliberately avoid Tauri-specific types so this crate stays
//! transport-agnostic.

use std::sync::Arc;

use camino::{Utf8Path, Utf8PathBuf};
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use tracing::{info, warn};

use ycode_config::{AgentLaunchProfile, Config};
use ycode_persist::{Db, NewProject, NewSession, PersistError};
use ycode_terminal::{SpawnSpec, TerminalError, TerminalEvent, TerminalManager, TerminalSession};

use crate::{
    AgentProfileView, CreateProjectRequest, CreateSessionRequest, FileDiff, FileEntry,
    ProjectView, ResizePtyRequest, SessionView, UiEvent, UiEventKind, WritePtyRequest,
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

    /// Unified diff of `file_path` (relative to the project repo) against
    /// HEAD. Untracked files get a synthesized "all-add" diff so the
    /// frontend renders them uniformly. Runs git CLI on a blocking thread.
    pub async fn get_file_diff(
        &self,
        project_id: String,
        file_path: String,
    ) -> Result<FileDiff, IpcError> {
        let project = self.db.projects().get(&project_id).await?;
        let repo = Utf8PathBuf::from(project.repo_path);
        tokio::task::spawn_blocking(move || compute_diff(&repo, file_path))
            .await
            .map_err(|e| IpcError::BadInput(format!("diff task: {e}")))?
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
        let spec = SpawnSpec {
            command: profile.command.clone(),
            args: profile.args.clone(),
            env: profile
                .env
                .iter()
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect(),
            cwd,
            rows: INITIAL_ROWS,
            cols: INITIAL_COLS,
        };
        let session = self.terminals.spawn(id.to_string(), spec).await?;
        info!(session_id = %id, profile = %profile.id, "PTY spawned");
        Ok(session)
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

/// Run `git diff HEAD -- <file>` for tracked files, or synthesize a
/// full-add diff for untracked files. We shell out to `git` rather than
/// using `gix` to stay compatible with whatever git version the user has
/// (and to get rename/binary detection for free).
fn compute_diff(repo: &Utf8Path, file_path: String) -> Result<FileDiff, IpcError> {
    use std::process::Command;

    let status = Command::new("git")
        .args(["status", "--porcelain", "--", &file_path])
        .current_dir(repo.as_std_path())
        .output()
        .map_err(|e| IpcError::BadInput(format!("git status: {e}")))?;
    if !status.status.success() {
        return Err(IpcError::BadInput(format!(
            "git status failed: {}",
            String::from_utf8_lossy(&status.stderr).trim()
        )));
    }
    let porcelain = String::from_utf8_lossy(&status.stdout);
    let untracked = porcelain.lines().any(|l| l.starts_with("??"));

    if untracked {
        let abs = repo.join(&file_path);
        let content = std::fs::read_to_string(abs.as_std_path()).map_err(|e| {
            IpcError::BadInput(format!("read {}: {}", file_path, e))
        })?;
        let line_count = content.lines().count().max(1);
        let mut patch = String::new();
        patch.push_str(&format!("diff --git a/{file_path} b/{file_path}\n"));
        patch.push_str("new file mode 100644\n");
        patch.push_str("--- /dev/null\n");
        patch.push_str(&format!("+++ b/{file_path}\n"));
        patch.push_str(&format!("@@ -0,0 +1,{line_count} @@\n"));
        for line in content.lines() {
            patch.push('+');
            patch.push_str(line);
            patch.push('\n');
        }
        return Ok(FileDiff {
            path: file_path,
            patch,
            is_untracked: true,
        });
    }

    let diff = Command::new("git")
        .args(["diff", "--no-color", "HEAD", "--", &file_path])
        .current_dir(repo.as_std_path())
        .output()
        .map_err(|e| IpcError::BadInput(format!("git diff: {e}")))?;
    if !diff.status.success() {
        // `git diff` returns non-zero on legitimate errors (e.g. ambiguous
        // arg). Surface stderr so the user knows what went wrong.
        return Err(IpcError::BadInput(format!(
            "git diff failed: {}",
            String::from_utf8_lossy(&diff.stderr).trim()
        )));
    }
    Ok(FileDiff {
        path: file_path,
        patch: String::from_utf8_lossy(&diff.stdout).into_owned(),
        is_untracked: false,
    })
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
