//! Headless smoke-test entry point.
//!
//! Hosts the verification scenarios from the plan (S1–S6). Each scenario is a
//! self-contained pass: setup → drive a `SessionRunner` → assert terminal
//! state → exit non-zero on failure. NDJSON transcript goes to stdout for
//! debuggability; logs go to stderr.

use std::path::PathBuf;
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use clap::{Parser, Subcommand};
use tokio::sync::broadcast::error::RecvError;
use tracing_subscriber::EnvFilter;
use ycode_adapter::{AgentEvent, BoxedAdapter, SessionState, SpawnSpec, StopReason};
use ycode_core::{is_terminal, SessionRunner, SessionStart};
use ycode_persist::Db;

mod scenarios;
mod support;

#[derive(Parser)]
#[command(version, about = "ycode headless smoke runner")]
struct Cli {
    #[command(subcommand)]
    cmd: Cmd,
}

#[derive(Subcommand)]
enum Cmd {
    /// Run a verification scenario.
    Smoke {
        #[command(subcommand)]
        scenario: Scenario,
    },
}

#[derive(Subcommand)]
enum Scenario {
    /// Echo adapter happy path. No API key, no subprocess. Asserts the
    /// adapter abstraction is loose enough to admit an in-process toy.
    Echo,
    /// Echo adapter permission round-trip. Validates RequestPermission →
    /// AwaitingPermission → answer_permission → Running → Done.
    EchoPermission,
    /// Cancel mid-permission. Validates the orchestrator's cancel path
    /// reaches Done(Cancelled).
    EchoCancel,
    /// S4-style: 3 echo sessions concurrently via SessionManager. Validates
    /// the manager handles parallel sessions without contention.
    EchoParallel,
    /// S5-style: detach a session (crash simulation), then restart it via
    /// SessionManager. Validates the restart pathway preserves session id
    /// while spawning a fresh adapter.
    EchoRestart,
    /// S6: measure the LoC budget for the echo adapter. Fails if > 500.
    LocGate,
    /// S1: Claude Code via ACP. Requires ANTHROPIC_API_KEY and
    /// `claude-code-acp` on PATH.
    AcpClaude {
        /// Repo to spawn the worktree from.
        #[arg(long)]
        repo: PathBuf,
        #[arg(long, default_value = "Hello, claude.")]
        prompt: String,
    },
    /// S2: Gemini CLI via ACP, cancel mid-turn. Requires GEMINI_API_KEY and
    /// `gemini` on PATH (with `--experimental-acp` support).
    AcpGemini {
        /// Repo to spawn the worktree from.
        #[arg(long)]
        repo: PathBuf,
        /// Override the default long prompt; the default is intentionally
        /// verbose so cancel can land while the agent is still streaming.
        #[arg(long)]
        prompt: Option<String>,
    },
    /// S3: Codex via the PTY adapter (heuristic profile). Requires
    /// OPENAI_API_KEY and `codex` on PATH.
    PtyCodex {
        /// Repo to spawn the worktree from.
        #[arg(long)]
        repo: PathBuf,
        #[arg(long)]
        prompt: Option<String>,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")))
        .with_writer(std::io::stderr)
        .try_init();

    let cli = Cli::parse();
    match cli.cmd {
        Cmd::Smoke { scenario } => match scenario {
            Scenario::Echo => scenarios::echo::run().await,
            Scenario::EchoPermission => scenarios::echo_permission::run().await,
            Scenario::EchoCancel => scenarios::echo_cancel::run().await,
            Scenario::EchoParallel => scenarios::echo_parallel::run().await,
            Scenario::EchoRestart => scenarios::echo_restart::run().await,
            Scenario::LocGate => scenarios::loc_gate::run(),
            Scenario::AcpClaude { repo, prompt } => {
                scenarios::acp_claude::run(repo, prompt).await
            }
            Scenario::AcpGemini { repo, prompt } => {
                scenarios::acp_gemini::run(repo, prompt).await
            }
            Scenario::PtyCodex { repo, prompt } => {
                scenarios::pty_codex::run(repo, prompt).await
            }
        },
    }
}

/// Helper: drive a session to a terminal state, emitting NDJSON for every
/// event. Returns the terminal state.
pub(crate) async fn drive_to_terminal(
    runner: &SessionRunner,
    timeout: Duration,
) -> Result<SessionState> {
    let mut rx = runner.subscribe();
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            bail!("timed out waiting for terminal state");
        }
        match tokio::time::timeout(deadline - now, rx.recv()).await {
            Ok(Ok(event)) => {
                emit_ndjson(&event);
                if let AgentEvent::StateChanged { state } = &event {
                    if is_terminal(state) {
                        return Ok(state.clone());
                    }
                }
            }
            Ok(Err(RecvError::Lagged(n))) => {
                eprintln!("(lagged {n} events; transcript truncated)");
            }
            Ok(Err(RecvError::Closed)) => {
                return Ok(runner.state().await);
            }
            Err(_) => bail!("timed out waiting for terminal state"),
        }
    }
}

fn emit_ndjson(event: &AgentEvent) {
    match serde_json::to_string(event) {
        Ok(s) => println!("{s}"),
        Err(e) => eprintln!("(failed to serialize event: {e})"),
    }
}

/// Helper: build a `SessionStart` for adapters that don't need a real
/// worktree. Uses a tempdir for `cwd`. Returned `_keep` must outlive the
/// session.
pub(crate) fn dummy_start(profile: &str, title: &str) -> Result<(SessionStart, tempfile::TempDir)> {
    let dir = tempfile::tempdir().context("creating tempdir for dummy worktree")?;
    let dir_utf8 = camino::Utf8PathBuf::from_path_buf(dir.path().to_path_buf())
        .map_err(|p| anyhow!("tempdir path is not UTF-8: {}", p.display()))?;
    let spec = SpawnSpec {
        cwd: dir_utf8.clone(),
        env: vec![],
        command: "/bin/true".into(),
        args: vec![],
    };
    let start = SessionStart {
        id: ulid::Ulid::new().to_string(),
        title: title.into(),
        agent_profile: profile.into(),
        repo_root: dir_utf8.clone(),
        worktree_path: dir_utf8,
        branch: "ycode/smoke".into(),
        base_ref: "0000000".into(),
        spawn_spec: spec,
    };
    Ok((start, dir))
}

/// Helper: open an in-memory DB for scenarios that don't need persistence
/// across runs.
pub(crate) async fn temp_db() -> Result<Db> {
    Db::open_in_memory()
        .await
        .context("opening in-memory database")
}

/// Helper: terminal state matches `Done(EndTurn)`.
pub(crate) fn assert_done_endturn(state: &SessionState) -> Result<()> {
    match state {
        SessionState::Done {
            stop_reason: StopReason::EndTurn,
        } => Ok(()),
        other => Err(anyhow!("expected Done(EndTurn), got {:?}", other)),
    }
}

/// Helper: build an adapter via boxed factory.
pub(crate) fn boxed<A: ycode_adapter::AgentAdapter + 'static>(a: A) -> BoxedAdapter {
    Box::new(a)
}
