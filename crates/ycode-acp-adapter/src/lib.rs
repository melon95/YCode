//! ACP (Agent Client Protocol) adapter.
//!
//! Drives any ACP-compliant agent over JSON-RPC on stdio: Claude Code (via
//! `@zed-industries/claude-code-acp`), Gemini CLI (`gemini --experimental-acp`),
//! and others. Wire format is newline-delimited JSON-RPC 2.0.
//!
//! ## Layout
//!
//! - [`protocol`] — hand-rolled wire types (only the subset we need).
//! - [`transport`] — process spawn, NDJSON IO, request/response correlation.
//! - [`map`] — pure translation between ACP `SessionUpdate` and our
//!   `AgentEvent` enum.
//! - this module — `AcpAdapter` implementing `AgentAdapter`, including the
//!   inbound permission-request handler and the prompt turn driver.
//!
//! ## Day-3 risk note
//!
//! ACP's `session/request_permission` is a server-method call: the agent
//! is asking us a question and waiting on a response. Per the plan, our
//! handler MUST NOT block the JSON-RPC reader — see `transport::dispatch`,
//! which spawns each handler on a fresh task.

mod map;
mod protocol;
mod transport;

use std::sync::Arc;

use async_trait::async_trait;
use serde_json::Value;
use tokio::sync::{oneshot, Mutex};
use tracing::{debug, error, info, warn};
use ulid::Ulid;

use ycode_adapter::{
    AdapterError, AgentAdapter, AgentEvent, Capabilities, EventSender, SessionState, SpawnSpec,
    StopReason,
};

use crate::protocol::{
    method, CancelNotification, ContentBlock, InitializeRequest, NewSessionRequest,
    NewSessionResponse, PermissionOutcome, PromptRequest, PromptResponse, ReadTextFileParams,
    ReadTextFileResponse, RequestPermissionParams, RequestPermissionResponse, RpcError,
    SessionUpdateNotification, WriteTextFileParams, WriteTextFileResponse, PROTOCOL_VERSION,
};
use crate::transport::{MessageHandler, Transport};

const ACP_CAPS: Capabilities = Capabilities {
    streaming_text: true,
    structured_tool_calls: true,
    structured_permissions: true,
    plans: true,
    cancel: true,
    modes: true,
};

pub struct AcpAdapter {
    transport: Option<Arc<Transport>>,
    session_id: Arc<Mutex<Option<String>>>,
    /// Outstanding inbound permission requests waiting for `answer_permission`.
    pending_permissions: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<String>>>>,
    /// The cwd for fs/* sandboxing. Set during `start`.
    cwd: Arc<Mutex<Option<camino::Utf8PathBuf>>>,
    /// Events sender retained for the turn driver.
    events_tx: Option<EventSender>,
}

impl AcpAdapter {
    pub fn new() -> Self {
        Self {
            transport: None,
            session_id: Arc::new(Mutex::new(None)),
            pending_permissions: Arc::new(Mutex::new(Default::default())),
            cwd: Arc::new(Mutex::new(None)),
            events_tx: None,
        }
    }

    fn t(&self) -> Result<&Arc<Transport>, AdapterError> {
        self.transport
            .as_ref()
            .ok_or(AdapterError::InvalidState("adapter not started"))
    }
}

impl Default for AcpAdapter {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AgentAdapter for AcpAdapter {
    fn name(&self) -> &'static str {
        "acp"
    }

    fn capabilities(&self) -> Capabilities {
        ACP_CAPS
    }

