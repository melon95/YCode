//! Frontend-facing event payloads.
//!
//! `UiEvent` is the single channel the Tauri shell emits to the webview.
//! It always carries `session_id` so the webview can route to the right
//! pane regardless of which broadcast channel the shell uses internally.

use serde::{Deserialize, Serialize};
use ts_rs::TS;

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
    /// A new session row appeared. Sent by `create_session`.
    SessionAppeared,
    /// Existing session row's metadata changed (e.g. exit code recorded).
    /// Webview should re-fetch via `list_sessions` for the full row.
    SessionTouched,
    /// Session row went away (archived).
    SessionRemoved,
    /// A new project row appeared. `session_id` carries the project id —
    /// the wire shape stays uniform across membership events.
    ProjectAppeared,
    /// Project row went away.
    ProjectRemoved,
    /// One chunk of PTY output. `data` is base64-encoded raw bytes from the
    /// child — pass through to xterm.js after decoding.
    PtyOutput { data: String },
    /// Child process exited. `code` is `None` for signal-terminated.
    PtyExit { code: Option<i32> },
}

impl UiEvent {
    pub fn pty_output(session_id: impl Into<String>, bytes: &[u8]) -> Self {
        use base64::Engine;
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::PtyOutput {
                data: base64::engine::general_purpose::STANDARD.encode(bytes),
            },
        }
    }

    pub fn pty_exit(session_id: impl Into<String>, code: Option<i32>) -> Self {
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::PtyExit { code },
        }
    }
}
