//! The `AgentAdapter` contract — the load-bearing abstraction in ycode.
//!
//! Every CLI agent integration (Claude Code, Gemini CLI, Codex, ...) implements
//! this trait. The trait deliberately mentions neither ACP nor PTY: both
//! protocols are downstream details. The orchestrator holds adapters as
//! `Box<dyn AgentAdapter>` and never branches on the concrete type.
//!
//! ## Design tension and resolution
//!
//! ACP yields structured events (`tool_call`, `request_permission`, `plan`);
//! a PTY yields bytes that may or may not parse cleanly. The naive resolutions
//! are both bad:
//!
//! - Trait shaped around ACP → PTY adapters become escape-hatch hacks.
//! - Trait shaped around bytes → ACP loses its semantic edge.
//!
//! ycode resolves this by making `AgentEvent` a **superset enum** with first-
//! class variants for both worlds, and exposing a [`Capabilities`] struct so
//! the orchestrator and UI know which variants to expect. PTY-only variants
//! (`RawOutput`, `HeuristicState`) are first-class, not afterthoughts; ACP
//! adapters simply never emit them. The cost-of-adding-a-new-CLI gate (S6 in
//! the verification plan) is the operational test that this design holds.

mod events;
mod state;
mod transcript;

pub use events::{
    AgentCommand, AgentEvent, FileLoc, PermissionKind, PermissionOption, PlanItem, ToolStatus,
};
pub use state::{Capabilities, SessionState, StopReason};
pub use transcript::Transcript;

use async_trait::async_trait;
use camino::Utf8PathBuf;
use std::sync::Arc;
use thiserror::Error;
use tokio::sync::mpsc;

/// Everything an adapter needs to spawn its agent.
///
/// The `cwd` is always the resolved git worktree path — adapters should treat
/// it as the root of the agent's filesystem world. Adapters MUST NOT spawn
/// children outside `cwd`.
#[derive(Clone, Debug)]
pub struct SpawnSpec {
    pub cwd: Utf8PathBuf,
    pub env: Vec<(String, String)>,
    pub command: String,
    pub args: Vec<String>,
}

/// Channel an adapter writes events into. The orchestrator owns the receiver.
pub type EventSender = mpsc::Sender<AgentEvent>;

/// The contract every CLI agent integration implements.
///
/// Lifecycle invariants the orchestrator relies on:
/// - The session is created in `Initializing`. `start` MUST emit
///   `StateChanged(Idle)` (or a fatal `Error`) once handshake is done — that
///   transition is what signals readiness to the orchestrator.
/// - `prompt`, `cancel`, `answer_permission`, `shutdown` return immediately;
///   results stream via the event channel.
/// - `shutdown` MUST be idempotent.
/// - Adapters MUST NOT emit `SessionState` transitions that the orchestrator
///   would reject (see `ycode-core::session::Session::apply`); the orchestrator
///   validates and demotes invalid transitions to `Error`, but well-behaved
///   adapters should not rely on that.
#[async_trait]
pub trait AgentAdapter: Send + Sync + 'static {
    /// Stable identifier for diagnostics and logs (e.g. `"acp"`, `"pty-codex"`).
    /// NOT a user-facing label — that comes from the agent profile.
    fn name(&self) -> &'static str;

    /// What this adapter is capable of producing. Read by the orchestrator and
    /// the UI to gate features. MUST be constant for the lifetime of the
    /// adapter.
    fn capabilities(&self) -> Capabilities;

    /// Spawn the agent process and complete handshake. The adapter retains the
    /// sender and writes events into it for the rest of the session.
    async fn start(
        &mut self,
        spec: SpawnSpec,
        events_tx: EventSender,
    ) -> Result<(), AdapterError>;

    /// Send a user prompt. Returns immediately; turn results stream as events.
    async fn prompt(&mut self, text: String) -> Result<(), AdapterError>;

    /// Reply to a previously emitted [`AgentEvent::RequestPermission`].
    ///
    /// For ACP adapters: forwarded as the response to the agent's
    /// `session/request_permission` JSON-RPC call.
    ///
    /// For PTY adapters: translated by the heuristic profile into keystrokes
    /// (e.g. `option_id="allow_once"` → `"y\r"`).
    async fn answer_permission(
        &mut self,
        request_id: String,
        option_id: String,
    ) -> Result<(), AdapterError>;

    /// Cooperative cancel. ACP: `session/cancel` notification. PTY: `\x03`
    /// (SIGINT) followed by escalation if the process doesn't exit within a
    /// short timeout.
    async fn cancel(&mut self) -> Result<(), AdapterError>;

    /// Hard stop and resource cleanup. MUST be idempotent: callers may invoke
    /// it during normal shutdown AND from a Drop-style cleanup path.
    async fn shutdown(&mut self) -> Result<(), AdapterError>;
}

/// Boxed handle the orchestrator stores. Use this as `Box<dyn AgentAdapter>` so
/// the trait can stay object-safe without forcing every consumer to write the
/// `Send + Sync + 'static` bounds.
pub type BoxedAdapter = Box<dyn AgentAdapter>;

/// Factory function shape that constructs adapters from configuration. The
/// orchestrator holds a registry keyed by `agent_profile.kind`.
pub type AdapterFactory =
    Arc<dyn Fn() -> Result<BoxedAdapter, AdapterError> + Send + Sync + 'static>;

#[derive(Error, Debug)]
pub enum AdapterError {
    #[error("spawn failed: {0}")]
    Spawn(String),

    #[error("transport error: {0}")]
    Transport(String),

    #[error("protocol error: {0}")]
    Protocol(String),

    #[error("agent process crashed (exit code {0:?})")]
    Crashed(Option<i32>),

    #[error("permission request {request_id} not found or already answered")]
    UnknownPermission { request_id: String },

    #[error("operation rejected in current state: {0}")]
    InvalidState(&'static str),

    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("{0}")]
    Other(String),
}
