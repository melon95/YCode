//! S5-style: simulate a crash, then restart the session with a fresh adapter.
//!
//! 1. Create an echo session via `SessionManager`.
//! 2. Drive it to `Done`.
//! 3. Detach it from the manager (simulating a crashed adapter).
//! 4. Call `manager.restart(id, profile)` — should bring up a new adapter,
//!    leave the DB row's id intact, and return a fresh runner in `Idle`.
//! 5. Send another prompt and verify the second turn completes.

use std::time::Duration;

use anyhow::{bail, Context, Result};
use camino::Utf8PathBuf;
use tokio::time::timeout;
use tracing::info;
use ycode_adapter::{SessionState, StopReason};
use ycode_core::SessionManager;
use ycode_persist::Db;
use ycode_worktree::WorktreeManager;

use crate::support::{echo_profile, init_git_repo, register_factories};

pub async fn run() -> Result<()> {
    let db = Db::open_in_memory().await?;
    let workdir = tempfile::tempdir().context("worktree root")?;
    let workdir_path = Utf8PathBuf::from_path_buf(workdir.path().to_path_buf())
        .map_err(|p| anyhow::anyhow!("non-UTF8 tempdir: {}", p.display()))?;
    let manager = SessionManager::new(db, WorktreeManager::new(workdir_path.join("worktrees")));
    register_factories(&manager).await;

    let repo_dir = tempfile::tempdir().context("repo tempdir")?;
    let repo_path = Utf8PathBuf::from_path_buf(repo_dir.path().to_path_buf())
        .map_err(|p| anyhow::anyhow!("non-UTF8 repo: {}", p.display()))?;
    init_git_repo(&repo_path)?;

    let profile = echo_profile();
    let runner = manager
        .create_session(&profile, &repo_path, "restart-victim".into())
        .await?;
    let session_id = runner.id().to_string();

    // First turn — succeeds normally.
    runner.prompt("first turn".into()).await?;
    let state = timeout(Duration::from_secs(5), runner.wait_terminal()).await?;
    if !matches!(
        state,
        SessionState::Done {
            stop_reason: StopReason::EndTurn
        }
    ) {
        bail!("expected first turn Done(EndTurn), got {state:?}");
    }

    // Simulate a crash: yank the runner out of the manager and drop it.
    let detached = manager
        .detach(&session_id)
        .await
        .ok_or_else(|| anyhow::anyhow!("runner not found in manager"))?;
    let _ = detached.shutdown().await;
    drop(detached);

    // Restart — should produce a brand-new runner with the same id.
    let revived = manager.restart(&session_id, &profile).await?;
    if revived.id() != session_id {
        bail!(
            "restart should preserve session id: got {} want {}",
            revived.id(),
            session_id
        );
    }
    if !matches!(revived.state().await, SessionState::Idle) {
        bail!("revived runner not Idle: {:?}", revived.state().await);
    }

    // Second turn against the fresh adapter.
    revived.prompt("second turn after restart".into()).await?;
    let state = timeout(Duration::from_secs(5), revived.wait_terminal()).await?;
    if !matches!(
        state,
        SessionState::Done {
            stop_reason: StopReason::EndTurn
        }
    ) {
        bail!("expected second turn Done(EndTurn), got {state:?}");
    }

    let _ = manager
        .archive(&session_id, ycode_worktree::CleanupMode::DeleteBranch)
        .await;
    drop(workdir);
    drop(repo_dir);

    info!("smoke echo-restart: PASS (id preserved, fresh adapter)");
    Ok(())
}
