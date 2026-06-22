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
pub mod mcp_listener;
pub mod notify_listener;
pub mod service;

pub use events::{UiEvent, UiEventKind};
pub use service::{IpcError, Service};

// Re-export the unified history types so the Tauri shell can wire them
// through `#[tauri::command]` without an extra crate dependency, and the
// ts-rs binding directory has them in one place.
pub use ycode_introspect::{
    DiffSummary, PlanStep, ToolStatus, UnifiedEvent, UnifiedEventKind, UnifiedRole,
};

// LSP types — same idea: the Tauri shell talks to them through the IPC
// crate so the binding directory stays the single source of truth.
pub use ycode_lsp::{
    AssetPattern, CommandSpec, InstallProgress, InstallSpec, InstallStage, ServerManifest,
};

use serde::{Deserialize, Serialize};
use ts_rs::TS;
use ycode_config::{AgentLaunchProfile, FontSizes, NotificationSettings};
use ycode_persist::{ProjectRow, SessionRow, TodoRow};
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
    /// Agent-native conversation id when known or generated for resume.
    pub agent_session_id: Option<String>,
    /// Agent-native title/thread label emitted by the CLI, when observed.
    pub agent_thread_name: Option<String>,
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
            agent_session_id: row.agent_session_id,
            agent_thread_name: row.agent_thread_name,
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
    /// Frontend `AgentIcon` whitelist key. Unknown / missing → placeholder.
    pub icon: Option<String>,
    /// "color" | "mono". Other values fall back to "color".
    pub icon_variant: Option<String>,
    /// Optional brand color hint (currently advisory).
    pub color: Option<String>,
    /// Introspect parser id ("claude" / "codex" today). `None` means PTY-only;
    /// such profiles are hidden from the sidebar's history filter tabs.
    pub introspect: Option<String>,
}

impl AgentProfileView {
    pub fn from_profile(profile: &AgentLaunchProfile, available: bool) -> Self {
        Self {
            id: profile.id.clone(),
            display_name: profile.display_name().to_string(),
            command: profile.command.clone(),
            available,
            icon: profile.icon.clone(),
            icon_variant: profile.icon_variant.clone(),
            color: profile.color.clone(),
            introspect: profile.introspect.clone(),
        }
    }
}

/// Editable mirror of [`AgentLaunchProfile`]. Carries every field the user
/// can change in the Settings UI (`args` / `env` included, unlike the
/// runtime [`AgentProfileView`] which only exposes display data).
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct AgentLaunchProfileView {
    pub id: String,
    pub display_name: Option<String>,
    pub command: String,
    pub args: Vec<String>,
    pub env: std::collections::BTreeMap<String, String>,
    pub icon: Option<String>,
    pub icon_variant: Option<String>,
    pub color: Option<String>,
    pub introspect: Option<String>,
}

impl From<AgentLaunchProfile> for AgentLaunchProfileView {
    fn from(p: AgentLaunchProfile) -> Self {
        Self {
            id: p.id,
            display_name: p.display_name,
            command: p.command,
            args: p.args,
            env: p.env,
            icon: p.icon,
            icon_variant: p.icon_variant,
            color: p.color,
            introspect: p.introspect,
        }
    }
}

impl From<AgentLaunchProfileView> for AgentLaunchProfile {
    fn from(v: AgentLaunchProfileView) -> Self {
        Self {
            id: v.id,
            display_name: v.display_name,
            command: v.command,
            args: v.args,
            env: v.env,
            icon: v.icon,
            icon_variant: v.icon_variant,
            color: v.color,
            introspect: v.introspect,
        }
    }
}

/// Editable mirror of [`ycode_config::Config`].
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ConfigView {
    pub agents: Vec<AgentLaunchProfileView>,
    pub font_sizes: FontSizesView,
    pub notifications: NotificationSettingsView,
    /// Active theme id. Mirrors the string from disk verbatim — the frontend
    /// looks it up in its theme registry and falls back to "foundry" when the
    /// id is unknown (lets future themes round-trip safely through older app
    /// versions).
    pub theme: String,
}

/// Editable mirror of [`ycode_config::NotificationSettings`].
#[derive(Clone, Copy, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct NotificationSettingsView {
    pub enabled: bool,
    pub only_when_unfocused: bool,
}

impl From<NotificationSettings> for NotificationSettingsView {
    fn from(n: NotificationSettings) -> Self {
        Self {
            enabled: n.enabled,
            only_when_unfocused: n.only_when_unfocused,
        }
    }
}

impl From<NotificationSettingsView> for NotificationSettings {
    fn from(v: NotificationSettingsView) -> Self {
        Self {
            enabled: v.enabled,
            only_when_unfocused: v.only_when_unfocused,
        }
    }
}

