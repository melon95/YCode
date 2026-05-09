//! S4-style: drive 3 echo sessions concurrently through `SessionManager`.
//!
//! Each session lives in its own git worktree (so worktree-isolation is
//! exercised too), prompts independently, and is asserted to reach
//! `Done(EndTurn)`. Stresses the manager under parallelism without burning
//! API credit.

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

const N: usize = 3;

pub async fn run() -> Result<()> {
    let db = Db::open_in_memory().await?;
    let workdir = tempfile::tempdir().context("worktree root")?;
    let workdir_path =
        Utf8PathBuf::from_path_buf(workdir.path().to_path_buf()).map_err(|p| {
            anyhow::anyhow!("non-UTF8 tempdir: {}", p.display())
        })?;
    let manager = SessionManager::new(db, WorktreeManager::new(workdir_path.join("worktrees")));
    register_factories(&manager).await;

    let profile = echo_profile();

    // Spin up N independent repos + sessions.
    let mut runners = Vec::new();
    let mut keeps: Vec<tempfile::TempDir> = Vec::new();
    for i in 0..N {
        let repo_dir = tempfile::tempdir().context("repo tempdir")?;
        let repo_path =
            Utf8PathBuf::from_path_buf(repo_dir.path().to_path_buf()).map_err(|p| {
                anyhow::anyhow!("non-UTF8 repo path: {}", p.display())
            })?;
        init_git_repo(&repo_path)?;
        let runner = manager
            .create_session(&profile, &repo_path, format!("parallel-{i}"))
            .await
            .with_context(|| format!("create_session #{i}"))?;
        runners.push(runner);
        keeps.push(repo_dir);
    }

    // Prompt + wait, all concurrently.
    let waits = runners.iter().enumerate().map(|(i, runner)| {
        let runner = runner.clone();
        async move {
            runner
                .prompt(format!("hello-{i}"))
                .await
                .with_context(|| format!("prompt #{i}"))?;
            let final_state = timeout(Duration::from_secs(10), runner.wait_terminal())
                .await
                .with_context(|| format!("wait_terminal #{i}"))?;
            anyhow::Ok((i, final_state))
        }
    });
    let results = futures_join_all(waits).await;

    let mut failures = Vec::new();
    for r in results {
        match r {
            Ok((_, SessionState::Done {
                stop_reason: StopReason::EndTurn,
            })) => {}
            Ok((i, other)) => failures.push(format!("session #{i} ended in {other:?}")),
            Err(e) => failures.push(format!("task error: {e}")),
        }
    }
    if !failures.is_empty() {
        bail!("S4 FAILED: {failures:?}");
    }

    // Tidy up — manager.archive each.
    for r in &runners {
        let _ = manager
            .archive(r.id(), ycode_worktree::CleanupMode::DeleteBranch)
            .await;
    }
    drop(workdir);
    drop(keeps);

    info!("smoke echo-parallel: PASS ({N} sessions reached Done)");
    Ok(())
}

/// Tiny dependency-free `join_all` so we don't pull in `futures` as a CLI
/// dep. Sequential await of the resolved futures *after* all are queued via
/// `tokio::spawn` so they can race.
async fn futures_join_all<F, T>(futures: impl IntoIterator<Item = F>) -> Vec<T>
where
    F: std::future::Future<Output = T> + Send + 'static,
    T: Send + 'static,
{
    let handles: Vec<_> = futures.into_iter().map(tokio::spawn).collect();
    let mut out = Vec::with_capacity(handles.len());
    for h in handles {
        out.push(h.await.expect("spawned task panicked"));
    }
    out
}