    async fn start(
        &mut self,
        spec: SpawnSpec,
        events_tx: EventSender,
    ) -> Result<(), AdapterError> {
        info!(command = %spec.command, "spawning ACP agent");

        let handler: Arc<dyn MessageHandler> = Arc::new(InboundHandler {
            events_tx: events_tx.clone(),
            pending: self.pending_permissions.clone(),
            session_id: self.session_id.clone(),
            cwd: self.cwd.clone(),
        });

        *self.cwd.lock().await = Some(spec.cwd.clone());

        let transport = Transport::spawn(
            &spec.command,
            &spec.args,
            &spec.env,
            Some(spec.cwd.as_str()),
            handler,
        )
        .await
        .map_err(|e| AdapterError::Spawn(e.to_string()))?;

        // Initialize handshake.
        let init_req = InitializeRequest {
            protocol_version: PROTOCOL_VERSION,
            client_capabilities: Some(crate::protocol::ClientCapabilities {
                fs: crate::protocol::FsCapabilities {
                    read_text_file: true,
                    write_text_file: true,
                },
            }),
            client_info: Some(crate::protocol::Implementation {
                name: "ycode".into(),
                version: env!("CARGO_PKG_VERSION").into(),
            }),
        };
        let resp = transport
            .request(method::INITIALIZE, init_req)
            .await
            .map_err(|e| AdapterError::Transport(format!("initialize: {e}")))?;
        if let Some(err) = resp.error {
            return Err(AdapterError::Protocol(format!(
                "initialize failed: {} ({})",
                err.message, err.code
            )));
        }

        // session/new
        let new_req = NewSessionRequest {
            cwd: spec.cwd.to_string(),
            mcp_servers: vec![],
        };
        let resp = transport
            .request(method::SESSION_NEW, new_req)
            .await
            .map_err(|e| AdapterError::Transport(format!("session/new: {e}")))?;
        if let Some(err) = resp.error {
            return Err(AdapterError::Protocol(format!(
                "session/new failed: {} ({})",
                err.message, err.code
            )));
        }
        let session_resp: NewSessionResponse = match resp.result {
            Some(v) => serde_json::from_value(v)
                .map_err(|e| AdapterError::Protocol(format!("decoding session/new: {e}")))?,
            None => return Err(AdapterError::Protocol("session/new: empty result".into())),
        };
        *self.session_id.lock().await = Some(session_resp.session_id.clone());
        debug!(session_id = %session_resp.session_id, "ACP session opened");

        self.transport = Some(transport);

        // Signal readiness.
        let _ = events_tx
            .send(AgentEvent::StateChanged {
                state: SessionState::Idle,
            })
            .await;

        self.events_tx = Some(events_tx);

        Ok(())
    }

    async fn prompt(&mut self, text: String) -> Result<(), AdapterError> {
        let transport = self.t()?.clone();
        let session_id = self
            .session_id
            .lock()
            .await
            .clone()
            .ok_or(AdapterError::InvalidState("no session"))?;
        let events_tx = self
            .events_tx
            .clone()
            .ok_or(AdapterError::InvalidState("no events channel"))?;

        // Spawn the turn so prompt() returns immediately. The reader keeps
        // delivering session/update notifications in parallel.
        tokio::spawn(async move {
            run_turn(transport, session_id, text, events_tx).await;
        });
        Ok(())
    }

    async fn answer_permission(
        &mut self,
        request_id: String,
        option_id: String,
    ) -> Result<(), AdapterError> {
        let tx = {
            let mut pending = self.pending_permissions.lock().await;
            pending
                .remove(&request_id)
                .ok_or_else(|| AdapterError::UnknownPermission {
                    request_id: request_id.clone(),
                })?
        };

        // Transition AwaitingPermission → Running BEFORE waking the handler.
        // This way the handler's reply travels through the wire after the
        // state machine has already accepted the resume. If we did this in
        // the handler instead, run_turn could deliver `Done` first and the
        // orchestrator would reject `AwaitingPermission → Done`.
        if let Some(events_tx) = &self.events_tx {
            let _ = events_tx
                .send(AgentEvent::StateChanged {
                    state: SessionState::Running {
                        turn_id: Ulid::new().to_string(),
                    },
                })
                .await;
        }

        let _ = tx.send(option_id);
        Ok(())
    }

    async fn cancel(&mut self) -> Result<(), AdapterError> {
        let transport = self.t()?.clone();
        let session_id = self
            .session_id
            .lock()
            .await
            .clone()
            .ok_or(AdapterError::InvalidState("no session"))?;

        // Per ACP spec: when cancelling, we MUST resolve every pending
        // request_permission with `Cancelled`. Do it here before sending the
        // session/cancel notification so the handler's reply leaves with the
        // cancel outcome. Also transition out of AwaitingPermission to
        // Cancelling so the state machine accepts the eventual Done.
        let pending: Vec<_> = {
            let mut p = self.pending_permissions.lock().await;
            p.drain().collect()
        };
        let had_pending = !pending.is_empty();
        for (_, tx) in pending {
            let _ = tx.send("__cancelled__".to_string());
        }
        if let Some(events_tx) = &self.events_tx {
            let _ = events_tx
                .send(AgentEvent::StateChanged {
                    state: SessionState::Cancelling,
                })
                .await;
        }
        let _ = had_pending; // (kept for future logging if useful)

        transport
            .notify(method::SESSION_CANCEL, CancelNotification { session_id })
            .await
            .map_err(|e| AdapterError::Transport(format!("session/cancel: {e}")))?;
        Ok(())
    }

    async fn shutdown(&mut self) -> Result<(), AdapterError> {
        if let Some(t) = self.transport.take() {
            t.shutdown().await;
        }
        // Wake any stranded permission waiters so their tasks unwind.
        let mut pending = self.pending_permissions.lock().await;
        for (_, tx) in pending.drain() {
            let _ = tx.send("__cancelled__".into());
        }
        Ok(())
    }
}

