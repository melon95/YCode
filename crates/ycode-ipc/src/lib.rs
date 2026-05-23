//! Typed IPC surface — the protocol between ycode-core and the webview.
//!
//! Under the terminal-first architecture the surface is small:
//!
//! | Command            | Behaviour                                              |
//! |--------------------|--------------------------------------------------------|
//! | `list_agents`      | Read [`Config`] and return registered profiles.        |
//! | `list_projects`    | All projects, newest first.                            |
//! | `create_project`   | Validate folder + persist; returns the new row.        |
//! | `delete_project`   | Removes the project iff no live sessions remain.       |
//! | `list_sessions`    | All non-archived sessions across projects.             |
//! | `create_session`   | Spawn PTY child, persist row; returns view.            |
//! | `write_pty`        | Forward bytes (typed input) to the PTY.                |
//! | `resize_pty`       | Update PTY geometry to match xterm.js.                 |
//! | `kill_session`     | Send SIGKILL to the child; row stays live.             |
//! | `archive_session`  | Kill + remove from DB list.                            |
//! | `restart_session`  | Kill existing PTY (if any) and spawn fresh.            |
//!
//! Events flow back through [`UiEvent`] on the channel `"ycode://session"`.

pub mod events;
pub mod service;

pub use events::{UiEvent, UiEventKind};
pub use service::{IpcError, Service};

use serde::{Deserialize, Serialize};
use ts_rs::TS;
use ycode_config::AgentLaunchProfile;
use ycode_persist::{ProjectRow, SessionRow};
use ycode_terminal::TerminalStatus;

/// Wire-format mirror of [`TerminalStatus`]. Kept here (rather than deriving
/// `TS` on the terminal crate's enum) so the terminal crate stays free of
/// frontend-binding concerns.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum SessionStatus {
    Running,
    Exited { code: Option<i32> },
    Error { message: String },
}

impl From<TerminalStatus> for SessionStatus {
    fn from(s: TerminalStatus) -> Self {
        match s {
            TerminalStatus::Running => SessionStatus::Running,
            TerminalStatus::Exited { code } => SessionStatus::Exited { code },
            TerminalStatus::Error { message } => SessionStatus::Error { message },
        }
    }
}

/// Frontend-facing snapshot of one session row.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SessionView {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub project_id: String,
    /// Runtime status. `Running` iff a live `TerminalSession` is currently
    /// driving this id; otherwise `Exited { code: last_exit_code }`.
    pub status: SessionStatus,
    /// Unix milliseconds.
    pub created_at_ms: i64,
    /// Unix milliseconds.
    pub updated_at_ms: i64,
    pub archived_at_ms: Option<i64>,
}

impl SessionView {
    /// Build a view from a DB row plus a hint about whether the runtime has
    /// a live PTY for it. Live ⇒ `Running`; otherwise the last recorded
    /// exit code (or a fallback `Exited { code: None }`).
    pub fn from_row(row: SessionRow, is_live: bool) -> Self {
        let status = if is_live {
            SessionStatus::Running
        } else {
            SessionStatus::Exited {
                code: row.last_exit_code.map(|c| c as i32),
            }
        };
        Self {
            id: row.id,
            title: row.title,
            agent_profile: row.agent_profile,
            project_id: row.project_id,
            status,
            created_at_ms: row.created_at,
            updated_at_ms: row.updated_at,
            archived_at_ms: row.archived_at,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct AgentProfileView {
    pub id: String,
    pub display_name: String,
    pub command: String,
    /// True iff `command` resolves on `PATH`. The picker hides unavailable
    /// agents (or shows them disabled).
    pub available: bool,
}

impl AgentProfileView {
    pub fn from_profile(profile: &AgentLaunchProfile, available: bool) -> Self {
        Self {
            id: profile.id.clone(),
            display_name: profile.display_name().to_string(),
            command: profile.command.clone(),
            available,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct CreateSessionRequest {
    pub agent_profile_id: String,
    pub project_id: String,
    pub title: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct CreateProjectRequest {
    pub name: String,
    pub repo_path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct RenameSessionRequest {
    pub session_id: String,
    pub title: String,
}

/// Frontend-facing snapshot of a project plus the count of its live sessions.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ProjectView {
    pub id: String,
    pub name: String,
    pub repo_path: String,
    pub created_at_ms: i64,
    pub session_count: i64,
}

impl ProjectView {
    pub fn from_row(row: ProjectRow, session_count: i64) -> Self {
        Self {
            id: row.id,
            name: row.name,
            repo_path: row.repo_path,
            created_at_ms: row.created_at,
            session_count,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct WritePtyRequest {
    pub session_id: String,
    /// Base64-encoded bytes. The webview encodes typed input + key sequences
    /// here so binary-safe transports work uniformly.
    pub data: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ResizePtyRequest {
    pub session_id: String,
    pub cols: u16,
    pub rows: u16,
}

/// Spawn a raw PTY not associated with any project session — used by the
/// second-terminal panel for ad-hoc shell commands. The returned id can be
/// used with `write_pty` / `resize_pty` / `kill_pty_raw`.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SpawnPtyRequest {
    pub cwd: String,
    pub command: String,
    pub args: Vec<String>,
}

/// One entry in the project file tree. `path` is forward-slash, relative to
/// the project repo root. Directories also appear as their own entry so the
/// frontend can build an expandable tree.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct FileEntry {
    pub path: String,
    pub is_dir: bool,
}

/// Contents of a single file as UTF-8. Binary files surface a `is_binary` flag
/// so the editor can refuse to open them instead of rendering garbage.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct FileContents {
    pub path: String,
    pub contents: String,
    pub is_binary: bool,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct WriteFileRequest {
    pub project_id: String,
    pub file_path: String,
    pub contents: String,
}
