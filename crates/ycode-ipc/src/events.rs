//! Frontend-facing event payloads.
//!
//! `UiEvent` is the single channel the Tauri shell emits to the webview.
//! It always carries `session_id` so the webview can route to the right
//! pane regardless of which broadcast channel the shell uses internally.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use ts_rs::TS;
use ycode_lsp::{InstallProgress, InstallStage};

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
    /// The todo list for a project changed (added / edited / status-flipped /
    /// deleted) — either from the UI or via the MCP control socket.
    /// `session_id` carries the affected project id; the webview re-fetches
    /// via `list_todos` when the project is the active one.
    TodosChanged,
    /// One chunk of PTY output. `data` is base64-encoded raw bytes from the
    /// child — pass through to xterm.js after decoding.
    PtyOutput { data: String },
    /// Child process exited. `code` is `None` for signal-terminated.
    PtyExit { code: Option<i32> },
    /// The CLI emitted an `OSC 0/1/2;<title>` window-title sequence. The UI
    /// uses this as the live session label, falling back to the persisted
    /// `title` when absent.
    TitleChanged { title: String },
    /// One of the jsonl session files for the active workspace was written
    /// to or appeared. Carries the absolute path so HistoryTab can invalidate
    /// its in-memory cache and re-fetch via `load_session_history`. Per plan
    /// §6.2.5 (real-time tail of active session).
    JsonlChanged { agent: String, jsonl_path: String },
    /// The agent CLI running in this terminal signalled that it finished a
    /// turn / is waiting for the user. Emitted by the `NotifyListener` when
    /// the helper binary (Claude `Stop` hook, Codex `notify`) connects.
    /// `session_id` is the same terminal id we set as `YCODE_TERMINAL_ID`
    /// when spawning the PTY. The Tauri shell decides whether to surface a
    /// system notification (typically: only when the window is unfocused).
    AgentTurnComplete {
        /// Identifier of the CLI that fired the event — "claude", "codex",
        /// or "unknown" when the helper was invoked without a source arg.
        source: String,
        /// Specific event sub-kind from the hook: "stop" / "notification" /
        /// "turn_complete". Lets the UI distinguish "done" from "needs
        /// permission" without inspecting `source`.
        event_kind: String,
        /// Short snippet of the last assistant message extracted from the
        /// hook payload (Codex notify JSON's `last-assistant-message` field,
        /// Claude's transcript jsonl tail). Truncated to ~200 chars before
        /// emission so the renderer can drop it straight into the toast.
        /// `None` when extraction failed (file missing, unknown agent, etc.)
        /// — the Tauri shell falls back to the generic "finished its turn"
        /// body.
        body_preview: Option<String>,
    },
    /// Progress update from an in-flight LSP install. `session_id` carries
    /// the manifest id so the Settings card can correlate. Streamed by the
    /// installer through the same broadcast bus as everything else.
    LspInstallProgress {
        stage: InstallStage,
        percent: Option<u8>,
        message: String,
    },
    /// Terminal events for an LSP install. `outcome` reports the version
    /// label on success, or the error string on failure. The Settings UI
    /// uses this to refresh `lsp_list_manifests` and surface a toast.
    LspInstallFinished {
        ok: bool,
        version: Option<String>,
        error: Option<String>,
    },
    /// Server was uninstalled — UI should refresh its list.
    LspUninstalled,
    /// `textDocument/publishDiagnostics` passed through from a running
    /// language server. `params` is the raw LSP payload — the frontend
    /// decides how (or whether) to render it.
    LspDiagnostics {
        server_id: String,
        uri: String,
        #[ts(type = "unknown")]
        params: Value,
    },
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

    pub fn title_changed(session_id: impl Into<String>, title: String) -> Self {
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::TitleChanged { title },
        }
    }

    pub fn jsonl_changed(
        session_id: impl Into<String>,
        agent: impl Into<String>,
        jsonl_path: impl Into<String>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::JsonlChanged {
                agent: agent.into(),
                jsonl_path: jsonl_path.into(),
            },
        }
    }

    pub fn agent_turn_complete(
        session_id: impl Into<String>,
        source: impl Into<String>,
        event_kind: impl Into<String>,
        body_preview: Option<String>,
    ) -> Self {
        Self {
            session_id: session_id.into(),
            kind: UiEventKind::AgentTurnComplete {
                source: source.into(),
                event_kind: event_kind.into(),
                body_preview,
            },
        }
    }

    pub fn lsp_install_progress(progress: InstallProgress) -> Self {
        Self {
            session_id: progress.server_id,
            kind: UiEventKind::LspInstallProgress {
                stage: progress.stage,
                percent: progress.percent,
                message: progress.message,
            },
        }
    }

    pub fn lsp_install_finished(server_id: impl Into<String>, version: String) -> Self {
        Self {
            session_id: server_id.into(),
            kind: UiEventKind::LspInstallFinished {
                ok: true,
                version: Some(version),
                error: None,
            },
        }
    }

    pub fn lsp_install_failed(server_id: impl Into<String>, error: String) -> Self {
        Self {
            session_id: server_id.into(),
            kind: UiEventKind::LspInstallFinished {
                ok: false,
                version: None,
                error: Some(error),
            },
        }
    }

    pub fn lsp_uninstalled(server_id: impl Into<String>) -> Self {
        Self {
            session_id: server_id.into(),
            kind: UiEventKind::LspUninstalled,
        }
    }

    pub fn lsp_diagnostics(server_id: String, uri: String, params: Value) -> Self {
        Self {
            // No good "owner" id for an unsolicited server push — route by
            // server_id so the frontend can fan-out to the right editor.
            session_id: server_id.clone(),
            kind: UiEventKind::LspDiagnostics {
                server_id,
                uri,
                params,
            },
        }
    }
}
