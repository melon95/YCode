//! `Service` — concrete IPC command handler.
//!
//! Holds the [`SessionManager`] and the loaded [`Config`]; each method
//! corresponds to one IPC command. The Tauri shell wraps each method as
//! `#[tauri::command]` and emits `UiEvent`s by subscribing to runner
//! event buses.
//!
//! Methods deliberately avoid Tauri-specific types so this crate stays
//! transport-agnostic.

use std::sync::Arc;

use camino::Utf8Path;
use thiserror::Error;
use tokio::sync::{broadcast, RwLock};
use tracing::warn;

use ycode_adapter::AgentEvent;
use ycode_config::{AgentLaunchProfile, Config};
use ycode_core::{ManagerError, OrchestratorError, SessionManager};
use ycode_persist::PersistError;
use ycode_worktree::{CleanupMode, WorktreeError};

use crate::{
    AgentProfileView, AnswerPermissionRequest, CreateSessionRequest, ReplayEntry,
    ReplayRequest, SendPromptRequest, SessionView, UiEvent,
};

pub struct Service {
    manager: Arc<SessionManager>,
    config: RwLock<Config>,
    /// Fan-in of all per-session event streams. Subscribers are typically the
    /// Tauri shell's event-emit task, but tests can subscribe directly.
    ui_bus: broadcast::Sender<UiEvent>,
}

const UI_BUS_CAPACITY: usize = 4096;

impl Service {
    pub fn new(manager: Arc<SessionManager>, config: Config) -> Self {
        let (tx, _) = broadcast::channel(UI_BUS_CAPACITY);
        Self {
            manager,
            config: RwLock::new(config),
            ui_bus: tx,
        }
    }

    pub fn manager(&self) -> &Arc<SessionManager> {
        &self.manager
    }

    /// Subscribe to the merged UI event stream. The Tauri shell wires this
    /// receiver to `app_handle.emit_all("ycode://session", event)`.
    pub fn subscribe(&self) -> broadcast::Receiver<UiEvent> {
        self.ui_bus.subscribe()
    }

