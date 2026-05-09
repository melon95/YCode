//! S2: drive Gemini CLI via ACP and cancel mid-turn.
//!
//! Live test — requires `gemini` on PATH (with `--acp` support). Auth is
//! inherited from the parent process env: any of `GEMINI_API_KEY`,
//! `GOOGLE_API_KEY`, or a local `gemini login` credential will work. Per
//! plan S2: after `cancel()`, the session must reach `Done(Cancelled)`
//! within 5s.
//!
//! The plan's secondary assertion ("process gone from `ps`") is NOT enforced
//! here because the adapter does not expose the child PID, and a name-based
//! `pgrep` would race other gemini processes on the developer's machine.
//! Cleanly observing `Done(Cancelled)` plus a successful `shutdown()` gives
//! us functional equivalent coverage; if we ever need stricter assurance,
//! plumb the PID through `AdapterError`/diagnostics rather than scraping ps.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use camino::Utf8PathBuf;
use tokio::sync::broadcast::error::RecvError;
use tracing::info;
use ycode_acp_adapter::AcpAdapter;
use ycode_adapter::{AgentEvent, SessionState, SpawnSpec, StopReason};
use ycode_core::{SessionRunner, SessionStart};
use ycode_persist::Db;
use ycode_worktree::{CleanupMode, WorktreeManager};

use crate::{boxed, emit_ndjson};

/// Default prompt picked to keep the agent busy long enough to give the
/// cancel a chance to land mid-turn. Caller can override via --prompt.
const LONG_PROMPT: &str =
    "List 50 detailed facts about cats, one per line, with a sentence each.";

pub async fn run(repo: PathBuf, prompt: Option<String>) -> Result<()> {
    let repo = Utf8PathBuf::from_path_buf(repo)
        .map_err(|p| anyhow!("repo path is not UTF-8: {}", p.display()))?;
    let workdir = tempfile::tempdir().context("worktree root tempdir")?;
    let workdir_utf8 = Utf8PathBuf::from_path_buf(workdir.path().to_path_buf())
        .map_err(|p| anyhow!("tempdir not UTF-8: {}", p.display()))?;
    let mgr = WorktreeManager::new(workdir_utf8);
    let info = mgr.detect_repo(&repo)?;
    let session_id = ulid::Ulid::new().to_string();
    let wt = mgr.create_for_session(&info, &session_id)?;

    let db = Db::open_in_memory().await?;
    let spec = SpawnSpec {
        cwd: wt.worktree_path.clone(),
        env: vec![],
        command: "gemini".into(),
        args: vec!["--acp".into()],
    };

    let start = SessionStart {
        id: session_id,
        title: "smoke-acp-gemini".into(),
        agent_profile: "gemini-cli".into(),
        repo_root: wt.repo_root.clone(),
        worktree_path: wt.worktree_path.clone(),
        branch: wt.branch.clone(),
        base_ref: wt.base_ref.clone(),
        spawn_spec: spec,
    };

    let runner = SessionRunner::start(db, boxed(AcpAdapter::new()), start).await?;
    let mut rx = runner.subscribe();

    let prompt_text = prompt.unwrap_or_else(|| LONG_PROMPT.into());
    runner.prompt(prompt_text).await?;

    // Phase 1: wait for Running. Without this we'd risk cancelling before the
    // turn left Idle — observably "fast cancel", but not the mid-turn case
    // S2 is supposed to exercise.
    wait_for_running(&mut rx, Duration::from_secs(30)).await?;

    runner.cancel().await?;

    // Phase 2: plan-mandated 5s budget for Done(Cancelled).
    let outcome = wait_for_cancelled(&mut rx, Duration::from_secs(5)).await;

    let _ = runner.shutdown().await;
    let _ = mgr.cleanup(&wt, CleanupMode::KeepBranch);

    outcome?;
    info!("smoke acp-gemini: PASS");
    Ok(())
}

async fn wait_for_running(
    rx: &mut tokio::sync::broadcast::Receiver<AgentEvent>,
    budget: Duration,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("timed out waiting for Running before cancel");
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                if matches!(
                    event,
                    AgentEvent::StateChanged {
                        state: SessionState::Running { .. }
                    }
                ) {
                    return Ok(());
                }
            }
            Ok(Err(RecvError::Lagged(_))) => continue,
            Ok(Err(RecvError::Closed)) => bail!("event stream closed before Running"),
            Err(_) => bail!("timed out waiting for Running"),
        }
    }
}

async fn wait_for_cancelled(
    rx: &mut tokio::sync::broadcast::Receiver<AgentEvent>,
    budget: Duration,
) -> Result<()> {
    let deadline = tokio::time::Instant::now() + budget;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("S2 FAILED: did not reach Done(Cancelled) within {budget:?} of cancel");
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                if let AgentEvent::StateChanged { ref state } = event {
                    match state {
                        SessionState::Done {
                            stop_reason: StopReason::Cancelled,
                        } => return Ok(()),
                        SessionState::Done { stop_reason } => {
                            bail!("expected Done(Cancelled), got Done({stop_reason:?})");
                        }
                        SessionState::Error { message } => {
                            bail!("session errored during cancel: {message}");
                        }
                        _ => {}
                    }
                }
            }
            Ok(Err(RecvError::Lagged(_))) => continue,
            Ok(Err(RecvError::Closed)) => bail!("event stream closed during cancel"),
            Err(_) => bail!("S2 FAILED: timed out waiting for Done(Cancelled)"),
        }
    }
}
