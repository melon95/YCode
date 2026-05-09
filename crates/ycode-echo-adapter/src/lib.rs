//! `EchoAdapter` — the S6 LoC-gate witness.
//!
//! No subprocess, no LLM, no protocol. It echoes the user's prompt back as
//! `AssistantText` and ends the turn. If the prompt starts with the literal
//! `permission: <summary>`, it first asks for permission via the structured
//! event channel and waits for the answer before completing the turn.
//!
//! Two reasons this crate exists:
//!
//! 1. **The S6 LoC budget**: the plan requires a working adapter implementation
//!    in under 500 LoC of NEW code. This crate plus its registration in
//!    ycode-cli is the canary; if the budget is exceeded the trait is leaking
//!    too much downstream concern.
//! 2. **Deterministic smoke tests**: the orchestrator and CLI smoke runner
//!    have a path that doesn't burn API credits or require an installed CLI.

use std::sync::Arc;

use async_trait::async_trait;
use tokio::sync::{oneshot, Mutex};
use tracing::debug;

use ycode_adapter::{
    AdapterError, AgentAdapter, AgentEvent, Capabilities, EventSender, PermissionKind,
    PermissionOption, SessionState, SpawnSpec, StopReason,
};

/// Capabilities the echo adapter advertises. PTY-shaped (no structured tool
/// calls) — the point is to validate that the trait accommodates a "dumb"
/// adapter without escape hatches.
const CAPS: Capabilities = Capabilities {
    streaming_text: true,
    structured_tool_calls: false,
    structured_permissions: true, // we DO emit structured RequestPermission
    plans: false,
    cancel: true,
    modes: false,
};

#[derive(Default)]
pub struct EchoAdapter {
    events_tx: Option<EventSender>,
    /// One pending permission at a time is enough for the smoke flow.
    pending: Arc<Mutex<Option<Pending>>>,
    cancelled: Arc<Mutex<bool>>,
}

struct Pending {
    request_id: String,
    waker: oneshot::Sender<String>,
}

impl EchoAdapter {
    pub fn new() -> Self {
        Self::default()
    }

    fn tx(&self) -> Result<EventSender, AdapterError> {
        self.events_tx
            .clone()
            .ok_or(AdapterError::InvalidState("adapter not started"))
    }
}

#[async_trait]
impl AgentAdapter for EchoAdapter {
    fn name(&self) -> &'static str {
        "echo"
    }

    fn capabilities(&self) -> Capabilities {
        CAPS
    }

    async fn start(
        &mut self,
        _spec: SpawnSpec,
        events_tx: EventSender,
    ) -> Result<(), AdapterError> {
        send(&events_tx, AgentEvent::StateChanged { state: SessionState::Idle }).await?;
        self.events_tx = Some(events_tx);
        Ok(())
    }

    async fn prompt(&mut self, text: String) -> Result<(), AdapterError> {
        let tx = self.tx()?;
        let pending = self.pending.clone();
        let cancelled = self.cancelled.clone();
        // Run the turn off-thread so prompt() returns immediately.
        tokio::spawn(async move {
            run_turn(tx, text, pending, cancelled).await;
        });
        Ok(())
    }

    async fn answer_permission(
        &mut self,
        request_id: String,
        option_id: String,
    ) -> Result<(), AdapterError> {
        let mut slot = self.pending.lock().await;
        match slot.take() {
            Some(p) if p.request_id == request_id => {
                let _ = p.waker.send(option_id);
                Ok(())
            }
            other => {
                // Put back if it was a different request_id (shouldn't happen).
                if let Some(p) = other {
                    *slot = Some(p);
                }
                Err(AdapterError::UnknownPermission { request_id })
            }
        }
    }

    async fn cancel(&mut self) -> Result<(), AdapterError> {
        *self.cancelled.lock().await = true;
        // Wake any pending permission with a "rejected" answer so the turn
        // can wind down.
        if let Some(p) = self.pending.lock().await.take() {
            let _ = p.waker.send("__cancelled__".into());
        }
        Ok(())
    }

    async fn shutdown(&mut self) -> Result<(), AdapterError> {
        self.events_tx = None;
        Ok(())
    }
}

