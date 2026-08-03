//! Control socket for the `ycode` shell command.
//!
//! The `ycode-cli` binary (installed on the user's PATH as `ycode`) connects
//! here, sends one newline-terminated JSON request, and reads one
//! newline-terminated JSON response — the same wire shape as
//! [`mcp_listener`](crate::mcp_listener).
//!
//! Request:
//! ```json
//! {"action":"open","path":"/abs/dir","file":"/abs/dir/src/main.rs"}
//! ```
//! `file` is optional and absolute — we re-base it against the project we
//! resolve to, which need not be `path` (see [`relative_to_repo`]).
//!
//! Response: `{"ok":true,"data":{…}}` or `{"ok":false,"error":"…"}`.
//!
//! Opening resolves to an existing project when one already covers the folder
//! (exact match first, then the deepest enclosing repo — so `ycode
//! ~/repo/sub/dir` focuses the `~/repo` project rather than registering a
//! second, overlapping one). Otherwise a new project row is created.
//!
//! The *window* side is not handled here: this listener returns the resolved
//! project to the caller in the Tauri shell, which owns showing/focusing the
//! window. Keeping windows out of this crate preserves the transport-agnostic
//! boundary the rest of `ycode-ipc` maintains.
//!
//! Socket path is stable (not pid-scoped) because the CLI has to find it
//! without knowing the app's pid. The single-instance plugin keeps two ycode
//! processes from racing it, and `bind` unlinks a stale file first.

use std::path::PathBuf;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use tracing::{debug, info, warn};

use crate::service::Service;
use crate::ProjectView;

/// One request from the `ycode` command.
#[derive(Debug, Deserialize)]
struct CliRequest {
    /// Only `open` today; kept as a field so future verbs (`--goto`, `--diff`)
    /// don't need a wire-format break.
    action: String,
    #[serde(default)]
    path: Option<String>,
    /// Repo-relative file to focus, when the user pointed at a file.
    #[serde(default)]
    file: Option<String>,
}

