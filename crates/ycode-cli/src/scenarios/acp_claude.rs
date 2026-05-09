//! S1: drive Claude Code via ACP through a single happy-path turn.
//!
//! Live test — requires `claude-code-acp` on PATH and `ANTHROPIC_API_KEY`. CI
//! gates this behind a `live` feature/label so unit runs don't burn credit.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{bail, Context, Result};
use camino::Utf8PathBuf;
use tracing::info;
use ycode_acp_adapter::AcpAdapter;
use ycode_adapter::SpawnSpec;
use ycode_core::{SessionRunner, SessionStart};
use ycode_persist::Db;
use ycode_worktree::{CleanupMode, WorktreeManager};

use crate::{assert_done_endturn, boxed, drive_to_terminal};

pub async fn run(repo: PathBuf, prompt: String) -> Result<()> {
    // claude-code-acp refuses to spawn inside an existing Claude Code session
    // (it errors `session/new` with -32603). The smoke runner inherits its
    // env into the child, so scrub the marker before spawning. Harmless on
    // hosts where the var was never set.
    // SAFETY: called before any spawn / async work; single-threaded.
    std::env::remove_var("CLAUDECODE");

    let repo = Utf8PathBuf::from_path_buf(repo)
        .map_err(|p| anyhow::anyhow!("repo path is not UTF-8: {}", p.display()))?;

    let workdir = tempfile::tempdir().context("worktree root tempdir")?;
    let workdir_utf8 = Utf8PathBuf::from_path_buf(workdir.path().to_path_buf())
        .map_err(|p| anyhow::anyhow!("tempdir not UTF-8: {}", p.display()))?;
    let mgr = WorktreeManager::new(workdir_utf8);
    let info = mgr.detect_repo(&repo)?;
    let session_id = ulid::Ulid::new().to_string();
    let wt = mgr.create_for_session(&info, &session_id)?;

    let db = Db::open_in_memory().await?;
    // Adapter spawn inherits the parent process env, so the user's existing
    // auth (ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN+ANTHROPIC_BASE_URL /
    // local `claude login` keychain entry) flows through unchanged. No need
    // to require any specific shape here.
    let spec = SpawnSpec {
        cwd: wt.worktree_path.clone(),
        env: vec![],
        command: "claude-code-acp".into(),
        args: vec![],
    };

    let start = SessionStart {
        id: session_id,
        title: "smoke-acp-claude".into(),
        agent_profile: "claude-code".into(),
        repo_root: wt.repo_root.clone(),
        worktree_path: wt.worktree_path.clone(),
        branch: wt.branch.clone(),
        base_ref: wt.base_ref.clone(),
        spawn_spec: spec,
    };

    let runner = SessionRunner::start(db, boxed(AcpAdapter::new()), start).await?;

    runner.prompt(prompt).await?;
    let final_state = drive_to_terminal(&runner, Duration::from_secs(120)).await;

    let _ = runner.shutdown().await;
    let _ = mgr.cleanup(&wt, CleanupMode::KeepBranch);

    let final_state = final_state?;
    if let Err(e) = assert_done_endturn(&final_state) {
        bail!("S1 FAILED: {e}");
    }
    info!("smoke acp-claude: PASS");
    Ok(())
}