async fn run_turn(
    tx: EventSender,
    text: String,
    pending: Arc<Mutex<Option<Pending>>>,
    cancelled: Arc<Mutex<bool>>,
) {
    let turn_id = ulid::Ulid::new().to_string();
    if !send(&tx, AgentEvent::StateChanged {
        state: SessionState::Running { turn_id: turn_id.clone() },
    })
    .await
    .is_ok()
    {
        return;
    }

    // Optional permission request: if prompt starts with `permission:`, ask
    // for approval before producing assistant text.
    let body = if let Some(rest) = text.strip_prefix("permission:") {
        let request_id = ulid::Ulid::new().to_string();
        let summary = rest.trim().to_string();
        let (waker, wait) = oneshot::channel();
        *pending.lock().await = Some(Pending {
            request_id: request_id.clone(),
            waker,
        });
        let _ = send(
            &tx,
            AgentEvent::RequestPermission {
                request_id: request_id.clone(),
                tool_name: "echo".into(),
                summary: summary.clone(),
                options: vec![
                    PermissionOption {
                        option_id: "allow_once".into(),
                        name: "Allow".into(),
                        kind: PermissionKind::AllowOnce,
                    },
                    PermissionOption {
                        option_id: "reject_once".into(),
                        name: "Reject".into(),
                        kind: PermissionKind::RejectOnce,
                    },
                ],
            },
        )
        .await;
        let _ = send(
            &tx,
            AgentEvent::StateChanged {
                state: SessionState::AwaitingPermission {
                    request_id: request_id.clone(),
                    tool: "echo".into(),
                    summary: summary.clone(),
                },
            },
        )
        .await;
        let answer = wait.await.unwrap_or_else(|_| "reject_once".into());
        if answer == "__cancelled__" || answer == "reject_once" {
            // Cancelled or rejected: end the turn cleanly.
            let _ = send(
                &tx,
                AgentEvent::StateChanged {
                    state: SessionState::Running {
                        turn_id: turn_id.clone(),
                    },
                },
            )
            .await;
            let stop_reason = if *cancelled.lock().await {
                StopReason::Cancelled
            } else {
                StopReason::Refusal
            };
            let _ = send(
                &tx,
                AgentEvent::StateChanged {
                    state: SessionState::Done { stop_reason },
                },
            )
            .await;
            return;
        }
        // Approved: resume Running, then echo the summary.
        let _ = send(
            &tx,
            AgentEvent::StateChanged {
                state: SessionState::Running {
                    turn_id: turn_id.clone(),
                },
            },
        )
        .await;
        format!("(approved) {summary}")
    } else {
        text
    };

    // If cancellation arrived during the (no-permission) path, honour it.
    if *cancelled.lock().await {
        let _ = send(&tx, AgentEvent::StateChanged { state: SessionState::Cancelling }).await;
        let _ = send(
            &tx,
            AgentEvent::StateChanged {
                state: SessionState::Done {
                    stop_reason: StopReason::Cancelled,
                },
            },
        )
        .await;
        return;
    }

    // Stream the echo as a single chunk.
    let _ = send(
        &tx,
        AgentEvent::AssistantText {
            chunk_id: ulid::Ulid::new().to_string(),
            text: format!("echo: {body}"),
            final_chunk: true,
        },
    )
    .await;
    let _ = send(
        &tx,
        AgentEvent::StateChanged {
            state: SessionState::Done {
                stop_reason: StopReason::EndTurn,
            },
        },
    )
    .await;
    debug!("echo turn complete");
}

async fn send(tx: &EventSender, ev: AgentEvent) -> Result<(), AdapterError> {
    tx.send(ev)
        .await
        .map_err(|_| AdapterError::Transport("event channel closed".into()))
}
