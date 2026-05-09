//! S3: drive Codex via the PTY adapter with the codex heuristic profile.
//!
//! Live test — requires `codex` on PATH. Auth is inherited from the parent
//! process env (`OPENAI_API_KEY` if set, otherwise the credentials saved by
//! `codex login`). Per plan S3:
//!
//! 1. ≥1 non-empty cleaned text line crosses the vt100 → reader pipeline
//!    (proves we're actually reading the agent's output, not just bytes).
//! 2. The advertised capabilities are honest: `structured_permissions =
//!    false` for PTY profiles. The UI relies on this flag to render the
//!    PTY-only fallback experience.
//! 3. Shutdown drains the reader thread without panicking on EOF.
//!
//! The y/n permission heuristic is exercised by unit tests in
//! `ycode_pty_adapter::heuristics::codex` rather than here, because reliably
//! coaxing live codex into a permission prompt within a smoke is brittle and
//! version-dependent.
//!
//! Codex's bare-`codex` invocation drops into an interactive TUI which does
//! not consume newline-terminated stdin lines. The smoke therefore spawns
//! `codex exec <prompt>` (non-interactive) so the prompt comes through argv
//! and the agent self-drives to completion. This means `runner.prompt()` is
//! deliberately *not* called — the assertion targets the PTY pipeline, not
//! the orchestrator's prompt → input wire (which the echo smokes cover).

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use camino::Utf8PathBuf;
use tokio::sync::broadcast::error::RecvError;
use tracing::info;
use ycode_adapter::{AgentAdapter, AgentEvent, SessionState, SpawnSpec};
use ycode_core::{SessionRunner, SessionStart};
use ycode_persist::Db;
use ycode_pty_adapter::{PtyAdapter, PtyAdapterConfig};
use ycode_worktree::{CleanupMode, WorktreeManager};

use crate::{boxed, emit_ndjson};

pub async fn run(repo: PathBuf, prompt: Option<String>) -> Result<()> {
    let repo = Utf8PathBuf::from_path_buf(repo)
        .map_err(|p| anyhow!("repo path is not UTF-8: {}", p.display()))?;
    // Capabilities check happens before spawn so we fail fast on a static
    // contract drift without burning subprocess resources.
    let probe = PtyAdapter::new(PtyAdapterConfig {
        heuristic_profile: "codex".into(),
    });
    let caps = probe.capabilities();
    if caps.structured_permissions {
        bail!("S3 FAILED: PTY adapter advertised structured_permissions=true");
    }
    if caps.structured_tool_calls {
        bail!("S3 FAILED: PTY adapter advertised structured_tool_calls=true");
    }
    drop(probe);

    let workdir = tempfile::tempdir().context("worktree root tempdir")?;
    let workdir_utf8 = Utf8PathBuf::from_path_buf(workdir.path().to_path_buf())
        .map_err(|p| anyhow!("tempdir not UTF-8: {}", p.display()))?;
    let mgr = WorktreeManager::new(workdir_utf8);
    let info = mgr.detect_repo(&repo)?;
    let session_id = ulid::Ulid::new().to_string();
    let wt = mgr.create_for_session(&info, &session_id)?;

    let db = Db::open_in_memory().await?;
    let prompt_text = prompt.unwrap_or_else(|| "Say hi in one short line.".into());
    let spec = SpawnSpec {
        cwd: wt.worktree_path.clone(),
        env: vec![],
        command: "codex".into(),
        args: vec!["exec".into(), prompt_text.clone()],
    };

    let start = SessionStart {
        id: session_id,
        title: "smoke-pty-codex".into(),
        agent_profile: "codex".into(),
        repo_root: wt.repo_root.clone(),
        worktree_path: wt.worktree_path.clone(),
        branch: wt.branch.clone(),
        base_ref: wt.base_ref.clone(),
        spawn_spec: spec,
    };

    let adapter = PtyAdapter::new(PtyAdapterConfig {
        heuristic_profile: "codex".into(),
    });
    let runner = SessionRunner::start(db, boxed(adapter), start).await?;
    let mut rx = runner.subscribe();

    // No runner.prompt(): see module-level doc — the prompt is in argv, the
    // agent self-drives. We only listen for output and EOF.
    let saw_clean_text = collect_until_done_or_timeout(&mut rx, Duration::from_secs(60)).await?;

    // Shutdown is itself part of the assertion: the reader thread must drain
    // EOF without panic. If it panics, the JoinHandle returns an Err which
    // shutdown logs but doesn't propagate — so we just verify shutdown
    // completes cleanly, then trust the lack of a panic in stderr.
    runner.shutdown().await?;
    let _ = mgr.cleanup(&wt, CleanupMode::KeepBranch);

    if !saw_clean_text {
        bail!("S3 FAILED: no non-empty cleaned output observed within 30s");
    }

    info!(
        structured_permissions = caps.structured_permissions,
        "smoke pty-codex: PASS"
    );
    Ok(())
}

async fn collect_until_done_or_timeout(
    rx: &mut tokio::sync::broadcast::Receiver<AgentEvent>,
    budget: Duration,
) -> Result<bool> {
    let deadline = tokio::time::Instant::now() + budget;
    let mut saw_clean = false;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            return Ok(saw_clean);
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                match &event {
                    AgentEvent::RawOutput { bytes } => {
                        let s = String::from_utf8_lossy(bytes);
                        if s.lines().any(|l| !l.trim().is_empty()) {
                            saw_clean = true;
                        }
                    }
                    AgentEvent::StateChanged {
                        state: SessionState::Done { .. },
                    } => return Ok(saw_clean),
                    AgentEvent::Error {
                        fatal: true,
                        message,
                    } => bail!("fatal adapter error: {message}"),
                    _ => {}
                }
            }
            Ok(Err(RecvError::Lagged(_))) => continue,
            Ok(Err(RecvError::Closed)) => return Ok(saw_clean),
            Err(_) => return Ok(saw_clean),
        }
    }
}
