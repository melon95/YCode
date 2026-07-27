//! Control socket for the `ycode-mcp` sidecar.
//!
//! `ycode-mcp` is a small stdio MCP server that AI CLIs (Claude Code, Codex)
//! spawn as a child process. It exposes todo tools to the model but holds no
//! state itself — every tool call connects to *this* Unix domain socket, sends
//! one newline-terminated JSON request, and reads one newline-terminated JSON
//! response. We run the real logic here (project resolution + SQLite via the
//! [`Service`]) so the sidecar stays a thin, dependency-light bridge.
//!
//! Unlike [`notify_listener`](crate::notify_listener) — which is fire-and-
//! forget — this listener is request/response: `list` has to return data.
//!
//! Socket path is **stable** (not pid-scoped): the path is injected into the
//! PTY environment as `YCODE_MCP_SOCK` and inherited down to the MCP child,
//! and a stable path also lets a persisted MCP config keep working across app
//! restarts. The single-instance plugin keeps two ycode processes from racing
//! the same path; `bind` unlinks any stale file first.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::service::Service;

/// One request from the `ycode-mcp` sidecar. `terminal_id` / `cwd` are used to
/// resolve which project the call applies to (see [`resolve_project`]).
#[derive(Debug, Deserialize)]
struct McpRequest {
    #[serde(default)]
    terminal_id: Option<String>,
    #[serde(default)]
    cwd: Option<String>,
    /// `list` | `add` | `update` | `delete`.
    action: String,
    #[serde(default)]
    payload: serde_json::Value,
}

#[derive(Debug, Serialize)]
struct McpResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl McpResponse {
    fn ok(data: serde_json::Value) -> Self {
        Self {
            ok: true,
            data: Some(data),
            error: None,
        }
    }
    fn err(msg: impl Into<String>) -> Self {
        Self {
            ok: false,
            data: None,
            error: Some(msg.into()),
        }
    }
}

/// Stable per-user socket path under `$TMPDIR`. Mirrored by the `ycode-mcp`
/// binary as its default when `YCODE_MCP_SOCK` is unset.
pub fn default_socket_path() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    tmp.join("ycode-mcp.sock")
}

/// Bind the control socket and start the accept loop. Returns the bound path
/// (so callers can confirm it matches what they inject as `YCODE_MCP_SOCK`).
/// Bind failure is non-fatal — logged, returns `None`, MCP todo tools just
/// won't work until the next launch.
#[cfg(unix)]
pub fn start(
    service: Arc<Service>,
    cancel: CancellationToken,
    sock_path: PathBuf,
) -> Option<PathBuf> {
    use tokio::net::UnixListener;

    if sock_path.exists() {
        if let Err(e) = std::fs::remove_file(&sock_path) {
            warn!(path = %sock_path.display(), error = %e, "could not remove stale mcp socket");
            return None;
        }
    }

    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            warn!(path = %sock_path.display(), error = %e, "mcp socket bind failed; todo MCP disabled");
            return None;
        }
    };

    info!(path = %sock_path.display(), "mcp control listener started");
    let path_for_task = sock_path.clone();
    tokio::spawn(async move {
        run_accept_loop(listener, service, cancel).await;
        let _ = std::fs::remove_file(&path_for_task);
        debug!(path = %path_for_task.display(), "mcp control listener stopped");
    });

    Some(sock_path)
}

#[cfg(not(unix))]
pub fn start(
    _service: Arc<Service>,
    _cancel: CancellationToken,
    _sock_path: PathBuf,
) -> Option<PathBuf> {
    // Windows named-pipe support is deferred — Unix-only for now.
    None
}

#[cfg(unix)]
async fn run_accept_loop(
    listener: tokio::net::UnixListener,
    service: Arc<Service>,
    cancel: CancellationToken,
) {
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((stream, _addr)) => {
                    let service = service.clone();
                    tokio::spawn(async move {
                        handle_connection(stream, service).await;
                    });
                }
                Err(e) => {
                    warn!(error = %e, "mcp accept failed");
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            }
        }
    }
}

