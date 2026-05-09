//! Multi-session orchestration.
//!
//! `SessionManager` is the level above [`SessionRunner`]: it owns the DB and
//! worktree resources, holds an adapter factory registry keyed by adapter
//! kind, and tracks the live `Arc<SessionRunner>`s. Tauri commands (and the
//! CLI smoke runner) use the manager rather than calling `SessionRunner`
//! directly.
//!
//! ## Restart and crash recovery
//!
//! Per `/Users/melon/.claude/plans/sleepy-roaming-graham.md`: on app restart
//! we do NOT auto-spawn adapters for non-archived rows. The manager exposes
//! [`SessionManager::list_records`] so the UI can display dormant rows; the
//! user explicitly invokes [`SessionManager::restart`] to bring one back to
//! life with a fresh adapter. ACP `session/load` is a v0.2 concern.

use std::collections::HashMap;
use std::sync::Arc;

use camino::{Utf8Path, Utf8PathBuf};
use thiserror::Error;
use tokio::sync::RwLock;
use tracing::{info, warn};

use ycode_adapter::{BoxedAdapter, SessionState, SpawnSpec};
use ycode_config::AgentLaunchProfile;
use ycode_persist::{Db, PersistError, SessionRow};
use ycode_worktree::{CleanupMode, WorktreeError, WorktreeManager};

use crate::orchestrator::{OrchestratorError, SessionRunner, SessionStart};

/// Factory function shape: given a launch profile, build a fresh adapter.
/// Registered once per adapter kind (`"acp"`, `"pty"`, `"echo"`, ...).
pub type AdapterFactoryFn =
    Arc<dyn Fn(&AgentLaunchProfile) -> Result<BoxedAdapter, ManagerError> + Send + Sync>;

pub struct SessionManager {
    db: Db,
    worktree_mgr: Arc<WorktreeManager>,
    factories: RwLock<HashMap<String, AdapterFactoryFn>>,
    runners: RwLock<HashMap<String, Arc<SessionRunner>>>,
}

impl SessionManager {
    pub fn new(db: Db, worktree_mgr: WorktreeManager) -> Self {
        Self {
            db,
            worktree_mgr: Arc::new(worktree_mgr),
            factories: RwLock::new(HashMap::new()),
            runners: RwLock::new(HashMap::new()),
        }
    }

    pub fn db(&self) -> &Db {
        &self.db
    }

    /// Register a factory for an adapter kind. Last writer wins.
    pub async fn register_factory(&self, kind: impl Into<String>, factory: AdapterFactoryFn) {
        self.factories.write().await.insert(kind.into(), factory);
    }

    /// Look up the factory for `kind`. Returns the cloned `Arc` so callers can
    /// invoke it without holding the registry lock.
    pub async fn factory_for(&self, kind: &str) -> Result<AdapterFactoryFn, ManagerError> {
        self.factories
            .read()
            .await
            .get(kind)
            .cloned()
            .ok_or_else(|| ManagerError::NoFactory(kind.to_string()))
    }

    /// Spin up a new session: detect repo, create worktree, build adapter,
    /// insert DB row, launch runner. Stores the runner in the registry.
    pub async fn create_session(
        &self,
        profile: &AgentLaunchProfile,
        repo_path: &Utf8Path,
        title: String,
    ) -> Result<Arc<SessionRunner>, ManagerError> {
        let kind = profile_kind_str(profile);
        let factory = self.factory_for(kind).await?;
        let repo = self.worktree_mgr.detect_repo(repo_path)?;

        let id = ulid::Ulid::new().to_string();
        let wt = self.worktree_mgr.create_for_session(&repo, &id)?;

        let adapter = factory(profile)?;
        let spawn_spec = build_spawn_spec(profile, &wt.worktree_path);

        let start = SessionStart {
            id: id.clone(),
            title,
            agent_profile: profile.id.clone(),
            repo_root: wt.repo_root.clone(),
            worktree_path: wt.worktree_path.clone(),
            branch: wt.branch.clone(),
            base_ref: wt.base_ref.clone(),
            spawn_spec,
        };

        let runner = match SessionRunner::start(self.db.clone(), adapter, start).await {
            Ok(r) => r,
            Err(e) => {
                // Roll back the worktree so we don't leak it on failed launch.
                let _ = self.worktree_mgr.cleanup(&wt, CleanupMode::DeleteBranch);
                return Err(e.into());
            }
        };

        self.runners.write().await.insert(id, runner.clone());
        Ok(runner)
    }

    /// Find a live runner by id.
    pub async fn get(&self, id: &str) -> Option<Arc<SessionRunner>> {
        self.runners.read().await.get(id).cloned()
    }

    /// All live runners. Order is unspecified.
    pub async fn list_live(&self) -> Vec<Arc<SessionRunner>> {
        self.runners.read().await.values().cloned().collect()
    }

