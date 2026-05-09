//! Row types as they live in SQLite.
//!
//! These are deliberately separate from `ycode-adapter::AgentEvent` /
//! `SessionState`: the persist layer converts between rows and domain types
//! through the repo methods. Keep the boundary clean so DB changes don't
//! leak into the domain.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct SessionRow {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_ref: String,
    /// JSON-encoded `SessionState`.
    pub state: String,
    pub created_at: i64,
    pub updated_at: i64,
    pub archived_at: Option<i64>,
}

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct EventRow {
    pub id: i64,
    pub session_id: String,
    pub seq: i64,
    pub ts: i64,
    /// JSON-encoded `AgentEvent`.
    pub payload: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct PermissionRow {
    pub request_id: String,
    pub session_id: String,
    pub tool_name: String,
    pub summary: String,
    /// JSON-encoded `Vec<PermissionOption>`.
    pub options_json: String,
    pub decided_option: Option<String>,
    pub decided_at: Option<i64>,
    pub created_at: i64,
}