    /// Pump a session's `AgentEvent` broadcast into the merged UI bus.
    /// Spawns a background task that forwards every event tagged with the
    /// session id. Call this once per session — typically inside
    /// `create_session`/`restart_session`.
    pub fn pipe_session_events(&self, session_id: String, mut rx: broadcast::Receiver<AgentEvent>) {
        let bus = self.ui_bus.clone();
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(event) => {
                        let _ = bus.send(UiEvent::agent(session_id.clone(), event));
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(session_id = %session_id, lagged = n, "UI bus pipe lagged");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }
        });
    }

    pub async fn list_agents(&self) -> Vec<AgentProfileView> {
        self.config
            .read()
            .await
            .agents
            .iter()
            .map(AgentProfileView::from_profile)
            .collect()
    }

    pub async fn list_sessions(&self) -> Result<Vec<SessionView>, IpcError> {
        let records = self.manager.list_records().await?;
        Ok(records
            .into_iter()
            .map(|r| SessionView::from_row(r.row, r.is_live))
            .collect())
    }

    pub async fn create_session(
        &self,
        req: CreateSessionRequest,
    ) -> Result<SessionView, IpcError> {
        let profile = self
            .config
            .read()
            .await
            .find(&req.agent_profile_id)
            .cloned()
            .ok_or_else(|| IpcError::UnknownAgentProfile(req.agent_profile_id.clone()))?;
        let repo = Utf8Path::new(&req.repo_path);
        let runner = self.manager.create_session(&profile, repo, req.title).await?;
        let id = runner.id().to_string();
        self.pipe_session_events(id.clone(), runner.subscribe());
        // Refresh: pick up the inserted row.
        let row = self
            .manager
            .db()
            .sessions()
            .get(&id)
            .await
            .map_err(IpcError::Persist)?;
        let view = SessionView::from_row(row, true);
        let _ = self.ui_bus.send(UiEvent {
            session_id: id,
            kind: crate::UiEventKind::SessionAppeared,
        });
        Ok(view)
    }

    pub async fn send_prompt(&self, req: SendPromptRequest) -> Result<(), IpcError> {
        let runner = self
            .manager
            .get(&req.session_id)
            .await
            .ok_or_else(|| IpcError::UnknownSession(req.session_id.clone()))?;
        runner.prompt(req.text).await?;
        Ok(())
    }

    pub async fn answer_permission(&self, req: AnswerPermissionRequest) -> Result<(), IpcError> {
        let runner = self
            .manager
            .get(&req.session_id)
            .await
            .ok_or_else(|| IpcError::UnknownSession(req.session_id.clone()))?;
        runner.answer_permission(req.request_id, req.option_id).await?;
        Ok(())
    }

    pub async fn cancel_session(&self, session_id: String) -> Result<(), IpcError> {
        let runner = self
            .manager
            .get(&session_id)
            .await
            .ok_or_else(|| IpcError::UnknownSession(session_id))?;
        runner.cancel().await?;
        Ok(())
    }

    pub async fn archive_session(
        &self,
        session_id: String,
        delete_branch: bool,
    ) -> Result<(), IpcError> {
        let mode = if delete_branch {
            CleanupMode::DeleteBranch
        } else {
            CleanupMode::KeepBranch
        };
        self.manager.archive(&session_id, mode).await?;
        let _ = self.ui_bus.send(UiEvent {
            session_id,
            kind: crate::UiEventKind::SessionRemoved,
        });
        Ok(())
    }

    pub async fn restart_session(&self, session_id: String) -> Result<SessionView, IpcError> {
        // Reuse the existing row's agent_profile to look up the launch profile.
        let row = self
            .manager
            .db()
            .sessions()
            .get(&session_id)
            .await
            .map_err(IpcError::Persist)?;
        let profile: AgentLaunchProfile = self
            .config
            .read()
            .await
            .find(&row.agent_profile)
            .cloned()
            .ok_or_else(|| IpcError::UnknownAgentProfile(row.agent_profile.clone()))?;
        let runner = self.manager.restart(&session_id, &profile).await?;
        self.pipe_session_events(session_id.clone(), runner.subscribe());
        let row = self
            .manager
            .db()
            .sessions()
            .get(&session_id)
            .await
            .map_err(IpcError::Persist)?;
        let view = SessionView::from_row(row, true);
        let _ = self.ui_bus.send(UiEvent {
            session_id,
            kind: crate::UiEventKind::SessionTouched,
        });
        Ok(view)
    }

    pub async fn replay_events(&self, req: ReplayRequest) -> Result<Vec<ReplayEntry>, IpcError> {
        let rows = self
            .manager
            .db()
            .events()
            .replay(&req.session_id, req.from_seq)
            .await?;
        let mut out = Vec::with_capacity(rows.len());
        for r in rows {
            let event: AgentEvent = serde_json::from_str(&r.payload).map_err(|e| {
                IpcError::CorruptEvent(format!("session {}: seq {}: {}", r.session_id, r.seq, e))
            })?;
            out.push(ReplayEntry {
                seq: r.seq,
                ts_ms: r.ts,
                event,
            });
        }
        Ok(out)
    }
}

#[derive(Error, Debug)]
pub enum IpcError {
    #[error("unknown agent profile `{0}`")]
    UnknownAgentProfile(String),

    #[error("unknown session `{0}`")]
    UnknownSession(String),

    #[error("manager: {0}")]
    Manager(#[from] ManagerError),

    #[error("orchestrator: {0}")]
    Orchestrator(#[from] OrchestratorError),

    #[error("persist: {0}")]
    Persist(#[from] PersistError),

    #[error("worktree: {0}")]
    Worktree(#[from] WorktreeError),

    #[error("corrupt event row: {0}")]
    CorruptEvent(String),
}