    /// Merged DB + runtime view: every non-archived session row, with a flag
    /// indicating whether a live `SessionRunner` exists for it. UI renders
    /// from this.
    pub async fn list_records(&self) -> Result<Vec<SessionRecord>, ManagerError> {
        let rows = self.db.sessions().list_live().await?;
        let live = self.runners.read().await;
        Ok(rows
            .into_iter()
            .map(|r| {
                let is_live = live.contains_key(&r.id);
                SessionRecord { row: r, is_live }
            })
            .collect())
    }

    /// Resurrect a dormant session with a fresh adapter. The DB row keeps its
    /// id, transcript, and worktree; the agent process is brand-new (no LLM
    /// context recovery in MVP).
    pub async fn restart(
        &self,
        id: &str,
        profile: &AgentLaunchProfile,
    ) -> Result<Arc<SessionRunner>, ManagerError> {
        // Refuse if a live runner is already in residence.
        if self.runners.read().await.contains_key(id) {
            return Err(ManagerError::AlreadyLive(id.to_string()));
        }
        let row = self.db.sessions().get(id).await?;
        if row.archived_at.is_some() {
            return Err(ManagerError::Archived(id.to_string()));
        }
        if row.agent_profile != profile.id {
            return Err(ManagerError::ProfileMismatch {
                stored: row.agent_profile.clone(),
                provided: profile.id.clone(),
            });
        }
        let kind = profile_kind_str(profile);
        let factory = self.factory_for(kind).await?;
        let adapter = factory(profile)?;

        let worktree_path = Utf8PathBuf::from(row.worktree_path.clone());
        let spawn_spec = build_spawn_spec(profile, &worktree_path);

        let runner = SessionRunner::start_resume(
            self.db.clone(),
            adapter,
            id.to_string(),
            profile.id.clone(),
            spawn_spec,
        )
        .await?;

        self.runners
            .write()
            .await
            .insert(id.to_string(), runner.clone());
        info!(session_id = %id, "session restarted");
        Ok(runner)
    }

    /// Tear a session down: shutdown runner, archive DB row, optionally remove
    /// the worktree.
    pub async fn archive(
        &self,
        id: &str,
        cleanup: CleanupMode,
    ) -> Result<(), ManagerError> {
        if let Some(runner) = self.runners.write().await.remove(id) {
            if let Err(e) = runner.shutdown().await {
                warn!(session_id = %id, error = %e, "shutdown during archive");
            }
        }
        let row = self.db.sessions().get(id).await?;
        if row.archived_at.is_none() {
            self.db.sessions().archive(id).await?;
        }
        if let Ok(repo) = self.worktree_mgr.detect_repo(Utf8Path::new(&row.repo_root)) {
            let wt = ycode_worktree::Worktree {
                session_id: id.to_string(),
                repo_root: repo.root.clone(),
                worktree_path: Utf8PathBuf::from(row.worktree_path.clone()),
                branch: row.branch.clone(),
                base_ref: row.base_ref.clone(),
            };
            if let Err(e) = self.worktree_mgr.cleanup(&wt, cleanup) {
                warn!(session_id = %id, error = %e, "worktree cleanup during archive");
            }
        }
        info!(session_id = %id, "session archived");
        Ok(())
    }

    /// Eject a runner from the live registry without touching DB or worktree.
    /// Used by smoke tests that want to simulate a crash.
    pub async fn detach(&self, id: &str) -> Option<Arc<SessionRunner>> {
        self.runners.write().await.remove(id)
    }
}

/// One row from the merged "DB + live" view.
#[derive(Clone, Debug)]
pub struct SessionRecord {
    pub row: SessionRow,
    pub is_live: bool,
}

impl SessionRecord {
    pub fn parsed_state(&self) -> SessionState {
        serde_json::from_str(&self.row.state).unwrap_or(SessionState::Error {
            message: format!("malformed state JSON: {}", self.row.state),
        })
    }
}

fn profile_kind_str(profile: &AgentLaunchProfile) -> &'static str {
    use ycode_config::AdapterKind;
    match profile.kind {
        AdapterKind::Acp => "acp",
        AdapterKind::Pty => "pty",
        AdapterKind::Echo => "echo",
    }
}

fn build_spawn_spec(profile: &AgentLaunchProfile, cwd: &Utf8Path) -> SpawnSpec {
    SpawnSpec {
        cwd: cwd.to_path_buf(),
        env: profile
            .env
            .iter()
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect(),
        command: profile.command.clone(),
        args: profile.args.clone(),
    }
}

#[derive(Error, Debug)]
pub enum ManagerError {
    #[error("no factory registered for adapter kind `{0}`")]
    NoFactory(String),

    #[error("session `{0}` is already live")]
    AlreadyLive(String),

    #[error("session `{0}` is archived")]
    Archived(String),

    #[error("profile mismatch: row recorded `{stored}`, caller passed `{provided}`")]
    ProfileMismatch { stored: String, provided: String },

    #[error("adapter factory: {0}")]
    Factory(String),

    #[error("orchestrator: {0}")]
    Orchestrator(#[from] OrchestratorError),

    #[error("worktree: {0}")]
    Worktree(#[from] WorktreeError),

    #[error("persist: {0}")]
    Persist(#[from] PersistError),
}
