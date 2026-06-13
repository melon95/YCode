//! Per-project LSP fleet.
//!
//! Holds at most one `LspSession` per `(project_id, server_id)` tuple.
//! Routing is by file extension — `manifest_for_file("foo.rs")` returns the
//! manifest with `.rs` in its `file_extensions`. The caller picks language
//! id from the same manifest (each server pins exactly one language id per
//! extension via the order in `language_ids`).

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use tokio::sync::RwLock;
use tracing::warn;
use ycode_persist::Db;

use crate::client::{LspSession, NotificationSink};
use crate::manifest::{builtin_manifests, ServerManifest};
use crate::LspError;

pub struct LspManager {
    db: Db,
    sink: NotificationSink,
    // (project_id, server_id) → session
    sessions: RwLock<HashMap<(String, String), Arc<LspSession>>>,
}

impl LspManager {
    pub fn new(db: Db, sink: NotificationSink) -> Self {
        Self {
            db,
            sink,
            sessions: RwLock::new(HashMap::new()),
        }
    }

    /// First manifest whose `file_extensions` covers this path. Case-insensitive
    /// on the extension only.
    pub fn manifest_for_file(file_path: &str) -> Option<ServerManifest> {
        let lower = file_path.to_lowercase();
        for manifest in builtin_manifests() {
            for ext in &manifest.file_extensions {
                if lower.ends_with(&ext.to_lowercase()) {
                    return Some(manifest);
                }
            }
        }
        None
    }

    /// Language id the server expects for this file. Today every manifest
    /// pins one `language_id` per extension; we don't disambiguate by
    /// shebang or content sniff.
    pub fn language_id_for<'a>(manifest: &'a ServerManifest, file_path: &str) -> &'a str {
        // First extension that matches wins; fall back to the first language
        // id in the list when the manifest doesn't list extensions in the
        // same order as language ids (none of our built-ins do today but
        // it costs nothing to be safe).
        let lower = file_path.to_lowercase();
        for (idx, ext) in manifest.file_extensions.iter().enumerate() {
            if lower.ends_with(&ext.to_lowercase()) {
                if idx < manifest.language_ids.len() {
                    return &manifest.language_ids[idx];
                }
                break;
            }
        }
        manifest
            .language_ids
            .first()
            .map(String::as_str)
            .unwrap_or("plaintext")
    }

    /// Return the session for `(project, manifest)`, spawning it on demand.
    /// Errors when the manifest is not installed — the caller should treat
    /// that as "LSP unavailable for this file" and silently skip.
    pub async fn get_or_spawn(
        &self,
        project_id: &str,
        project_root: &Path,
        manifest: ServerManifest,
    ) -> Result<Arc<LspSession>, LspError> {
        // Require an install row before we even try to spawn. Bail with
        // `UnknownServer` (the install button in Settings becomes the user's
        // action item).
        let installed = self
            .db
            .lsp_installations()
            .get(&manifest.id)
            .await?
            .ok_or_else(|| LspError::UnknownServer(manifest.id.clone()))?;

        // Touch the install path so a deleted dir doesn't masquerade as
        // installed — the user might have wiped `~/.config/ycode/lsp` by
        // hand without going through the uninstall flow.
        if !PathBuf::from(&installed.binary_path).exists() {
            return Err(LspError::UnknownServer(manifest.id.clone()));
        }

        let key = (project_id.to_string(), manifest.id.clone());
        if let Some(session) = self.sessions.read().await.get(&key) {
            return Ok(session.clone());
        }

        // Spawn outside the lock — initialize handshake can take seconds.
        let session =
            LspSession::spawn(&manifest, project_id.to_string(), project_root, self.sink.clone())
                .await?;

        let mut sessions = self.sessions.write().await;
        // Race window: another caller may have already inserted while we
        // were initializing. Keep theirs and quietly drop ours — both
        // sessions are equivalent, and the dropped one's `kill_on_drop`
        // tears the duplicate child down.
        if let Some(existing) = sessions.get(&key) {
            return Ok(existing.clone());
        }
        sessions.insert(key, session.clone());
        Ok(session)
    }

    /// Look up an existing session without spawning. Returns `None` if the
    /// caller never triggered an open.
    pub async fn get(&self, project_id: &str, server_id: &str) -> Option<Arc<LspSession>> {
        let key = (project_id.to_string(), server_id.to_string());
        self.sessions.read().await.get(&key).cloned()
    }

    /// Tear every session down. Called on `Service::shutdown`.
    pub async fn shutdown_all(&self) {
        let sessions: Vec<Arc<LspSession>> = self
            .sessions
            .write()
            .await
            .drain()
            .map(|(_, s)| s)
            .collect();
        for s in sessions {
            // Send shutdown/exit but don't hang on a misbehaving server —
            // the kill_on_drop fallback inside `LspSession::spawn` handles
            // the worst case.
            if tokio::time::timeout(std::time::Duration::from_secs(2), s.shutdown())
                .await
                .is_err()
            {
                warn!(server_id = %s.server_id, "lsp shutdown timed out");
            }
        }
    }
}