async fn run_turn(
    transport: Arc<Transport>,
    session_id: String,
    text: String,
    events_tx: EventSender,
) {
    let turn_id = Ulid::new().to_string();
    let _ = events_tx
        .send(AgentEvent::StateChanged {
            state: SessionState::Running {
                turn_id: turn_id.clone(),
            },
        })
        .await;

    let req = PromptRequest {
        session_id,
        prompt: vec![ContentBlock::Text { text }],
    };
    match transport.request(method::SESSION_PROMPT, req).await {
        Ok(resp) => {
            if let Some(err) = resp.error {
                error!(error = %err.message, "session/prompt failed");
                let _ = events_tx
                    .send(AgentEvent::Error {
                        message: err.message,
                        fatal: false,
                    })
                    .await;
                let _ = events_tx
                    .send(AgentEvent::StateChanged {
                        state: SessionState::Done {
                            stop_reason: StopReason::Other {
                                detail: "prompt_error".into(),
                            },
                        },
                    })
                    .await;
                return;
            }
            let pr: Result<PromptResponse, _> = resp
                .result
                .map(serde_json::from_value)
                .unwrap_or_else(|| serde_json::from_value(serde_json::json!({"stopReason": "end_turn"})));
            let stop_reason = match pr {
                Ok(p) => map::map_stop_reason(p.stop_reason),
                Err(e) => {
                    warn!(error = %e, "couldn't decode PromptResponse; assuming end_turn");
                    StopReason::EndTurn
                }
            };
            let _ = events_tx
                .send(AgentEvent::StateChanged {
                    state: SessionState::Done { stop_reason },
                })
                .await;
        }
        Err(e) => {
            error!(error = %e, "transport error during prompt");
            let _ = events_tx
                .send(AgentEvent::Error {
                    message: e.to_string(),
                    fatal: true,
                })
                .await;
        }
    }
}

// -- Inbound handler --------------------------------------------------------

struct InboundHandler {
    events_tx: EventSender,
    pending: Arc<Mutex<std::collections::HashMap<String, oneshot::Sender<String>>>>,
    session_id: Arc<Mutex<Option<String>>>,
    cwd: Arc<Mutex<Option<camino::Utf8PathBuf>>>,
}

#[async_trait]
impl MessageHandler for InboundHandler {
    async fn handle_request(
        &self,
        method: &str,
        params: Option<Value>,
    ) -> Result<Value, RpcError> {
        match method {
            crate::protocol::method::SESSION_REQUEST_PERMISSION => {
                let params: RequestPermissionParams = parse_params(params)?;
                let request_id = Ulid::new().to_string();
                let summary = params
                    .tool_call
                    .title
                    .clone()
                    .unwrap_or_else(|| "tool call".to_string());
                let tool_name = params
                    .tool_call
                    .kind
                    .clone()
                    .unwrap_or_else(|| "tool".into());
                let options = map::map_permission_options(params.options.clone());

                // Set up the wakeup channel BEFORE emitting the event.
                let (tx, rx) = oneshot::channel::<String>();
                self.pending.lock().await.insert(request_id.clone(), tx);

                // Emit the event for the orchestrator/UI to handle.
                let _ = self
                    .events_tx
                    .send(AgentEvent::RequestPermission {
                        request_id: request_id.clone(),
                        tool_name: tool_name.clone(),
                        summary: summary.clone(),
                        options,
                    })
                    .await;
                let _ = self
                    .events_tx
                    .send(AgentEvent::StateChanged {
                        state: SessionState::AwaitingPermission {
                            request_id: request_id.clone(),
                            tool: tool_name,
                            summary,
                        },
                    })
                    .await;

                // Wait for the user's answer (delivered via answer_permission
                // or implicitly via cancel). The state transition out of
                // AwaitingPermission has already been emitted by the adapter
                // method that woke us up (Running for answer, Cancelling for
                // cancel) — we don't emit another transition here.
                let outcome = match rx.await {
                    Ok(option_id) if option_id == "__cancelled__" => PermissionOutcome::Cancelled,
                    Ok(option_id) => PermissionOutcome::Selected { option_id },
                    Err(_) => PermissionOutcome::Cancelled,
                };

                let response = RequestPermissionResponse { outcome };
                serde_json::to_value(response).map_err(|e| RpcError {
                    code: -32603,
                    message: format!("encoding RequestPermissionResponse: {e}"),
                    data: None,
                })
            }
            crate::protocol::method::FS_READ_TEXT_FILE => {
                let params: ReadTextFileParams = parse_params(params)?;
                let cwd = self
                    .cwd
                    .lock()
                    .await
                    .clone()
                    .ok_or_else(|| internal_error("cwd not set"))?;
                let resolved = resolve_in_cwd(&cwd, &params.path)
                    .map_err(|e| RpcError {
                        code: -32602,
                        message: e,
                        data: None,
                    })?;
                let mut content = std::fs::read_to_string(&resolved).map_err(|e| RpcError {
                    code: -32603,
                    message: format!("read {resolved:?}: {e}"),
                    data: None,
                })?;
                if let Some(line) = params.line {
                    content = skip_lines(&content, line.saturating_sub(1));
                }
                if let Some(limit) = params.limit {
                    content = take_lines(&content, limit);
                }
                serde_json::to_value(ReadTextFileResponse { content })
                    .map_err(|e| internal_error(format!("encoding read response: {e}")))
            }
            crate::protocol::method::FS_WRITE_TEXT_FILE => {
                let params: WriteTextFileParams = parse_params(params)?;
                let cwd = self
                    .cwd
                    .lock()
                    .await
                    .clone()
                    .ok_or_else(|| internal_error("cwd not set"))?;
                let resolved = resolve_in_cwd(&cwd, &params.path)
                    .map_err(|e| RpcError {
                        code: -32602,
                        message: e,
                        data: None,
                    })?;
                if let Some(parent) = resolved.parent() {
                    let _ = std::fs::create_dir_all(parent);
                }
                std::fs::write(&resolved, params.content).map_err(|e| RpcError {
                    code: -32603,
                    message: format!("write {resolved:?}: {e}"),
                    data: None,
                })?;
                serde_json::to_value(WriteTextFileResponse {})
                    .map_err(|e| internal_error(format!("encoding write response: {e}")))
            }
            other => Err(RpcError {
                code: -32601,
                message: format!("method not implemented: {other}"),
                data: None,
            }),
        }
    }