/// Editable mirror of [`ycode_config::FontSizes`]. Mirrored 1:1 — we only
/// duplicate the type so the ts-rs binding lives next to the rest of the
/// view types and stays a pure data envelope.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct FontSizesView {
    pub ui: u16,
    pub editor: u16,
    pub terminal: u16,
}

impl From<FontSizes> for FontSizesView {
    fn from(f: FontSizes) -> Self {
        Self {
            ui: f.ui,
            editor: f.editor,
            terminal: f.terminal,
        }
    }
}

impl From<FontSizesView> for FontSizes {
    fn from(v: FontSizesView) -> Self {
        Self {
            ui: v.ui,
            editor: v.editor,
            terminal: v.terminal,
        }
    }
}

impl From<ycode_config::Config> for ConfigView {
    fn from(c: ycode_config::Config) -> Self {
        Self {
            agents: c.agents.into_iter().map(Into::into).collect(),
            font_sizes: c.font_sizes.into(),
            notifications: c.notifications.into(),
            theme: c.theme,
        }
    }
}

impl From<ConfigView> for ycode_config::Config {
    fn from(v: ConfigView) -> Self {
        Self {
            agents: v.agents.into_iter().map(Into::into).collect(),
            font_sizes: v.font_sizes.into(),
            notifications: v.notifications.into(),
            theme: v.theme,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct CreateSessionRequest {
    pub agent_profile_id: String,
    pub project_id: String,
    pub title: String,
    /// When set, the freshly-spawned CLI is launched with `--resume <id>`
    /// (claude) / `resume <id>` (codex) so it loads the existing on-disk
    /// session jsonl as context. Used when the user clicks a row in the
    /// sidebar's "History" panel.
    #[serde(default)]
    pub resume: Option<String>,
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

/// Frontend-facing snapshot of a single todo item.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct TodoView {
    pub id: String,
    pub project_id: String,
    pub title: String,
    /// One of `todo` / `doing` / `done`.
    pub status: String,
    pub sort_order: i64,
    /// When the todo most recently entered `doing` (unix ms), or `None`.
    pub started_at_ms: Option<i64>,
    /// When the todo most recently entered `done` (unix ms), or `None`.
    pub done_at_ms: Option<i64>,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

impl TodoView {
    pub fn from_row(row: TodoRow) -> Self {
        Self {
            id: row.id,
            project_id: row.project_id,
            title: row.title,
            status: row.status,
            sort_order: row.sort_order,
            started_at_ms: row.started_at,
            done_at_ms: row.done_at,
            created_at_ms: row.created_at,
            updated_at_ms: row.updated_at,
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
///
/// `cols`/`rows` set the PTY's initial geometry. They're optional only for
/// backward compat; in practice every caller should pass real fitted values.
/// Opening the PTY at the wrong size and then sending `resize_pty` races
/// shell startup: the SIGWINCH from the resize can land before the shell
/// has installed its handler (default action: ignore), so the shell keeps
/// `COLUMNS` at the initial size and renders its first prompt at the wrong
/// width. VS Code / Hyper / Tabby all dodge this by passing dimensions at
/// spawn time; see hermes-hq/hermes-ide#113 for the canonical write-up.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SpawnPtyRequest {
    pub cwd: String,
    pub command: String,
    pub args: Vec<String>,
    #[serde(default)]
    #[ts(optional)]
    pub cols: Option<u16>,
    #[serde(default)]
    #[ts(optional)]
    pub rows: Option<u16>,
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

/// Request payload for `fs_open_in_external_editor`. `editor` is optional;
/// when absent we fall back to `$VISUAL`, then `$EDITOR`, then a sensible
/// platform default. Per plan §8.15.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct OpenInExternalEditorRequest {
    pub path: String,
    pub editor: Option<String>,
}

/// Overwrite a project file with new UTF-8 contents. Path traversal escaping
/// the repo is rejected — same enforcement as `read_file`.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct WriteFileRequest {
    pub project_id: String,
    pub file_path: String,
    pub contents: String,
}

/// Working-tree status of a file relative to its index entry. We only surface
/// the unstaged side here — staged changes are deliberately ignored by the
/// "Changes" panel per product decision. `Renamed` only fires when the rename
/// happens in the working tree (rare; typical rename is index-side).
#[derive(Clone, Debug, Serialize, Deserialize, TS, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
#[ts(export)]
pub enum GitFileStatus {
    Modified,
    Deleted,
    Untracked,
    /// Catch-all for status codes we don't classify (`T` type-change, etc).
    Other,
}

/// One row in the "Changes" panel. `additions`/`deletions` come from
/// `git diff --numstat` for tracked files; untracked files report `additions`
/// = line count and `deletions` = 0.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct GitFileChange {
    /// Repo-relative path, forward-slash separated.
    pub path: String,
    pub status: GitFileStatus,
    pub additions: u32,
    pub deletions: u32,
}

/// One row in the "Sessions" sidebar — describes a session jsonl that the
/// introspect scanner found on disk. Per plan §9.1.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct DiscoveredSessionView {
    /// "claude" / "codex".
    pub agent: String,
    /// Native session UUID. `None` when the file is malformed.
    pub session_id: Option<String>,
    /// Absolute path to the jsonl file.
    pub jsonl_path: String,
    /// Bytes — useful to flag huge sessions to the UI.
    pub size_bytes: u64,
    /// Unix milliseconds — file mtime, used to sort the sidebar.
    pub modified_at_ms: i64,
    /// Human-readable title derived from the session's first user message
    /// (or claude `summary` event). `None` when the file is too new / has
    /// no user message yet. The sidebar shows this when present, falling
    /// back to a short session id.
    pub title: Option<String>,
}

/// Search hit returned from the cross-session query. Per plan §8.13.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SearchHit {
    pub agent: String,
    pub session_id: String,
    pub jsonl_path: String,
    pub seq: u64,
    pub ts_ms: i64,
    pub preview: String,
}

// --- Token usage views ---------------------------------------------------
//
// Numeric fields are `f64` on purpose: token counts and timestamps are
// integers, but typing them as `i64`/`u64` makes ts-rs emit `bigint`, forcing
// a retype layer in the frontend. These are read-only display DTOs delivered
// as JSON numbers anyway, and the magnitudes (token counts, unix-millis) sit
// well within f64's exact-integer range, so `f64 -> number` is both correct
// and frictionless here.

/// Token counters for a usage rollup. `reasoning` is a subset of `output`
/// (Codex reasoning tokens), kept for display only and excluded from `total`.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct TokenCountsView {
    pub input: f64,
    pub output: f64,
    pub cache_creation: f64,
    pub cache_read: f64,
    pub reasoning: f64,
    pub total: f64,
}

/// One session's usage row in the usage table.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct SessionUsageView {
    pub agent: String,
    pub session_id: Option<String>,
    pub title: Option<String>,
    pub jsonl_path: String,
    /// Dominant model (the one accounting for the most tokens).
    pub model: Option<String>,
    pub tokens: TokenCountsView,
    pub cost_usd: f64,
    pub first_ts_ms: f64,
    pub last_ts_ms: f64,
    pub message_count: f64,
}