#[cfg(unix)]
async fn handle_connection(stream: tokio::net::UnixStream, service: Arc<Service>) {
    const MAX_PAYLOAD: usize = 128 * 1024;

    let (read_half, mut write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half).take(MAX_PAYLOAD as u64);
    let mut line = String::new();
    if let Err(e) = reader.read_line(&mut line).await {
        warn!(error = %e, "mcp read failed");
        return;
    }
    let line = line.trim();
    if line.is_empty() {
        return;
    }

    let response = match serde_json::from_str::<McpRequest>(line) {
        Ok(req) => handle_request(&service, req).await,
        Err(e) => McpResponse::err(format!("bad request json: {e}")),
    };

    let mut body = match serde_json::to_string(&response) {
        Ok(s) => s,
        Err(e) => format!(r#"{{"ok":false,"error":"serialize: {e}"}}"#),
    };
    body.push('\n');
    if let Err(e) = write_half.write_all(body.as_bytes()).await {
        debug!(error = %e, "mcp write failed (client gone?)");
    }
    let _ = write_half.flush().await;
}

/// Resolve the project a request targets: prefer `YCODE_TERMINAL_ID`
/// (terminal → session → project), fall back to matching `cwd` against known
/// project repo paths.
async fn resolve_project(service: &Service, req: &McpRequest) -> Result<String, String> {
    if let Some(tid) = req.terminal_id.as_deref() {
        if let Ok(pid) = service.project_id_for_terminal(tid).await {
            return Ok(pid);
        }
    }
    if let Some(cwd) = req.cwd.as_deref() {
        if let Ok(pid) = service.project_id_for_cwd(cwd).await {
            // Diagnosability: a single global socket serves every project, so a
            // cwd-based resolution (used only when YCODE_TERMINAL_ID didn't
            // propagate or was stale) is where a cross-project misroute would
            // happen. Log it so it's traceable rather than silent.
            warn!(
                cwd,
                project_id = %pid,
                terminal_id = ?req.terminal_id,
                "mcp project resolved via cwd fallback (YCODE_TERMINAL_ID unresolved)"
            );
            return Ok(pid);
        }
    }
    Err("could not determine project (no YCODE_TERMINAL_ID match and no cwd match)".into())
}

async fn handle_request(service: &Service, req: McpRequest) -> McpResponse {
    match req.action.as_str() {
        "list" => {
            let pid = match resolve_project(service, &req).await {
                Ok(p) => p,
                Err(e) => return McpResponse::err(e),
            };
            match service.list_todos(pid).await {
                Ok(todos) => match serde_json::to_value(todos) {
                    Ok(v) => McpResponse::ok(v),
                    Err(e) => McpResponse::err(format!("serialize: {e}")),
                },
                Err(e) => McpResponse::err(e.to_string()),
            }
        }
        "add" => {
            let pid = match resolve_project(service, &req).await {
                Ok(p) => p,
                Err(e) => return McpResponse::err(e),
            };
            let title = req
                .payload
                .get("title")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            match service.create_todo(pid, title).await {
                Ok(todo) => McpResponse::ok(serde_json::to_value(todo).unwrap_or_default()),
                Err(e) => McpResponse::err(e.to_string()),
            }
        }
        "update" => {
            let id = match req.payload.get("id").and_then(|v| v.as_str()) {
                Some(id) => id.to_string(),
                None => return McpResponse::err("update requires `id`"),
            };
            let title = req
                .payload
                .get("title")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            let status = req
                .payload
                .get("status")
                .and_then(|v| v.as_str())
                .map(str::to_string);
            if title.is_none() && status.is_none() {
                return McpResponse::err("update requires at least one of `title` / `status`");
            }
            match service.update_todo(id, title, status).await {
                Ok(todo) => McpResponse::ok(serde_json::to_value(todo).unwrap_or_default()),
                Err(e) => McpResponse::err(e.to_string()),
            }
        }
        "delete" => {
            let id = match req.payload.get("id").and_then(|v| v.as_str()) {
                Some(id) => id.to_string(),
                None => return McpResponse::err("delete requires `id`"),
            };
            match service.delete_todo(id).await {
                Ok(()) => McpResponse::ok(serde_json::Value::Null),
                Err(e) => McpResponse::err(e.to_string()),
            }
        }
        other => McpResponse::err(format!("unknown action: {other}")),
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::CreateProjectRequest;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
    use tokio::net::UnixStream;
    use ycode_config::Config;
    use ycode_persist::Db;

    fn unix_socket_bind_available() -> bool {
        let path =
            std::env::temp_dir().join(format!("ycode-mcp-probe-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let ok = std::os::unix::net::UnixListener::bind(&path).is_ok();
        let _ = std::fs::remove_file(&path);
        ok
    }

    /// One request/response round-trip over the control socket. Sends `line`,
    /// returns the parsed JSON response.
    async fn roundtrip(sock: &std::path::Path, line: &str) -> serde_json::Value {
        let stream = UnixStream::connect(sock).await.unwrap();
        let (r, mut w) = stream.into_split();
        let mut msg = line.to_string();
        msg.push('\n');
        w.write_all(msg.as_bytes()).await.unwrap();
        w.flush().await.unwrap();
        let mut reader = BufReader::new(r);
        let mut resp = String::new();
        reader.read_line(&mut resp).await.unwrap();
        serde_json::from_str(resp.trim()).unwrap()
    }

    #[tokio::test]
    async fn add_then_list_via_cwd_resolution() {
        if !unix_socket_bind_available() {
            eprintln!("skipping: unix socket bind not permitted");
            return;
        }

        let db = Db::open_in_memory().await.unwrap();
        let service = Arc::new(Service::new(
            db,
            Config::default(),
            camino::Utf8PathBuf::from("/tmp/ycode-mcp-test-wt"),
        ));

        // A real directory is required (create_project validates is_dir). Use
        // the temp dir as both the project repo and the request cwd so the
        // cwd-fallback resolver finds it.
        let repo = std::env::temp_dir();
        let repo_str = repo.to_string_lossy().to_string();
        service
            .create_project(CreateProjectRequest {
                name: "test".into(),
                repo_path: repo_str.clone(),
            })
            .await
            .unwrap();

        let sock = std::env::temp_dir().join(format!("ycode-mcp-test-{}.sock", std::process::id()));
        let cancel = CancellationToken::new();
        let bound = start(service.clone(), cancel.clone(), sock.clone()).expect("listener bound");

        // add
        let add = roundtrip(
            &bound,
            &serde_json::json!({
                "cwd": repo_str,
                "action": "add",
                "payload": { "title": "write tests" },
            })
            .to_string(),
        )
        .await;
        assert_eq!(add["ok"], true, "add failed: {add}");
        assert_eq!(add["data"]["title"], "write tests");
        assert_eq!(add["data"]["status"], "todo");

        // list
        let list = roundtrip(
            &bound,
            &serde_json::json!({ "cwd": repo_str, "action": "list" }).to_string(),
        )
        .await;
        assert_eq!(list["ok"], true);
        let arr = list["data"].as_array().unwrap();
        assert_eq!(arr.len(), 1);
        assert_eq!(arr[0]["title"], "write tests");

        cancel.cancel();
    }

    #[tokio::test]
    async fn unknown_project_errors() {
        if !unix_socket_bind_available() {
            eprintln!("skipping: unix socket bind not permitted");
            return;
        }
        let db = Db::open_in_memory().await.unwrap();
        let service = Arc::new(Service::new(
            db,
            Config::default(),
            camino::Utf8PathBuf::from("/tmp/ycode-mcp-test-wt"),
        ));
        let sock =
            std::env::temp_dir().join(format!("ycode-mcp-test2-{}.sock", std::process::id()));
        let cancel = CancellationToken::new();
        let bound = start(service, cancel.clone(), sock).expect("listener bound");

        let resp = roundtrip(
            &bound,
            &serde_json::json!({ "cwd": "/nonexistent/path", "action": "list" }).to_string(),
        )
        .await;
        assert_eq!(resp["ok"], false);
        assert!(resp["error"].as_str().unwrap().contains("project"));

        cancel.cancel();
    }
}
