//! Application state — wires `Service` from on-disk config and DB.

use std::sync::Arc;

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;
use directories::ProjectDirs;
use ycode_config::Config;
use ycode_ipc::Service;
use ycode_persist::Db;

/// Root managed value installed via `app.manage(state)` in the Tauri builder.
pub struct AppState {
    pub service: Arc<Service>,
}

impl AppState {
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

        // Isolated session worktrees live alongside the DB, under the app data
        // dir, so they stay out of every project tree.
        let worktree_root = data_dir.join("worktrees");
        let service = Arc::new(Service::new(db, config, worktree_root));
        Ok(Self { service })
    }
}
