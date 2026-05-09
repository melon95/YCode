//! Cancel mid-permission: drives the orchestrator's cancel pathway end-to-end.
//!
//! Echo adapter's `permission:` prompt suspends awaiting an answer; we call
//! `runner.cancel()` instead of answering and assert the session winds down
//! to `Done(Cancelled)`.

use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use tokio::sync::broadcast::error::RecvError;
use tracing::info;
use ycode_adapter::{AgentEvent, SessionState, StopReason};
use ycode_core::SessionRunner;
use ycode_echo_adapter::EchoAdapter;

use crate::{boxed, dummy_start, emit_ndjson, temp_db};

pub async fn run() -> Result<()> {
    let db = temp_db().await?;
    let (start, _keep) = dummy_start("echo", "smoke-echo-cancel")?;
    let runner = SessionRunner::start(db, boxed(EchoAdapter::new()), start).await?;

    let mut rx = runner.subscribe();
    runner
        .prompt("permission: write hello.txt".into())
        .await?;

    // Wait for AwaitingPermission, then cancel instead of answering.
    loop {
        match rx.recv().await {
            Ok(event) => {
                emit_ndjson(&event);
                if matches!(
                    event,
                    AgentEvent::StateChanged {
                        state: SessionState::AwaitingPermission { .. }
                    }
                ) {
                    break;
                }
            }
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => bail!("event stream closed before AwaitingPermission"),
        }
    }
    runner.cancel().await?;

    // Drive to Done(Cancelled).
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("timed out waiting for Done(Cancelled)");
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                if let AgentEvent::StateChanged { ref state } = event {
                    match state {
                        SessionState::Done {
                            stop_reason: StopReason::Cancelled,
                        } => {
                            runner.shutdown().await?;
                            info!("smoke echo-cancel: PASS");
                            return Ok(());
                        }
                        SessionState::Done { stop_reason } => {
                            return Err(anyhow!(
                                "expected Done(Cancelled), got Done({stop_reason:?})"
                            ));
                        }
                        SessionState::Error { message } => {
                            return Err(anyhow!("session errored during cancel: {message}"));
                        }
                        _ => {}
                    }
                }
            }
            Ok(Err(RecvError::Lagged(_))) => continue,
            Ok(Err(RecvError::Closed)) => bail!("event stream closed during cancel"),
            Err(_) => bail!("timed out waiting for Done(Cancelled)"),
        }
    }
}