    async fn handle_notification(&self, method: &str, params: Option<Value>) {
        if method != crate::protocol::method::SESSION_UPDATE {
            debug!(method, "unhandled notification");
            return;
        }
        let Some(params) = params else {
            warn!("session/update missing params");
            return;
        };
        let n: SessionUpdateNotification = match serde_json::from_value(params) {
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "malformed session/update");
                return;
            }
        };
        // Filter on session id — agents that multiplex sessions over one
        // connection would otherwise leak between sessions. We only ever
        // create one session per adapter instance.
        let known = self.session_id.lock().await.clone();
        if let Some(known) = known {
            if known != n.session_id {
                debug!(known, got = %n.session_id, "ignoring update for unrelated session");
                return;
            }
        }
        if let Some(event) = map::map_update(n.update) {
            let _ = self.events_tx.send(event).await;
        }
    }
}

fn parse_params<T: for<'de> serde::Deserialize<'de>>(
    params: Option<Value>,
) -> Result<T, RpcError> {
    let params = params.ok_or_else(|| RpcError {
        code: -32602,
        message: "missing params".into(),
        data: None,
    })?;
    serde_json::from_value(params).map_err(|e| RpcError {
        code: -32602,
        message: format!("invalid params: {e}"),
        data: None,
    })
}

fn internal_error(msg: impl Into<String>) -> RpcError {
    RpcError {
        code: -32603,
        message: msg.into(),
        data: None,
    }
}

/// Constrain `path` to a descendant of `cwd`. ACP fs requests come with
/// absolute paths in practice; we resolve and check containment.
fn resolve_in_cwd(cwd: &camino::Utf8Path, path: &str) -> Result<std::path::PathBuf, String> {
    let p = std::path::Path::new(path);
    let resolved = if p.is_absolute() {
        p.to_path_buf()
    } else {
        cwd.as_std_path().join(p)
    };
    let canonical_cwd = std::fs::canonicalize(cwd.as_std_path())
        .map_err(|e| format!("canonicalize cwd: {e}"))?;
    // Don't require the file to exist (write case); canonicalize the parent.
    let parent = resolved.parent().unwrap_or(std::path::Path::new("/"));
    let canonical_parent = std::fs::canonicalize(parent).unwrap_or_else(|_| parent.to_path_buf());
    if !canonical_parent.starts_with(&canonical_cwd) {
        return Err(format!(
            "path escapes session cwd: {} not under {}",
            canonical_parent.display(),
            canonical_cwd.display()
        ));
    }
    Ok(resolved)
}

fn skip_lines(s: &str, n: u32) -> String {
    s.lines().skip(n as usize).collect::<Vec<_>>().join("\n")
}

fn take_lines(s: &str, n: u32) -> String {
    s.lines().take(n as usize).collect::<Vec<_>>().join("\n")
}
