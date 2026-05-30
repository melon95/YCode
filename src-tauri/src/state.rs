//! Application state — wires `Service` from on-disk config and DB.

use std::sync::{Arc, Mutex};

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;
use directories::ProjectDirs;
use ycode_config::Config;
use ycode_ipc::Service;
use ycode_persist::Db;

/// Root managed value installed via `app.manage(state)` in the Tauri builder.
pub struct AppState {
    pub service: Arc<Service>,
    /// Frontend pushes the id of the currently focused PTY pane here whenever
    /// it changes (via `set_active_terminal`). The event pump consults it to
    /// decide whether an incoming `AgentTurnComplete` should fire an OS
    /// notification: when the window is focused *and* the event matches this
    /// id, the user is literally looking at the pane and we stay silent.
    /// Shared `Arc<Mutex<…>>` so the pump can read it without going through
    /// `tauri::State` (which would need an `&AppHandle` round-trip).
    pub active_terminal: Arc<Mutex<Option<String>>>,
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

        let service = Arc::new(Service::new(db, config));
        Ok(Self {
            service,
            active_terminal: Arc::new(Mutex::new(None)),
        })
    }
}