#[derive(Debug, Serialize)]
struct CliResponse {
    ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    data: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl CliResponse {
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

/// What the shell decided the CLI wants shown, forwarded to the Tauri layer
/// so it can raise a window and tell the webview where to go.
#[derive(Debug, Clone, Serialize)]
pub struct CliOpenRequest {
    pub project: ProjectView,
    /// Repo-relative path of the file to focus, if any.
    pub file: Option<String>,
}

/// Stable per-user endpoint the CLI connects to. Mirrored by the `ycode-cli`
/// binary as its default when `YCODE_CLI_SOCK` is unset — keep both in sync
/// (`cli_endpoint_matches_the_cli_default` pins the Unix form).
///
/// Unix: a socket file under `$TMPDIR`. Windows: a named pipe, which is not a
/// filesystem path at all but is still carried as one so the two platforms
/// share a signature. The name is per-user because named pipes live in a
/// machine-global namespace — without the suffix, two logged-in users would
/// collide and the second app to start would find the name taken.
#[cfg(unix)]
pub fn default_socket_path() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"));
    tmp.join("ycode-cli.sock")
}

#[cfg(windows)]
pub fn default_socket_path() -> PathBuf {
    let user = std::env::var("USERNAME").unwrap_or_else(|_| "default".into());
    // Keep the name filesystem-safe: it's a pipe name, but it round-trips
    // through `PathBuf` and the CLI's argv/env.
    let user: String = user
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect();
    PathBuf::from(format!(r"\\.\pipe\ycode-cli-{user}"))
}

/// Bind the control socket and start the accept loop. Every successful `open`
/// is forwarded on `open_tx` so the shell can focus a window.
///
/// Returns the bound path, or `None` when binding failed — non-fatal, the app
/// just won't answer `ycode` invocations until the next launch.
#[cfg(unix)]
pub fn start(
    service: Arc<Service>,
    cancel: CancellationToken,
    sock_path: PathBuf,
    open_tx: mpsc::UnboundedSender<CliOpenRequest>,
) -> Option<PathBuf> {
    use tokio::net::UnixListener;

    if sock_path.exists() {
        if let Err(e) = std::fs::remove_file(&sock_path) {
            warn!(path = %sock_path.display(), error = %e, "could not remove stale cli socket");
            return None;
        }
    }

    let listener = match UnixListener::bind(&sock_path) {
        Ok(l) => l,
        Err(e) => {
            warn!(path = %sock_path.display(), error = %e, "cli socket bind failed; `ycode` command disabled");
            return None;
        }
    };

    // Restrict to the owner. macOS puts `$TMPDIR` in a per-user 0700 directory
    // so this is belt-and-braces there, but on Linux `TMPDIR` is typically
    // unset and we land in world-writable `/tmp`, where the default umask
    // leaves the socket connectable by every local user — enough for another
    // account to drive this app's UI or read the paths passed to `ycode`.
    // Best-effort: a chmod failure isn't worth disabling the command over.
    {
        use std::os::unix::fs::PermissionsExt;
        if let Err(e) =
            std::fs::set_permissions(&sock_path, std::fs::Permissions::from_mode(0o600))
        {
            warn!(path = %sock_path.display(), error = %e, "could not restrict cli socket permissions");
        }
    }

    info!(path = %sock_path.display(), "cli control listener started");
    let path_for_task = sock_path.clone();
    tokio::spawn(async move {
        run_accept_loop(listener, service, cancel, open_tx).await;
        let _ = std::fs::remove_file(&path_for_task);
        debug!(path = %path_for_task.display(), "cli control listener stopped");
    });

    Some(sock_path)
}

/// How many pipe instances listen concurrently.
///
/// A `NamedPipeServer` *is* a connection, not a factory: once a client attaches
/// to an instance, that instance is spoken for, and a client arriving while no
/// free instance exists gets `ERROR_PIPE_BUSY` rather than queueing. With a
/// single instance, the unavoidable gap between "client connected" and "we
/// created the replacement" is a busy window that two concurrent `ycode`
/// invocations hit reliably. A small pool makes that window require N
/// simultaneous clients instead of two; the client also retries on busy, so the
/// pool is defence in depth rather than the sole fix.
///
/// Each instance costs ~128 KiB of nonpaged pool (tokio's default in/out buffer
/// sizes), so this stays small.
#[cfg(windows)]
const PIPE_INSTANCES: usize = 4;

/// Windows: serve the same protocol over a named pipe.
///
/// Runs [`PIPE_INSTANCES`] independent accept tasks against the same name. Each
/// one waits for a client, hands the connected instance to a handler task, and
/// creates itself a fresh instance to wait on again.
#[cfg(windows)]
pub fn start(
    service: Arc<Service>,
    cancel: CancellationToken,
    sock_path: PathBuf,
    open_tx: mpsc::UnboundedSender<CliOpenRequest>,
) -> Option<PathBuf> {
    use tokio::net::windows::named_pipe::ServerOptions;

    let name = sock_path.to_string_lossy().to_string();
    // `first_pipe_instance` on the *first* instance only: it asserts nobody
    // else already owns this name (turning a silent hijack into a logged
    // startup warning). Setting it on the others would make them fail with
    // ERROR_ACCESS_DENIED, since the flag forbids further instances.
    let first = match ServerOptions::new().first_pipe_instance(true).create(&name) {
        Ok(s) => s,
        Err(e) => {
            warn!(pipe = %name, error = %e, "cli pipe bind failed; `ycode` command disabled");
            return None;
        }
    };

    info!(pipe = %name, instances = PIPE_INSTANCES, "cli control listener started");

    // Slot 0 adopts the instance we just created to prove the name was free;
    // the rest create their own on first iteration.
    let mut seed = Some(first);
    for _ in 0..PIPE_INSTANCES {
        tokio::spawn(serve_pipe_slot(
            name.clone(),
            seed.take(),
            service.clone(),
            cancel.clone(),
            open_tx.clone(),
        ));
    }

    Some(sock_path)
}

/// One accept loop: wait for a client, hand it off, create a fresh instance,
/// repeat. `seed` lets the first slot reuse the instance `start` already made.
#[cfg(windows)]
async fn serve_pipe_slot(
    name: String,
    seed: Option<tokio::net::windows::named_pipe::NamedPipeServer>,
    service: Arc<Service>,
    cancel: CancellationToken,
    open_tx: mpsc::UnboundedSender<CliOpenRequest>,
) {
    use tokio::net::windows::named_pipe::ServerOptions;

    let mut pending = seed;
    loop {
        if cancel.is_cancelled() {
            break;
        }
        // A pipe instance is consumed by the client that connects to it, and
        // one that errored is not reusable — so each iteration needs a fresh
        // instance rather than re-`connect`ing the old one (which would spin).
        let server = match pending.take() {
            Some(s) => s,
            None => match ServerOptions::new().create(&name) {
                Ok(s) => s,
                Err(e) => {
                    // Transient (nonpaged pool pressure) rather than fatal:
                    // back off and retry instead of killing the command for
                    // the rest of the app's lifetime.
                    warn!(error = %e, "cli pipe instance create failed; retrying");
                    tokio::select! {
                        biased;
                        _ = cancel.cancelled() => break,
                        _ = tokio::time::sleep(std::time::Duration::from_secs(1)) => continue,
                    }
                }
            },
        };

        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            connected = server.connect() => {
                if let Err(e) = connected {
                    warn!(error = %e, "cli pipe connect failed");
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                    continue;
                }
                let service = service.clone();
                let open_tx = open_tx.clone();
                tokio::spawn(async move {
                    let mut server = server;
                    handle_connection(&mut server, service, open_tx).await;
                    // Must happen before `server` drops — see `flush_pipe`.
                    flush_pipe(&server).await;
                });
            }
        }
    }
    debug!(pipe = %name, "cli pipe slot stopped");
}

