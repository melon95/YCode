//! Row types as they live in SQLite.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct SessionRow {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub agent_session_id: Option<String>,
    pub agent_thread_name: Option<String>,
    pub project_id: String,
    /// Last observed exit code. `None` while the session has never exited
    /// (either still alive, or the row was just inserted). `Some(code)` is
    /// set by the IPC layer when the child terminates.
    pub last_exit_code: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
    pub archived_at: Option<i64>,
    /// Absolute path of this session's isolated git worktree, or `None` when
    /// the session shares the project's main working tree (isolation off).
    pub worktree_path: Option<String>,
    /// The session's dedicated branch (`ycode/<short-id>`) when isolated.
    pub branch: Option<String>,
    /// The branch the worktree was forked from, used to merge it back.
    pub base_branch: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct ProjectRow {
    pub id: String,
    pub name: String,
    pub repo_path: String,
    pub created_at: i64,
    /// When true, each new session in this project runs in its own git
    /// worktree; when false, sessions share the project's main working tree.
    pub isolate_sessions: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct TodoRow {
    pub id: String,
    pub project_id: String,
    pub title: String,
    /// One of `todo` / `doing` / `done`. Validated at the repo layer.
    pub status: String,
    pub sort_order: i64,
    /// When the todo most recently entered the `doing` status. `None` until it
    /// has ever been `doing`.
    pub started_at: Option<i64>,
    /// When the todo most recently entered the `done` status. `None` until it
    /// has ever been `done`.
    pub done_at: Option<i64>,
    pub created_at: i64,
    pub updated_at: i64,
}
