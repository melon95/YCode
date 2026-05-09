//! Permission round-trip via EchoAdapter. Validates the orchestrator's broker
//! and state-machine handling of AwaitingPermission.

use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use tokio::sync::broadcast::error::RecvError;
use tracing::info;
use ycode_adapter::{AgentEvent, SessionState};
use ycode_echo_adapter::EchoAdapter;

use crate::{boxed, dummy_start, emit_ndjson, temp_db};

pub async fn run() -> Result<()> {
    let db = temp_db().await?;
    let (start, _keep) = dummy_start("echo", "smoke-echo-permission")?;
    let runner =
        ycode_core::SessionRunner::start(db, boxed(EchoAdapter::new()), start).await?;

    let mut rx = runner.subscribe();
    runner
        .prompt("permission: write hello.txt".into())
        .await?;

    // Wait for AwaitingPermission and grab request_id.
    let request_id = loop {
        match rx.recv().await {
            Ok(event) => {
                emit_ndjson(&event);
                if let AgentEvent::StateChanged {
                    state:
                        SessionState::AwaitingPermission {
                            ref request_id, ..
                        },
                } = event
                {
                    break request_id.clone();
                }
            }
            Err(RecvError::Lagged(_)) => continue,
            Err(RecvError::Closed) => bail!("event stream closed before AwaitingPermission"),
        }
    };

    runner
        .answer_permission(request_id, "allow_once".into())
        .await
        .context("answering permission")?;

    // Drive the rest to terminal.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut saw_approved = false;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("timed out after permission answer");
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                if let AgentEvent::AssistantText { ref text, .. } = event {
                    if text.contains("(approved)") {
                        saw_approved = true;
                    }
                }
                if let AgentEvent::StateChanged {
                    state: SessionState::Done { .. },
                } = event
                {
                    break;
                }
            }
            Ok(Err(RecvError::Lagged(_))) => continue,
            Ok(Err(RecvError::Closed)) => break,
            Err(_) => bail!("timed out after permission answer"),
        }
    }

    if !saw_approved {
        return Err(anyhow!("expected '(approved)' in echoed text"));
    }
    runner.shutdown().await?;
    info!("smoke echo-permission: PASS");
    Ok(())
}
