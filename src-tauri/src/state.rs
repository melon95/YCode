//! Application state — wires `Service` from on-disk config and DB.

use std::collections::HashMap;
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
}

/// A `ycode <path>` request that arrived before its window's webview was
/// listening, held until the webview asks for it.
///
/// Why this exists: `ycode .` with the app closed launches YCode and then
/// retries the socket, which succeeds as soon as the *backend* is up — several
/// seconds before React mounts and subscribes to `ycode://cli-open`. A Tauri
/// `emit` at that moment goes nowhere, so the cold-start case (the one users
/// hit most: open a terminal, type `ycode .`) would create the project but
/// never switch to it. The webview drains this slot on mount instead.
///
/// Keyed by window label, so a detached single-project window mounting later
/// can't steal a request meant for main — and, just as importantly, so two
/// requests aimed at *different* windows don't evict each other. Two windows
/// can be booting at once (`ycode ~/a && ycode ~/b` while a detached window is
/// still mounting); with one shared slot the first request would vanish
/// silently after the CLI had already reported success. Bounded by the number
/// of live windows.
#[derive(Default)]
pub struct PendingCliOpen(Mutex<HashMap<String, serde_json::Value>>);

impl PendingCliOpen {
    /// Park a payload for `label`. A second request for the *same* label before
    /// the first is drained replaces it: the user's most recent `ycode`
    /// invocation is the one they are waiting on.
    pub fn park(&self, label: String, payload: serde_json::Value) {
        // A panicked lock holder would only ever have been mid-insert, so the
        // map is still structurally sound — recover rather than poison the
        // whole CLI path.
        let mut slots = self.0.lock().unwrap_or_else(|e| e.into_inner());
        slots.insert(label, payload);
    }

    /// Take the payload routed to `label`, if any. Payloads for other windows
    /// are left untouched.
    pub fn take_for(&self, label: &str) -> Option<serde_json::Value> {
        let mut slots = self.0.lock().unwrap_or_else(|e| e.into_inner());
        slots.remove(label)
    }
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

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(tag: &str) -> serde_json::Value {
        serde_json::json!({ "project_id": tag })
    }

    #[test]
    fn take_is_scoped_to_the_target_window_and_consumes_once() {
        let pending = PendingCliOpen::default();
        pending.park("main".into(), payload("a"));

        // A different window must not be able to drain a request routed
        // elsewhere — otherwise a detached project window mounting at the
        // wrong moment steals the main window's `ycode .`.
        assert!(pending.take_for("project-1").is_none());

        assert_eq!(pending.take_for("main"), Some(payload("a")));
        // Destructive by design: a later remount must not replay it.
        assert!(pending.take_for("main").is_none());
    }

    /// Two windows booting concurrently (`ycode ~/a && ycode ~/b` while a
    /// detached window is still mounting) must not evict each other — the CLI
    /// has already reported success for both.
    #[test]
    fn requests_for_different_windows_coexist() {
        let pending = PendingCliOpen::default();
        pending.park("project-A".into(), payload("a"));
        pending.park("main".into(), payload("b"));

        assert_eq!(pending.take_for("project-A"), Some(payload("a")));
        assert_eq!(pending.take_for("main"), Some(payload("b")));
    }

    #[test]
    fn parking_twice_keeps_the_newest_request() {
        let pending = PendingCliOpen::default();
        pending.park("main".into(), payload("old"));
        pending.park("main".into(), payload("new"));
        // The user's most recent `ycode <path>` is the one they're waiting on.
        assert_eq!(pending.take_for("main"), Some(payload("new")));
    }

    #[test]
    fn empty_slot_is_not_an_error() {
        let pending = PendingCliOpen::default();
        assert!(pending.take_for("main").is_none());
    }
}