#[cfg(unix)]
async fn run_accept_loop(
    listener: tokio::net::UnixListener,
    service: Arc<Service>,
    cancel: CancellationToken,
    open_tx: mpsc::UnboundedSender<CliOpenRequest>,
) {
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => return,
            accepted = listener.accept() => match accepted {
                Ok((mut stream, _addr)) => {
                    let service = service.clone();
                    let open_tx = open_tx.clone();
                    tokio::spawn(async move {
                        handle_connection(&mut stream, service, open_tx).await;
                    });
                }
                Err(e) => {
                    warn!(error = %e, "cli accept failed");
                    tokio::time::sleep(std::time::Duration::from_millis(50)).await;
                }
            }
        }
    }
}

/// Read one request, answer it, done. Generic over the transport so the Unix
/// socket and the Windows named pipe share this — the wire protocol is
/// identical, only the endpoint differs.
async fn handle_connection<S>(
    stream: &mut S,
    service: Arc<Service>,
    open_tx: mpsc::UnboundedSender<CliOpenRequest>,
) where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
{
    // Paths only — a few KiB is already generous.
    const MAX_PAYLOAD: usize = 16 * 1024;

    let (read_half, mut write_half) = tokio::io::split(stream);
    let mut reader = BufReader::new(read_half).take(MAX_PAYLOAD as u64);
    let mut line = String::new();
    if let Err(e) = reader.read_line(&mut line).await {
        warn!(error = %e, "cli read failed");
        return;
    }
    let line = line.trim();
    if line.is_empty() {
        return;
    }

    let response = match serde_json::from_str::<CliRequest>(line) {
        Ok(req) => handle_request(&service, req, &open_tx).await,
        Err(e) => CliResponse::err(format!("bad request json: {e}")),
    };

    let mut body = match serde_json::to_string(&response) {
        Ok(s) => s,
        Err(e) => format!(r#"{{"ok":false,"error":"serialize: {e}"}}"#),
    };
    body.push('\n');
    if let Err(e) = write_half.write_all(body.as_bytes()).await {
        debug!(error = %e, "cli write failed (client gone?)");
    }
    let _ = write_half.flush().await;
}

/// Block until the client has drained everything we wrote to `handle`.
///
/// Windows-only, and mandatory: closing the server end of a named pipe
/// **discards** whatever is still unread in the pipe buffer, and
/// `AsyncWriteExt::flush` does not prevent it — tokio's `poll_flush` for
/// `NamedPipeServer` is `Poll::Ready(Ok(()))`, a no-op that never reaches
/// `FlushFileBuffers`. Without this the reply can vanish and the user sees
/// "YCode closed the connection without responding" even though the open
/// succeeded. A Unix socket still delivers bytes written before `close`, hence
/// no equivalent there.
///
/// Called with the handle still owned by the live `NamedPipeServer`, and
/// best-effort: if the client already left there is nothing to salvage.
#[cfg(windows)]
async fn flush_pipe(stream: &tokio::net::windows::named_pipe::NamedPipeServer) {
    use std::os::windows::io::AsRawHandle;

    let handle = stream.as_raw_handle() as isize;
    // `FlushFileBuffers` blocks until the peer reads, so keep it off the
    // runtime's worker threads.
    let _ = tokio::task::spawn_blocking(move || {
        // SAFETY: `FlushFileBuffers` only blocks on the handle; it neither
        // frees nor invalidates it. The caller keeps `stream` — and therefore
        // the handle — alive across this await.
        unsafe { FlushFileBuffers(handle) };
    })
    .await;
}

#[cfg(windows)]
extern "system" {
    /// `BOOL FlushFileBuffers(HANDLE)` — declared directly rather than pulling
    /// in a Windows-bindings crate for one call.
    fn FlushFileBuffers(handle: isize) -> i32;
}

async fn handle_request(
    service: &Service,
    req: CliRequest,
    open_tx: &mpsc::UnboundedSender<CliOpenRequest>,
) -> CliResponse {
    match req.action.as_str() {
        "open" => {
            let Some(path) = req.path.filter(|p| !p.trim().is_empty()) else {
                return CliResponse::err("open requires `path`");
            };
            let project = match service.open_project_for_path(path).await {
                Ok(p) => p,
                Err(e) => return CliResponse::err(e.to_string()),
            };
            // Re-base the file against the project we actually resolved to.
            // The CLI sends an absolute path precisely because its own idea of
            // the root (nearest `.git`) can differ from ours (deepest
            // registered project) — e.g. a file inside a submodule of an
            // already-registered monorepo. Trusting a relative path computed
            // against the other root would open a different file with the same
            // suffix, silently.
            let file = req
                .file
                .filter(|f| !f.trim().is_empty())
                .and_then(|f| relative_to_repo(&f, &project.repo_path));
            let data = serde_json::json!({
                "project_id": project.id,
                "name": project.name,
                "repo_path": project.repo_path,
            });
            // Send *after* the project exists so the shell never receives an
            // id the webview can't resolve. A closed receiver means the app is
            // shutting down — the project row is still valid, so report the
            // failure rather than pretending the window opened.
            if open_tx.send(CliOpenRequest { project, file }).is_err()
            {
                return CliResponse::err("YCode is shutting down");
            }
            CliResponse::ok(data)
        }
        other => CliResponse::err(format!("unknown action: {other}")),
    }
}

/// Express an absolute file path relative to `repo_path`, using `/`
/// separators. Returns `None` when the file falls outside the repo — the
/// project is still opened, just without a focused file, which beats guessing
/// at a path the editor would resolve to something unrelated.
///
/// Older `ycode` binaries (pre-absolute-path) send an already-relative value;
/// those are passed through unchanged so a stale command on someone's PATH
/// keeps working after an app update.
fn relative_to_repo(file: &str, repo_path: &str) -> Option<String> {
    let file = std::path::Path::new(file);
    if file.is_relative() {
        return Some(file.to_string_lossy().replace('\\', "/"));
    }
    let repo = std::path::Path::new(repo_path);
    file.strip_prefix(repo)
        .ok()
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use tokio::io::BufReader as TokioBufReader;
    use tokio::net::UnixStream;
    use ycode_config::Config;
    use ycode_persist::Db;

    fn unix_socket_bind_available() -> bool {
        let path = std::env::temp_dir().join(format!("ycode-cli-probe-{}.sock", std::process::id()));
        let _ = std::fs::remove_file(&path);
        let ok = std::os::unix::net::UnixListener::bind(&path).is_ok();
        let _ = std::fs::remove_file(&path);
        ok
    }

    async fn roundtrip(sock: &std::path::Path, line: &str) -> serde_json::Value {
        let stream = UnixStream::connect(sock).await.unwrap();
        let (r, mut w) = stream.into_split();
        let mut msg = line.to_string();
        msg.push('\n');
        w.write_all(msg.as_bytes()).await.unwrap();
        w.flush().await.unwrap();
        let mut reader = TokioBufReader::new(r);
        let mut resp = String::new();
        reader.read_line(&mut resp).await.unwrap();
        serde_json::from_str(resp.trim()).unwrap()
    }

    async fn test_service() -> Arc<Service> {
        let db = Db::open_in_memory().await.unwrap();
        Arc::new(Service::new(
            db,
            Config::default(),
            camino::Utf8PathBuf::from("/tmp/ycode-cli-test-wt"),
        ))
    }

    /// Short /tmp path: macOS caps `sockaddr_un` at 104 bytes and `$TMPDIR`
    /// under `/var/folders/...` already eats most of that.
    fn short_sock(tag: &str) -> PathBuf {
        PathBuf::from(format!("/tmp/yc-cli-{tag}-{}.sock", std::process::id()))
    }

    #[tokio::test]
    async fn open_creates_project_and_forwards_focus_request() {
        if !unix_socket_bind_available() {
            eprintln!("skipping: unix socket bind not permitted");
            return;
        }
        let service = test_service().await;
        let repo = tempfile::tempdir_in("/tmp").unwrap();
        // Canonical form: `open_project_for_path` resolves symlinks before
        // storing, and on macOS `/tmp` is a link to `/private/tmp`.
        let repo_path = repo
            .path()
            .canonicalize()
            .unwrap()
            .to_string_lossy()
            .to_string();

        let sock = short_sock("open");
        let cancel = CancellationToken::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        start(service.clone(), cancel.clone(), sock.clone(), tx).unwrap();

        let resp = roundtrip(
            &sock,
            &format!(r#"{{"action":"open","path":"{repo_path}","file":"src/main.rs"}}"#),
        )
        .await;
        assert_eq!(resp["ok"], serde_json::Value::Bool(true));
        assert_eq!(resp["data"]["repo_path"].as_str().unwrap(), repo_path);

        let forwarded = rx.recv().await.unwrap();
        assert_eq!(forwarded.file.as_deref(), Some("src/main.rs"));
        assert_eq!(forwarded.project.repo_path, repo_path);

        // A second open of the same folder reuses the row rather than piling
        // up duplicate projects.
        let again = roundtrip(&sock, &format!(r#"{{"action":"open","path":"{repo_path}"}}"#)).await;
        assert_eq!(
            again["data"]["project_id"], resp["data"]["project_id"],
            "same folder must map to the same project"
        );
        let forwarded = rx.recv().await.unwrap();
        assert_eq!(forwarded.file, None);

        cancel.cancel();
    }

    /// Path→project resolution, exercised through the service directly (no
    /// socket needed). The prefix match is the one genuinely subtle piece of
    /// this feature: it has to treat a *nested* path as "already covered" while
    /// keeping a merely *similarly-named* sibling distinct.
    #[tokio::test]
    async fn resolves_paths_to_the_deepest_covering_project() {
        let service = test_service().await;
        let root = tempfile::tempdir_in("/tmp").unwrap();
        let root = root.path().canonicalize().unwrap();

        let repo = root.join("app");
        let nested = repo.join("crates/inner");
        // Sibling whose path shares `app` as a string prefix — the case a
        // naive `starts_with(stored)` would wrongly collapse into `app`.
        let sibling = root.join("app-v2");
        std::fs::create_dir_all(&nested).unwrap();
        std::fs::create_dir_all(&sibling).unwrap();

        let app = service
            .open_project_for_path(repo.to_string_lossy().into())
            .await
            .unwrap();

        // A path *inside* the project reuses it rather than registering a
        // second, overlapping project.
        let from_nested = service
            .open_project_for_path(nested.to_string_lossy().into())
            .await
            .unwrap();
        assert_eq!(from_nested.id, app.id);

        // A sibling sharing the name prefix is its own project.
        let v2 = service
            .open_project_for_path(sibling.to_string_lossy().into())
            .await
            .unwrap();
        assert_ne!(v2.id, app.id);
        assert_eq!(v2.name, "app-v2");

        // With a nested project registered too, the deepest match wins.
        let inner = service
            .open_project_for_path(nested.to_string_lossy().into())
            .await
            .unwrap();
        assert_eq!(inner.id, app.id, "still the only covering project");
        let explicit_inner = service
            .create_project(crate::CreateProjectRequest {
                name: "inner".into(),
                repo_path: nested.to_string_lossy().into(),
            })
            .await
            .unwrap();
        let deepest = service
            .open_project_for_path(nested.join("sub").to_string_lossy().into())
            .await;
        // `nested/sub` doesn't exist on disk — a missing path is rejected
        // outright rather than silently resolving to an ancestor.
        assert!(deepest.is_err());
        std::fs::create_dir_all(nested.join("sub")).unwrap();
        let deepest = service
            .open_project_for_path(nested.join("sub").to_string_lossy().into())
            .await
            .unwrap();
        assert_eq!(deepest.id, explicit_inner.id);

        // Trailing slashes normalise to the same project, not a duplicate.
        let trailing = service
            .open_project_for_path(format!("{}/", repo.to_string_lossy()))
            .await
            .unwrap();
        assert_eq!(trailing.id, app.id);
    }

    #[test]
    fn rebases_files_onto_the_resolved_repo() {
        assert_eq!(
            relative_to_repo("/repo/src/main.rs", "/repo"),
            Some("src/main.rs".into())
        );
        // Already-relative input (an older `ycode` binary still on PATH after
        // an app update) passes through untouched.
        assert_eq!(
            relative_to_repo("src/main.rs", "/repo"),
            Some("src/main.rs".into())
        );
        // Outside the repo: no focused file rather than a wrong one.
        assert_eq!(relative_to_repo("/elsewhere/x.rs", "/repo"), None);
        // A sibling sharing a string prefix is not "inside" the repo.
        assert_eq!(relative_to_repo("/repo-v2/src/x.rs", "/repo"), None);
    }

    /// The bug this re-basing exists for: the CLI stops at the nearest `.git`
    /// (a submodule), while the app resolves to the deepest *registered*
    /// project (the outer repo). A relative path computed against the former
    /// and applied to the latter opens a different file with the same suffix.
    #[tokio::test]
    async fn file_inside_a_submodule_resolves_against_the_registered_project() {
        if !unix_socket_bind_available() {
            eprintln!("skipping: unix socket bind not permitted");
            return;
        }
        let service = test_service().await;
        let tmp = tempfile::tempdir_in("/tmp").unwrap();
        let outer = tmp.path().canonicalize().unwrap().join("outer");
        let sub = outer.join("vendor/lib");
        std::fs::create_dir_all(sub.join("src")).unwrap();
        std::fs::write(sub.join("src/main.rs"), "").unwrap();

        // Only the outer repo is registered.
        let registered = service
            .open_project_for_path(outer.to_string_lossy().into())
            .await
            .unwrap();

        let sock = short_sock("rebase");
        let cancel = CancellationToken::new();
        let (tx, mut rx) = mpsc::unbounded_channel();
        start(service, cancel.clone(), sock.clone(), tx).unwrap();

        let file = sub.join("src/main.rs");
        let resp = roundtrip(
            &sock,
            &format!(
                r#"{{"action":"open","path":"{}","file":"{}"}}"#,
                sub.to_string_lossy(),
                file.to_string_lossy()
            ),
        )
        .await;
        assert_eq!(resp["ok"], serde_json::Value::Bool(true));

        let forwarded = rx.recv().await.unwrap();
        assert_eq!(forwarded.project.id, registered.id);
        // Relative to the *outer* repo — not "src/main.rs", which would point
        // at the outer repo's own file.
        assert_eq!(forwarded.file.as_deref(), Some("vendor/lib/src/main.rs"));

        cancel.cancel();
    }

    #[tokio::test]
    async fn bad_requests_are_reported() {
        if !unix_socket_bind_available() {
            eprintln!("skipping: unix socket bind not permitted");
            return;
        }
        let service = test_service().await;
        let sock = short_sock("bad");
        let cancel = CancellationToken::new();
        let (tx, _rx) = mpsc::unbounded_channel();
        start(service, cancel.clone(), sock.clone(), tx).unwrap();

        let missing_path = roundtrip(&sock, r#"{"action":"open"}"#).await;
        assert_eq!(missing_path["ok"], serde_json::Value::Bool(false));

        let unknown = roundtrip(&sock, r#"{"action":"teleport","path":"/tmp"}"#).await;
        assert!(unknown["error"].as_str().unwrap().contains("unknown action"));

        let not_a_dir = roundtrip(
            &sock,
            r#"{"action":"open","path":"/definitely/not/a/real/dir"}"#,
        )
        .await;
        assert_eq!(not_a_dir["ok"], serde_json::Value::Bool(false));

        cancel.cancel();
    }
}
