//! End-to-end integration: drive the IPC `Service` through a full session
//! lifecycle using the EchoAdapter.

use std::process::Command;
use std::sync::Arc;
use std::time::Duration;

use camino::Utf8PathBuf;
use tokio::time::timeout;
use ycode_adapter::{AgentEvent, BoxedAdapter, SessionState};
use ycode_config::{AdapterKind, AgentLaunchProfile, Config};
use ycode_core::{ManagerError, SessionManager};
use ycode_echo_adapter::EchoAdapter;
use ycode_ipc::{
    AnswerPermissionRequest, CreateSessionRequest, SendPromptRequest, Service, UiEventKind,
};
use ycode_persist::Db;
use ycode_worktree::WorktreeManager;

fn init_repo(dir: &Utf8PathBuf) {
    std::fs::create_dir_all(dir.as_std_path()).unwrap();
    let runs = [
        ["init", "-b", "main"].as_slice(),
        ["config", "user.email", "test@example.com"].as_slice(),
        ["config", "user.name", "ycode-test"].as_slice(),
        ["config", "commit.gpgsign", "false"].as_slice(),
    ];
    for args in runs {
        let out = Command::new("git")
            .args(args)
            .current_dir(dir.as_std_path())
            .output()
            .unwrap();
        assert!(out.status.success(), "git {args:?} failed");
    }
    std::fs::write(dir.join("README.md").as_std_path(), "hi").unwrap();
    let out = Command::new("git")
        .args(["add", "."])
        .current_dir(dir.as_std_path())
        .output()
        .unwrap();
    assert!(out.status.success());
    let out = Command::new("git")
        .args(["commit", "-m", "init"])
        .current_dir(dir.as_std_path())
        .output()
        .unwrap();
    assert!(out.status.success());
}

async fn fixture() -> (Service, tempfile::TempDir, Utf8PathBuf) {
    let db = Db::open_in_memory().await.unwrap();
    let workdir = tempfile::tempdir().unwrap();
    let workdir_path =
        Utf8PathBuf::from_path_buf(workdir.path().to_path_buf()).unwrap();
    let manager = SessionManager::new(db, WorktreeManager::new(workdir_path.join("worktrees")));
    manager
        .register_factory(
            "echo",
            Arc::new(|_p: &AgentLaunchProfile| -> Result<BoxedAdapter, ManagerError> {
                Ok(Box::new(EchoAdapter::new()))
            }),
        )
        .await;

    let mut config = Config::default();
    config.agents.push(AgentLaunchProfile {
        id: "echo-it".into(),
        display_name: Some("Echo (test)".into()),
        kind: AdapterKind::Echo,
        command: "/bin/true".into(),
        args: vec![],
        env: Default::default(),
        heuristic_profile: None,
    });

    let service = Service::new(Arc::new(manager), config);
    let repo_dir = tempfile::tempdir().unwrap();
    let repo_path = Utf8PathBuf::from_path_buf(repo_dir.path().to_path_buf()).unwrap();
    init_repo(&repo_path);
    // Leak the repo dir for the test's lifetime.
    std::mem::forget(repo_dir);
    (service, workdir, repo_path)
}

#[tokio::test]
async fn list_agents_includes_echo_profile() {
    let (svc, _w, _r) = fixture().await;
    let agents = svc.list_agents().await;
    assert!(agents.iter().any(|a| a.id == "echo-it"));
}

#[tokio::test]
async fn full_session_lifecycle_through_service() {
    let (svc, _workdir, repo) = fixture().await;
    let mut events_rx = svc.subscribe();

    // Create session.
    let view = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "echo-it".into(),
            repo_path: repo.to_string(),
            title: "ipc-smoke".into(),
        })
        .await
        .unwrap();
    assert!(view.is_live);
    let session_id = view.id.clone();

    // We expect a SessionAppeared event plus several Agent events.
    let mut saw_appeared = false;
    let mut saw_done = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);

    // Send the prompt now that the session is in Idle.
    svc.send_prompt(SendPromptRequest {
        session_id: session_id.clone(),
        text: "hi".into(),
    })
    .await
    .unwrap();

    while tokio::time::Instant::now() < deadline && !saw_done {
        let ev = match timeout(Duration::from_millis(500), events_rx.recv()).await {
            Ok(Ok(ev)) => ev,
            Ok(Err(_)) => break,
            Err(_) => continue,
        };
        match &ev.kind {
            UiEventKind::SessionAppeared => saw_appeared = true,
            UiEventKind::Agent {
                event:
                    AgentEvent::StateChanged {
                        state: SessionState::Done { .. },
                    },
            } => saw_done = true,
            _ => {}
        }
    }
    assert!(saw_appeared, "SessionAppeared should have fired");
    assert!(saw_done, "Done state should have arrived");

    // Replay should yield non-empty transcript.
    let transcript = svc
        .replay_events(ycode_ipc::ReplayRequest {
            session_id: session_id.clone(),
            from_seq: 0,
        })
        .await
        .unwrap();
    assert!(!transcript.is_empty(), "transcript should have entries");

    // Archive.
    svc.archive_session(session_id.clone(), false).await.unwrap();
    let listing = svc.list_sessions().await.unwrap();
    assert!(
        !listing.iter().any(|s| s.id == session_id),
        "archived session should not appear in list_sessions"
    );
}

#[tokio::test]
async fn permission_round_trip_through_service() {
    let (svc, _workdir, repo) = fixture().await;

    let view = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "echo-it".into(),
            repo_path: repo.to_string(),
            title: "ipc-perm".into(),
        })
        .await
        .unwrap();
    let session_id = view.id.clone();

    let mut events_rx = svc.subscribe();

    svc.send_prompt(SendPromptRequest {
        session_id: session_id.clone(),
        text: "permission: write hello.txt".into(),
    })
    .await
    .unwrap();

    // Wait for the AwaitingPermission event, grab the request_id.
    let request_id = loop {
        let ev = events_rx.recv().await.expect("event");
        if let UiEventKind::Agent {
            event:
                AgentEvent::StateChanged {
                    state:
                        SessionState::AwaitingPermission {
                            request_id, ..
                        },
                },
        } = ev.kind
        {
            break request_id;
        }
    };

    svc.answer_permission(AnswerPermissionRequest {
        session_id: session_id.clone(),
        request_id,
        option_id: "allow_once".into(),
    })
    .await
    .unwrap();

    // Drive to Done.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut saw_done = false;
    while tokio::time::Instant::now() < deadline && !saw_done {
        if let Ok(ev) = timeout(Duration::from_millis(500), events_rx.recv()).await {
            if let Ok(ev) = ev {
                if let UiEventKind::Agent {
                    event:
                        AgentEvent::StateChanged {
                            state: SessionState::Done { .. },
                        },
                } = ev.kind
                {
                    saw_done = true;
                }
            }
        }
    }
    assert!(saw_done);
}
