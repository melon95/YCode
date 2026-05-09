//! `AgentEvent` and its supporting types.
//!
//! `AgentEvent` is a superset of every signal any adapter might emit. ACP
//! adapters emit the structured variants; PTY adapters emit `RawOutput` and
//! `HeuristicState`. Both kinds emit `StateChanged`, `AssistantText`,
//! `RequestPermission`, and `Error`.

use crate::state::SessionState;
use serde::{Deserialize, Serialize};
use ts_rs::TS;

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "kind")]
#[ts(export)]
pub enum AgentEvent {
    /// Lifecycle transition. The orchestrator validates and persists.
    StateChanged { state: SessionState },

    /// A chunk of assistant prose. ACP delivers via `content_chunk`/
    /// `agent_message_chunk`; PTY adapters synthesize from cleaned output.
    /// `final_chunk` is `true` when the assistant message block ends.
    AssistantText {
        chunk_id: String,
        text: String,
        final_chunk: bool,
    },

    /// Echo of the user's prompt for adapters that surface it (PTY agents
    /// often render the prompt back into the terminal). ACP adapters typically
    /// don't emit this.
    UserEcho { text: String },

    // -- Structured ACP-only events --
    /// A tool call has begun. `args_preview` is a short, human-readable
    /// summary; full args are not pushed through the event stream.
    ToolCallStarted {
        id: String,
        name: String,
        args_preview: String,
        locations: Vec<FileLoc>,
    },

    /// Tool call status update or output streaming.
    ToolCallUpdated {
        id: String,
        status: ToolStatus,
        output_preview: Option<String>,
    },

    /// Agent's current plan (ACP `plan` updates).
    Plan { items: Vec<PlanItem> },

    /// Slash commands the agent advertises in this session.
    AvailableCommands { commands: Vec<AgentCommand> },

    /// Agent switched modes (e.g. plan/edit modes in some agents).
    ModeChanged { mode_id: String },

    // -- Permission round-trip (both ACP and PTY use this) --
    /// Adapter is asking the user to approve/reject a tool action. The
    /// orchestrator routes this to the UI and answers via
    /// [`AgentAdapter::answer_permission`](super::AgentAdapter::answer_permission).
    RequestPermission {
        request_id: String,
        tool_name: String,
        summary: String,
        options: Vec<PermissionOption>,
    },

    // -- PTY-only events --
    /// Raw bytes from the PTY, vt100-stripped if the adapter is configured
    /// with `clean_text: true`. Truncated to ~64 KiB per row by the persist
    /// layer.
    RawOutput { bytes: Vec<u8> },

    /// Heuristic state label inferred from output patterns. Examples:
    /// `"waiting_for_y_n"`, `"running"`. Used by the UI for status colour
    /// when structured state isn't available.
    HeuristicState { label: String },

    // -- Errors --
    /// Non-fatal warnings use this with `fatal: false`. Fatal errors push the
    /// session into `SessionState::Error`.
    Error { message: String, fatal: bool },
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum ToolStatus {
    Pending,
    Running,
    Completed,
    Failed,
    Cancelled,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct FileLoc {
    pub path: String,
    pub line: Option<u32>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct PlanItem {
    pub id: String,
    pub title: String,
    pub status: ToolStatus,
    /// 0 = highest priority. Roughly maps to ACP plan priorities.
    pub priority: u8,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct AgentCommand {
    pub name: String,
    pub description: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct PermissionOption {
    pub option_id: String,
    pub name: String,
    pub kind: PermissionKind,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum PermissionKind {
    AllowOnce,
    AllowAlways,
    RejectOnce,
    RejectAlways,
}
