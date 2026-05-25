//! Parse and normalise CLI agent jsonl session files.
//!
//! Per plan §5.5 the source of truth for historical conversation content is
//! each CLI's own append-only jsonl (`~/.claude/projects/...`,
//! `~/.codex/sessions/...`). This crate exposes:
//!
//! * [`AgentBackend`] — locating, scanning, and parsing one agent's data
//! * Per-agent native event types (`claude::RawEvent`, `codex::RawEvent`)
//! * [`UnifiedEvent`] — a single shape both backends normalise into, so the
//!   frontend renders one component tree regardless of source agent
//!
//! Adding a new agent is a matter of implementing `AgentBackend` + a parser
//! + a `normalize_into_unified` mapping.

pub mod claude;
pub mod codex;
pub mod scanner;
pub mod unified;

pub use unified::{
    DiffSummary, PlanStep, ToolStatus, UnifiedEvent, UnifiedEventKind, UnifiedRole,
};

use std::path::{Path, PathBuf};

/// Concrete agent that produces jsonl session files we can read. Each impl
/// is stateless — instantiated once and shared. Per plan §5.5.1.
pub trait AgentBackend: Send + Sync {
    /// Stable string id ("claude" / "codex"). Drives DB rows and event tags.
    fn name(&self) -> &'static str;

    /// Root directory under `$HOME` where this agent stores sessions.
    /// `None` if the agent has no on-disk session store (defensive — every
    /// shipping backend should return Some).
    fn sessions_root(&self, home: &Path) -> Option<PathBuf>;

    /// Resolve a workspace cwd to the directory holding its session files.
    /// Returns `None` if this agent organises by date (codex) — callers
    /// must use [`AgentBackend::scan_workspaces`] instead.
    fn workspace_dir(&self, _home: &Path, _cwd: &Path) -> Option<PathBuf> {
        None
    }
}

/// One scanned session file before parsing.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DiscoveredSession {
    pub agent: &'static str,
    pub jsonl_path: PathBuf,
    /// Native session UUID extracted from the file. None when the file is
    /// malformed / not yet flushed past the first record.
    pub session_id: Option<String>,
    /// Workspace cwd this session belongs to.
    pub cwd: Option<PathBuf>,
    /// One-line summary built from the session's first user message (or
    /// claude `summary` event). Used as the human-readable title in the UI
    /// sidebar so users see "Refactor auth middleware" instead of a UUID.
    /// `None` when no meaningful first-message text is yet on disk.
    pub title: Option<String>,
}

#[derive(thiserror::Error, Debug)]
pub enum IntrospectError {
    #[error("io: {0}")]
    Io(String),

    #[error("parse: {0}")]
    Parse(String),
}
