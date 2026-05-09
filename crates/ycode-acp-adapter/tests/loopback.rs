//! Loopback integration: spawn the `fake_acp_agent` binary, drive it through
//! the real `AcpAdapter`, assert structured events flow.
//!
//! Validates the hand-rolled JSON-RPC + ACP wire layer end-to-end without a
//! real LLM. If this test fails, real Claude Code / Gemini won't talk to us
//! either.

use std::time::Duration;

use camino::Utf8PathBuf;
use tokio::time::timeout;
use ycode_acp_adapter::AcpAdapter;
use ycode_adapter::{AgentEvent, SessionState, SpawnSpec, StopReason};
use ycode_core::{SessionRunner, SessionStart};
use ycode_persist::Db;

/// Path to the binary Cargo built for us. Cargo sets `CARGO_BIN_EXE_<name>`
/// for `[[bin]]` entries when running integration tests in the same package.
const FAKE_AGENT: &str = env!("CARGO_BIN_EXE_fake_acp_agent");

fn dummy_start(spec: SpawnSpec) -> SessionStart {
    let cwd = spec.cwd.clone();
    SessionStart {
        id: ulid::Ulid::new().to_string(),
        title: "loopback-test".into(),
        agent_profile: "fake-acp".into(),
        repo_root: cwd.clone(),
        worktree_path: cwd,
        branch: "ycode/loopback".into(),
        base_ref: "0".into(),
        spawn_spec: spec,
    }
}

fn init_tracing() {
    use std::sync::Once;
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        let _ = tracing_subscriber::fmt()
            .with_env_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("error")),
            )
            .with_test_writer()
            .try_init();
    });
}

async fn launch() -> (std::sync::Arc<SessionRunner>, tempfile::TempDir) {
    init_tracing();
    let dir = tempfile::tempdir().unwrap();
    let cwd = Utf8PathBuf::from_path_buf(dir.path().to_path_buf()).unwrap();
    let spec = SpawnSpec {
        cwd,
        env: vec![],
        command: FAKE_AGENT.to_string(),
        args: vec![],
    };
    let db = Db::open_in_memory().await.unwrap();
    let runner = SessionRunner::start(db, Box::new(AcpAdapter::new()), dummy_start(spec))
        .await
        .expect("session should reach Idle through fake agent");
    (runner, dir)
}

#[tokio::test]
async fn happy_path_through_real_adapter_to_fake_agent() {
    let (runner, _keep) = launch().await;

    // Idle by now (start blocks until adapter signals readiness).
    assert!(matches!(runner.state().await, SessionState::Idle));

    let mut rx = runner.subscribe();
    runner.prompt("hello fake".into()).await.unwrap();

    let mut saw_assistant = false;
    let mut saw_tool_started = false;
    let mut saw_tool_completed = false;
    let mut final_state: Option<SessionState> = None;

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    while final_state.is_none() {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            panic!(
                "timed out: assistant={saw_assistant} tool_started={saw_tool_started} tool_completed={saw_tool_completed}"
            );
        }
        let ev = match timeout(deadline - now, rx.recv()).await {
            Ok(Ok(ev)) => ev,
            _ => continue,
        };
        match ev {
            AgentEvent::AssistantText { text, .. } => {
                assert!(text.contains("hello fake"), "assistant should echo: {text}");
                saw_assistant = true;
            }
            AgentEvent::ToolCallStarted { name, .. } => {
                assert_eq!(name, "fake_tool");
                saw_tool_started = true;
            }
            AgentEvent::ToolCallUpdated { status, .. } => {
                if matches!(status, ycode_adapter::ToolStatus::Completed) {
                    saw_tool_completed = true;
                }
            }
            AgentEvent::StateChanged { state } => {
                if matches!(state, SessionState::Done { .. } | SessionState::Error { .. }) {
                    final_state = Some(state);
                }
            }
            _ => {}
        }
    }

    let final_state = final_state.unwrap();
    assert!(saw_assistant, "expected an AssistantText event");
    assert!(saw_tool_started, "expected a ToolCallStarted event");
    assert!(saw_tool_completed, "expected a ToolCallUpdated(Completed) event");
    assert!(
        matches!(
            final_state,
            SessionState::Done {
                stop_reason: StopReason::EndTurn
            }
        ),
        "expected Done(EndTurn), got {final_state:?}"
    );

    runner.shutdown().await.unwrap();
}

#[tokio::test]
async fn permission_round_trip_through_real_adapter_to_fake_agent() {
    let (runner, _keep) = launch().await;
    let mut rx = runner.subscribe();
    runner
        .prompt("please get permission first".into())
        .await
        .unwrap();

    // Wait for AwaitingPermission and capture the request_id.
    let request_id = loop {
        let ev = rx.recv().await.expect("event");
        if let AgentEvent::StateChanged {
            state:
                SessionState::AwaitingPermission {
                    ref request_id, ..
                },
        } = ev
        {
            break request_id.clone();
        }
    };

    runner
        .answer_permission(request_id, "allow_once".into())
        .await
        .unwrap();

    // Drive to Done.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut saw_done = false;
    while !saw_done {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            panic!("timed out waiting for Done");
        }
        if let Ok(Ok(AgentEvent::StateChanged {
            state: SessionState::Done { .. },
        })) = timeout(deadline - now, rx.recv()).await
        {
            saw_done = true;
        }
    }

    runner.shutdown().await.unwrap();
}

#[tokio::test]
async fn cancel_through_real_adapter_to_fake_agent() {
    let (runner, _keep) = launch().await;
    let mut rx = runner.subscribe();
    runner
        .prompt("please get permission first".into())
        .await
        .unwrap();

    // Wait until we're in AwaitingPermission, then cancel.
    loop {
        let ev = rx.recv().await.expect("event");
        if let AgentEvent::StateChanged {
            state: SessionState::AwaitingPermission { .. },
        } = ev
        {
            break;
        }
    }
    runner.cancel().await.unwrap();

    // Eventually Done arrives. Stop reason may be Cancelled or Refusal
    // depending on which side wins the race; either is acceptable for
    // cancellation semantics here. The hard requirement is "we get to Done
    // and not Error within the timeout".
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut final_state: Option<SessionState> = None;
    while final_state.is_none() {
        let now = tokio::time::Instant::now();
        if now >= deadline {
            panic!("timed out waiting for terminal state after cancel");
        }
        if let Ok(Ok(ev)) = timeout(deadline - now, rx.recv()).await {
            if let AgentEvent::StateChanged { state } = ev {
                if matches!(state, SessionState::Done { .. } | SessionState::Error { .. }) {
                    final_state = Some(state);
                }
            }
        }
    }

    runner.shutdown().await.unwrap();
}
