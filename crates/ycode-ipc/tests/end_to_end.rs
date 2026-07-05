//! End-to-end integration: drive the IPC `Service` through a full session
//! lifecycle using a real /bin/sh under a PTY.

use std::time::Duration;

use camino::Utf8PathBuf;
use tokio::time::timeout;
use ycode_config::{AgentLaunchProfile, Config};
use ycode_ipc::{
    CreateProjectRequest, CreateSessionRequest, ResizePtyRequest, Service, UiEventKind,
    WriteFileRequest, WritePtyRequest,
};
use ycode_persist::Db;

fn shell_profile(id: &str) -> AgentLaunchProfile {
    AgentLaunchProfile {
        id: id.into(),
        display_name: Some(format!("shell-{id}")),
        command: "/bin/sh".into(),
        args: vec![],
        env: Default::default(),
        icon: None,
        icon_variant: None,
        color: None,
        introspect: None,
    }
}

async fn fixture() -> (Service, tempfile::TempDir, Utf8PathBuf) {
    let db = Db::open_in_memory().await.unwrap();
    let mut config = Config::default();
    // Wipe defaults; tests want a known agent set.
    config.agents.clear();
    config.agents.push(shell_profile("shell-test"));

    let workdir = tempfile::tempdir().unwrap();
    let repo_path = Utf8PathBuf::from_path_buf(workdir.path().to_path_buf()).unwrap();
    // Tests use a plain (non-git) temp dir as the repo, so isolation degrades
    // to shared mode and this root is never actually used.
    let service = Service::new(db, config, repo_path.join(".ycode-worktrees"));
    (service, workdir, repo_path)
}

#[tokio::test(flavor = "multi_thread")]
async fn list_agents_marks_shell_available() {
    let (svc, _w, _r) = fixture().await;
    let agents = svc.list_agents().await;
    let shell = agents.iter().find(|a| a.id == "shell-test").unwrap();
    assert!(shell.available, "/bin/sh should be on PATH");
}

#[tokio::test(flavor = "multi_thread")]
async fn full_session_lifecycle() {
    use base64::Engine;
    let (svc, _w, repo) = fixture().await;
    let mut rx = svc.subscribe();

    let project = svc
        .create_project(CreateProjectRequest {
            name: "ipc-smoke".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();
    // Drain the ProjectAppeared event.
    let _ = rx.recv().await;

    let view = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "shell-test".into(),
            project_id: project.id.clone(),
            title: "ipc-smoke".into(),
            resume: None,
        })
        .await
        .unwrap();
    let session_id = view.id.clone();

    // Write `exit 0\n` so the shell terminates deterministically.
    let payload = base64::engine::general_purpose::STANDARD.encode(b"exit 0\n");
    svc.write_pty(WritePtyRequest {
        session_id: session_id.clone(),
        data: payload,
    })
    .await
    .unwrap();

    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    let mut saw_appeared = false;
    let mut saw_output = false;
    let mut saw_exit = false;
    while tokio::time::Instant::now() < deadline && !saw_exit {
        let ev = match timeout(Duration::from_millis(500), rx.recv()).await {
            Ok(Ok(ev)) => ev,
            Ok(Err(_)) => break,
            Err(_) => continue,
        };
        match &ev.kind {
            UiEventKind::SessionAppeared => saw_appeared = true,
            UiEventKind::PtyOutput { .. } => saw_output = true,
            UiEventKind::PtyExit { .. } => saw_exit = true,
            _ => {}
        }
    }
    assert!(saw_appeared);
    assert!(saw_output, "should have observed PTY output");
    assert!(saw_exit);

    // After exit, the session should still appear in list_sessions until
    // archived — but with status Exited.
    let listing = svc.list_sessions().await.unwrap();
    let after = listing.iter().find(|s| s.id == session_id).unwrap();
    assert!(matches!(
        after.status,
        ycode_ipc::SessionStatus::Exited { .. }
    ));

    svc.archive_session(session_id.clone()).await.unwrap();
    let listing = svc.list_sessions().await.unwrap();
    assert!(!listing.iter().any(|s| s.id == session_id));
}

#[tokio::test(flavor = "multi_thread")]
async fn resize_works_on_live_session() {
    let (svc, _w, repo) = fixture().await;
    let project = svc
        .create_project(CreateProjectRequest {
            name: "ipc-resize".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();
    let view = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "shell-test".into(),
            project_id: project.id,
            title: "resize".into(),
            resume: None,
        })
        .await
        .unwrap();
    svc.resize_pty(ResizePtyRequest {
        session_id: view.id.clone(),
        cols: 100,
        rows: 30,
    })
    .await
    .unwrap();
    // No public way to read back PTY dims; success is no error.
    svc.kill_session(view.id).await.unwrap();
}

