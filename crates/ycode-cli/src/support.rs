//! Shared scaffolding for smoke scenarios.
//!
//! Lives outside `scenarios/` because both individual scenarios AND `main`
//! depend on it — registering adapter factories happens once at startup, not
//! per-scenario.

use std::process::Command;

use anyhow::{anyhow, Context, Result};
use camino::Utf8PathBuf;
use std::sync::Arc;
use ycode_acp_adapter::AcpAdapter;
use ycode_adapter::BoxedAdapter;
use ycode_config::AgentLaunchProfile;
use ycode_core::{ManagerError, SessionManager};
use ycode_echo_adapter::EchoAdapter;
use ycode_pty_adapter::{PtyAdapter, PtyAdapterConfig};

/// Register the three real-world adapter factories. Idempotent — last writer
/// wins per the manager contract.
pub async fn register_factories(manager: &SessionManager) {
    manager
        .register_factory(
            "echo",
            Arc::new(|_profile: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                Ok(Box::new(EchoAdapter::new()))
            }),
        )
        .await;
    manager
        .register_factory(
            "acp",
            Arc::new(|_profile: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                Ok(Box::new(AcpAdapter::new()))
            }),
        )
        .await;
    manager
        .register_factory(
            "pty",
            Arc::new(|profile: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                let heuristic_profile = profile
                    .heuristic_profile
                    .clone()
                    .ok_or_else(|| ManagerError::Factory(format!(
                        "PTY profile `{}` missing heuristic_profile",
                        profile.id
                    )))?;
                Ok(Box::new(PtyAdapter::new(PtyAdapterConfig {
                    heuristic_profile,
                })))
            }),
        )
        .await;
}

/// Build an `AgentLaunchProfile` for the in-process echo adapter. Used by
/// scenarios that drive the manager directly.
pub fn echo_profile() -> AgentLaunchProfile {
    AgentLaunchProfile {
        id: "echo-smoke".into(),
        display_name: Some("Echo (smoke)".into()),
        kind: ycode_config::AdapterKind::Echo,
        command: "/bin/true".into(),
        args: vec![],
        env: Default::default(),
        heuristic_profile: None,
    }
}

/// Initialise a tempdir as a single-commit git repo. Used by smoke scenarios
/// that go through `WorktreeManager::detect_repo`.
pub fn init_git_repo(dir: &Utf8PathBuf) -> Result<()> {
    std::fs::create_dir_all(dir.as_std_path())?;
    run_git(dir, &["init", "-b", "main"])?;
    run_git(dir, &["config", "user.email", "ycode-smoke@example.com"])?;
    run_git(dir, &["config", "user.name", "ycode-smoke"])?;
    run_git(dir, &["config", "commit.gpgsign", "false"])?;
    std::fs::write(dir.join("README.md").as_std_path(), "smoke")?;
    run_git(dir, &["add", "."])?;
    run_git(dir, &["commit", "-m", "initial"])?;
    Ok(())
}

fn run_git(cwd: &Utf8PathBuf, args: &[&str]) -> Result<()> {
    let out = Command::new("git")
        .args(args)
        .current_dir(cwd.as_std_path())
        .output()
        .with_context(|| format!("running git {args:?}"))?;
    if !out.status.success() {
        return Err(anyhow!(
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        ));
    }
    Ok(())
}
