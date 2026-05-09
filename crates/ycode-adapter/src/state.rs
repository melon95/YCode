//! `SessionState`, `Capabilities`, and `StopReason`.
//!
//! These types are exported to the frontend via ts-rs so the Svelte stores can
//! pattern-match on them with full type safety.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

/// Adapters declare their capabilities at construction time. The orchestrator
/// and UI gate features on these flags rather than sniffing event variants.
///
/// Concretely: a PTY adapter advertises `structured_permissions: false`, and
/// the UI then renders the permission modal in a "this is a heuristic match,
/// review the surrounding output" mode rather than the structured-tool form.
#[derive(Clone, Copy, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct Capabilities {
    /// Adapter emits [`AssistantText`](super::AgentEvent::AssistantText) chunks.
    pub streaming_text: bool,

    /// Adapter emits structured `ToolCallStarted`/`ToolCallUpdated` events.
    /// PTY adapters must set this to `false`.
    pub structured_tool_calls: bool,

    /// Adapter intercepts tool calls *before* execution and emits a structured
    /// `RequestPermission`. PTY adapters set this to `false`; they may still
    /// emit `RequestPermission` from heuristic matches, but the UI labels it
    /// as a best-effort interception.
    pub structured_permissions: bool,

    /// Adapter emits `Plan` updates.
    pub plans: bool,

    /// Adapter supports cooperative cancel.
    pub cancel: bool,

    /// Adapter supports `session/set_mode` (ACP modes feature).
    pub modes: bool,
}

impl Capabilities {
    /// What an ACP-conforming adapter advertises.
    pub const ACP: Self = Self {
        streaming_text: true,
        structured_tool_calls: true,
        structured_permissions: true,
        plans: true,
        cancel: true,
        modes: true,
    };

    /// What a PTY/screen-scraping adapter advertises. Heuristic permission
    /// interception is a UX nicety, not a structured contract — hence
    /// `structured_permissions: false`.
    pub const PTY: Self = Self {
        streaming_text: true,
        structured_tool_calls: false,
        structured_permissions: false,
        plans: false,
        cancel: true,
        modes: false,
    };
}

/// Lifecycle state of a session. Adapters emit
/// [`StateChanged`](super::AgentEvent::StateChanged) to announce transitions;
/// the orchestrator validates that the transition is allowed before committing
/// it to the session row.
///
/// See `ycode-core::session::Session::apply` for the transition matrix.
#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum SessionState {
    /// Adapter is launching the agent process and completing handshake.
    Initializing,

    /// Agent is ready and waiting for a prompt.
    Idle,

    /// Agent is processing a prompt. `turn_id` lets the UI correlate streaming
    /// events back to a specific turn.
    Running { turn_id: String },

    /// Agent paused mid-turn awaiting user permission for a tool call. The UI
    /// shows the modal; calling
    /// [`answer_permission`](super::AgentAdapter::answer_permission) resumes.
    AwaitingPermission {
        request_id: String,
        tool: String,
        summary: String,
    },

    /// Cancel was requested; we're waiting for the agent to wind down. Next
    /// state is `Done { stop_reason: Cancelled }` (or `Error` on timeout).
    Cancelling,

    /// Turn finished normally. The session can return to `Idle` for another
    /// turn (via a fresh `prompt` call) or be archived.
    Done { stop_reason: StopReason },

    /// Fatal error. The adapter has either crashed or violated protocol.
    /// Recovery requires `restart_session` (which spawns a fresh adapter).
    Error { message: String },
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum StopReason {
    /// Agent decided the turn was complete.
    EndTurn,
    /// Hit token / output budget.
    MaxTokens,
    /// User cancelled mid-turn.
    Cancelled,
    /// Agent refused (safety / policy).
    Refusal,
    /// Catch-all for protocol-specific reasons we don't model.
    Other { detail: String },
}
