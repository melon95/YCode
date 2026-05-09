//! Frontend-facing event payloads.
//!
//! `UiEvent` is the single channel the Tauri shell emits to the webview.
//! It always carries `session_id` so the webview can route to the right
//! pane regardless of which broadcast channel the shell uses internally.

use serde::{Deserialize, Serialize};
use ts_rs::TS;
use ycode_adapter::AgentEvent;

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[ts(export)]
pub struct UiEvent {
    pub session_id: String,
    pub kind: UiEventKind,
}

#[derive(Clone, Debug, Serialize, Deserialize, TS)]
#[serde(tag = "type")]
#[ts(export)]
pub enum UiEventKind {
    /// A new session row appeared (e.g. another tab created one). Sent on
    /// create_session and after restart.
    SessionAppeared,
    /// Existing session row's state or metadata changed. Webview should
    /// re-fetch via `list_sessions` if it needs the full row.
    SessionTouched,
    /// Session row went away (archived).
    SessionRemoved,
    /// One adapter event for a session — rendered into the log pane.
    Agent { event: AgentEvent },
}

impl UiEvent {
    pub fn agent(session_id: impl Into<String>, event: AgentEvent) -> Self {
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::Agent { event },
        }
    }
}