/// Usage grouped by model across the workspace.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ModelUsageView {
    pub model: String,
    pub tokens: TokenCountsView,
    pub cost_usd: f64,
}

/// Usage grouped by calendar day (UTC, `YYYY-MM-DD`).
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct DailyUsageView {
    pub date: String,
    pub tokens: TokenCountsView,
    pub cost_usd: f64,
}

/// Usage rolled up for one registered project. Only populated by the
/// cross-project view (`get_all_usage`); the single-project view returns an
/// empty `by_project`.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct ProjectUsageView {
    pub project_id: String,
    pub name: String,
    pub tokens: TokenCountsView,
    pub cost_usd: f64,
    pub session_count: f64,
}

/// Everything the Usage screen renders for one workspace. Costs are offline
/// estimates (known model families only); see `ycode_introspect::usage`.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct WorkspaceUsageView {
    pub totals: TokenCountsView,
    pub total_cost_usd: f64,
    pub sessions: Vec<SessionUsageView>,
    pub by_model: Vec<ModelUsageView>,
    pub by_day: Vec<DailyUsageView>,
    /// Per-project breakdown. Empty for the single-project view.
    pub by_project: Vec<ProjectUsageView>,
}

/// Frontend-facing snapshot of one language server: its built-in manifest
/// merged with the user's local install state. The Settings → Languages
/// page renders one card per entry.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct LspManifestView {
    pub manifest: ServerManifest,
    /// `None` until the user installs this server.
    pub installation: Option<LspInstallationView>,
    /// False on platforms the manifest doesn't list an asset for. The UI
    /// shows the card disabled with an "Unsupported on this platform" hint.
    pub platform_supported: bool,
    /// False when an external dependency is missing (e.g. `npm` not on
    /// PATH for npm-based installers). The UI surfaces the message so the
    /// user knows what to install first.
    pub requirement_message: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct LspInstallationView {
    pub version: String,
    pub binary_path: String,
    pub installed_at_ms: i64,
}

impl From<ycode_persist::LspInstallationRow> for LspInstallationView {
    fn from(row: ycode_persist::LspInstallationRow) -> Self {
        Self {
            version: row.version,
            binary_path: row.binary_path,
            installed_at_ms: row.installed_at,
        }
    }
}