#[tokio::test(flavor = "multi_thread")]
async fn list_files_respects_gitignore() {
    let (svc, _w, repo) = fixture().await;

    // `ignore` only honours .gitignore inside a real git repo by default;
    // mirror that so the test reflects real ycode usage.
    let init = std::process::Command::new("git")
        .args(["init", "-b", "main"])
        .current_dir(repo.as_std_path())
        .output()
        .unwrap();
    assert!(init.status.success(), "git init failed");

    // Seed: one tracked file, one git-ignored file, one git-ignored dir.
    std::fs::write(repo.join("README.md").as_std_path(), "hi").unwrap();
    std::fs::write(
        repo.join(".gitignore").as_std_path(),
        "target/\nsecret.txt\n",
    )
    .unwrap();
    std::fs::create_dir_all(repo.join("target").as_std_path()).unwrap();
    std::fs::write(repo.join("target/build.log").as_std_path(), "noise").unwrap();
    std::fs::write(repo.join("secret.txt").as_std_path(), "shh").unwrap();
    std::fs::create_dir_all(repo.join("src").as_std_path()).unwrap();
    std::fs::write(repo.join("src/lib.rs").as_std_path(), "//").unwrap();

    let project = svc
        .create_project(CreateProjectRequest {
            name: "files".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();

    let entries = svc.list_files(project.id).await.unwrap();
    let paths: Vec<&str> = entries.iter().map(|e| e.path.as_str()).collect();
    assert!(paths.contains(&"README.md"));
    assert!(paths.contains(&".gitignore"));
    assert!(paths.contains(&"src"));
    assert!(paths.contains(&"src/lib.rs"));
    assert!(!paths.iter().any(|p| p.starts_with("target")));
    assert!(!paths.contains(&"secret.txt"));
}

#[tokio::test(flavor = "multi_thread")]
async fn create_session_with_bad_project_errors() {
    let (svc, _w, _r) = fixture().await;
    let err = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "shell-test".into(),
            project_id: "nonexistent".into(),
            title: "x".into(),
            resume: None,
        })
        .await
        .unwrap_err();
    assert!(matches!(
        err,
        ycode_ipc::IpcError::Persist(ycode_persist::PersistError::ProjectNotFound(_))
    ));
}

#[tokio::test(flavor = "multi_thread")]
async fn create_session_with_unknown_agent_errors_without_persisting_row() {
    let (svc, _w, repo) = fixture().await;
    let project = svc
        .create_project(CreateProjectRequest {
            name: "unknown-agent".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();

    let err = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "missing-agent".into(),
            project_id: project.id,
            title: "x".into(),
            resume: None,
        })
        .await
        .unwrap_err();

    assert!(matches!(err, ycode_ipc::IpcError::UnknownAgentProfile(_)));
    assert!(svc.list_sessions().await.unwrap().is_empty());
}

#[tokio::test(flavor = "multi_thread")]
async fn read_write_and_resolve_files_stay_inside_project_root() {
    let (svc, _w, repo) = fixture().await;
    std::fs::create_dir_all(repo.join("src").as_std_path()).unwrap();
    std::fs::write(repo.join("src/main.ts").as_std_path(), "old").unwrap();

    let project = svc
        .create_project(CreateProjectRequest {
            name: "files-rw".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();

    svc.write_file(WriteFileRequest {
        project_id: project.id.clone(),
        file_path: "src/main.ts".into(),
        contents: "new contents".into(),
    })
    .await
    .unwrap();
    let file = svc
        .read_file(project.id.clone(), "src/main.ts".into())
        .await
        .unwrap();
    assert!(!file.is_binary);
    assert_eq!(file.contents, "new contents");

    assert_eq!(
        svc.resolve_terminal_path(project.id.clone(), "./src/main.ts".into())
            .await
            .unwrap()
            .as_deref(),
        Some("src/main.ts")
    );
    assert!(svc
        .read_file(project.id.clone(), "../outside.txt".into())
        .await
        .is_err());
    assert!(svc
        .write_file(WriteFileRequest {
            project_id: project.id,
            file_path: "../outside.txt".into(),
            contents: "bad".into(),
        })
        .await
        .is_err());
}

#[tokio::test(flavor = "multi_thread")]
async fn delete_project_archives_live_sessions_and_removes_project() {
    let (svc, _w, repo) = fixture().await;
    let project = svc
        .create_project(CreateProjectRequest {
            name: "delete-project".into(),
            repo_path: repo.to_string(),
        })
        .await
        .unwrap();
    let view = svc
        .create_session(CreateSessionRequest {
            agent_profile_id: "shell-test".into(),
            project_id: project.id.clone(),
            title: "delete me".into(),
            resume: None,
        })
        .await
        .unwrap();

    svc.delete_project(project.id.clone()).await.unwrap();

    assert!(!svc
        .list_sessions()
        .await
        .unwrap()
        .iter()
        .any(|s| s.id == view.id));
    assert!(!svc
        .list_projects()
        .await
        .unwrap()
        .iter()
        .any(|p| p.id == project.id));
}
