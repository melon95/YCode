//! Typed IPC surface — the protocol between ycode-core and the webview.
//!
//! The Tauri shell crate wraps each [`Service`] method as a `#[tauri::command]`
//! and forwards [`UiEvent`]s to the webview via `app_handle.emit_all`. By
//! keeping the surface in a plain Rust crate (no `tauri` dep), we can:
//!
//! - Generate TypeScript bindings via `ts-rs` for frontend type safety.
//! - Drive the same surface from non-Tauri callers (CLI, IDE plugins).
//! - Test commands without Tauri runtime overhead.
//!
//! ## Surface
//!
//! | Command            | Behaviour                                              |
//! |--------------------|--------------------------------------------------------|
//! | `list_agents`      | Read [`Config`] and return registered profiles.        |
//! | `list_sessions`    | DB rows + live flag (merged via `SessionManager`).     |
//! | `create_session`   | Spawn a new session; returns the new id.               |
//! | `send_prompt`      | Forward a prompt to a live session.                    |
//! | `answer_permission`| Reply to an outstanding `AwaitingPermission`.          |
//! | `cancel_session`   | Cooperative cancel.                                    |
//! | `archive_session`  | Shut down + remove worktree + archive in DB.           |
//! | `restart_session`  | Replace the dormant adapter with a fresh one.          |
//! | `replay_events`    | Backfill transcript from `seq` onward.                 |
//!
//! ## Events
//!
//! [`UiEvent`] is the single fan-out type. The Tauri shell emits these on
//! the channel `"ycode://session"` (or per-session channels — implementation
//! detail of the shell). The frontend pattern-matches on the `kind` tag.

pub mod events;
pub mod service;

pub use events::{UiEvent, UiEventKind};
pub use service::{IpcError, Service};

use serde::{Deserialize, Serialize};
use ts_rs::TS;
use ycode_adapter::SessionState;
use ycode_config::AgentLaunchProfile;
use ycode_persist::SessionRow;

/// Frontend-facing snapshot of one session row, parsed and lightly enriched.
/// Mirrors `ycode_core::SessionRecord` but with `state` already deserialized
/// so the webview doesn't need to re-parse.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SessionView {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_ref: String,
    pub state: SessionState,
    /// Unix milliseconds.
    pub created_at_ms: i64,
    /// Unix milliseconds.
    pub updated_at_ms: i64,
    pub archived_at_ms: Option<i64>,
    /// True iff a live `SessionRunner` is currently driving this row.
    pub is_live: bool,
}

impl SessionView {
    pub fn from_row(row: SessionRow, is_live: bool) -> Self {
        let state: SessionState = serde_json::from_str(&row.state).unwrap_or(SessionState::Error {
            message: format!("malformed state JSON: {}", row.state),
        });
        Self {
            id: row.id,
            title: row.title,
            agent_profile: row.agent_profile,
            repo_root: row.repo_root,
            worktree_path: row.worktree_path,
            branch: row.branch,
            base_ref: row.base_ref,
            state,
            created_at_ms: row.created_at,
            updated_at_ms: row.updated_at,
            archived_at_ms: row.archived_at,
            is_live,
        }
    }
}

/// Frontend-facing view of a configured agent profile. The `command`/`args`/
/// `env` fields are intentionally NOT exposed — those are launch-time
/// concerns and exposing them via IPC would let the webview poke holes in
/// process semantics.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct AgentProfileView {
    pub id: String,
    pub display_name: String,
    pub kind: String,
}

impl AgentProfileView {
    pub fn from_profile(profile: &AgentLaunchProfile) -> Self {
        let kind = match profile.kind {
            ycode_config::AdapterKind::Acp => "acp",
            ycode_config::AdapterKind::Pty => "pty",
            ycode_config::AdapterKind::Echo => "echo",
        }
        .to_string();
        Self {
            id: profile.id.clone(),
            display_name: profile.display_name().to_string(),
            kind,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct CreateSessionRequest {
    pub agent_profile_id: String,
    pub repo_path: String,
    pub title: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SendPromptRequest {
    pub session_id: String,
    pub text: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct AnswerPermissionRequest {
    pub session_id: String,
    pub request_id: String,
    pub option_id: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ReplayRequest {
    pub session_id: String,
    /// Replay events with `seq >= from_seq`. 0 returns the full transcript.
    pub from_seq: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ReplayEntry {
    pub seq: i64,
    pub ts_ms: i64,
    pub event: ycode_adapter::AgentEvent,
}
