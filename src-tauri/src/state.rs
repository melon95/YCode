//! Application state — wires up `Service` from on-disk config and DB.

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;
use directories::ProjectDirs;
use ycode_acp_adapter::AcpAdapter;
use ycode_adapter::BoxedAdapter;
use ycode_config::{AgentLaunchProfile, Config};
use ycode_core::{ManagerError, SessionManager};
use ycode_echo_adapter::EchoAdapter;
use ycode_ipc::Service;
use ycode_persist::Db;
use ycode_pty_adapter::{PtyAdapter, PtyAdapterConfig};
use ycode_worktree::WorktreeManager;

/// Root managed value installed via `app.manage(state)` in the Tauri builder.
/// All `#[tauri::command]` handlers reach in via `tauri::State`.
pub struct AppState {
    pub service: Arc<Service>,
}

impl AppState {
    /// Spin up the full backend: config, DB, worktree manager, factory
    /// registration, IPC service. Run once at startup.
    pub async fn initialize() -> Result<Self> {
        let config = Config::load().context("loading config")?;
        let dirs = ProjectDirs::from("dev", "ycode", "ycode")
            .ok_or_else(|| anyhow!("could not determine ycode data dir"))?;
        let data_dir = Utf8PathBuf::from_path_buf(dirs.data_dir().to_path_buf())
            .map_err(|p| anyhow!("data dir not UTF-8: {}", p.display()))?;
        std::fs::create_dir_all(data_dir.as_std_path())?;

        let db_path = data_dir.join("ycode.db");
        let db_url = format!("sqlite://{db_path}");
        let db = Db::open(&db_url)
            .await
            .with_context(|| format!("opening DB at {db_url}"))?;

        let worktree_root = data_dir.join("worktrees");
        std::fs::create_dir_all(worktree_root.as_std_path())?;
        let worktree_mgr = WorktreeManager::new(worktree_root);

        let manager = SessionManager::new(db, worktree_mgr);
        register_factories(&manager).await;

        let service = Arc::new(Service::new(Arc::new(manager), config));
        Ok(Self { service })
    }
}

async fn register_factories(manager: &SessionManager) {
    manager
        .register_factory(
            "echo",
            Arc::new(|_p: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                Ok(Box::new(EchoAdapter::new()))
            }),
        )
        .await;
    manager
        .register_factory(
            "acp",
            Arc::new(|_p: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                Ok(Box::new(AcpAdapter::new()))
            }),
        )
        .await;
    manager
        .register_factory(
            "pty",
            Arc::new(|p: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                let heuristic = p.heuristic_profile.clone().ok_or_else(|| {
                    ManagerError::Factory(format!(
                        "PTY profile `{}` is missing heuristic_profile",
                        p.id
                    ))
                })?;
                Ok(Box::new(PtyAdapter::new(PtyAdapterConfig {
                    heuristic_profile: heuristic,
                })))
            }),
        )
        .await;
}
