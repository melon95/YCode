//! Universal PTY terminal proxy.
//!
//! Spawns a child process under a PTY and forwards bytes between the child
//! and consumers byte-for-byte. No protocol parsing, no vt100 stripping —
//! consumers (typically xterm.js in the webview) handle terminal emulation.
//!
//! ## Design
//!
//! - [`TerminalSession`] owns one PTY pair + the child process. A blocking
//!   reader thread pulls bytes off the master and fans them out on a
//!   `broadcast` channel. A waiter thread detects child exit and emits a
//!   final `Exited` event before closing the channel.
//! - [`TerminalManager`] is a registry: id → `Arc<TerminalSession>`. The
//!   IPC layer owns one of these.
//! - Output is broadcast as raw `Vec<u8>`. Lagged subscribers will see
//!   `RecvError::Lagged` and should reconnect.
//!
//! ## Threading
//!
//! `portable-pty`'s `read` and `wait` are blocking, so each lives on its own
//! `tokio::task::spawn_blocking` thread. Async writes/resizes from the
//! foreground use the master handle through a mutex.

use std::io::{Read, Write};
use std::sync::Arc;

use camino::Utf8PathBuf;
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::{broadcast, Mutex, RwLock};
use tracing::{debug, info, warn};

/// Capacity of the per-session output broadcast channel. One slot is one
/// `read()` chunk (up to `READ_BUF_SIZE` bytes). Slow subscribers will lag
/// after ~OUTPUT_BUFFER_SLOTS * READ_BUF_SIZE bytes of un-drained output.
const OUTPUT_BUFFER_SLOTS: usize = 1024;
const READ_BUF_SIZE: usize = 8192;

/// Default PTY geometry. The frontend should `resize` immediately after
/// connecting to match xterm.js dimensions.
const DEFAULT_ROWS: u16 = 40;
const DEFAULT_COLS: u16 = 120;

/// Inputs needed to spawn a child under a PTY.
#[derive(Clone, Debug)]
pub struct SpawnSpec {
    pub command: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: Utf8PathBuf,
    pub rows: u16,
    pub cols: u16,
}

impl SpawnSpec {
    /// Build a spec with default geometry. The frontend can resize after
    /// attaching to match the actual xterm.js viewport.
    pub fn new(command: impl Into<String>, cwd: Utf8PathBuf) -> Self {
        Self {
            command: command.into(),
            args: vec![],
            env: vec![],
            cwd,
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
        }
    }
}

/// Process lifecycle, deliberately coarse — see PRD `SessionStatus`.
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(tag = "type")]
pub enum TerminalStatus {
    /// PTY is open, child is running (or in the brief startup window — we
    /// don't distinguish since there's no protocol handshake).
    Running,
    /// Child exited. `code` is `None` when the process was killed by a
    /// signal rather than calling `exit()`.
    Exited { code: Option<i32> },
    /// Spawn failed or the reader/waiter died unexpectedly. Treat as
    /// terminal.
    Error { message: String },
}

/// Events fanned out to subscribers. Output and exit ride the same channel
/// so consumers don't need to multiplex.
#[derive(Clone, Debug)]
pub enum TerminalEvent {
    /// Bytes read from the PTY master. Pass through to xterm.js unmodified.
    Output(Vec<u8>),
    /// Child exited. Always followed by the channel closing. `code` is None
    /// for signal-terminated processes.
    Exited { code: Option<i32> },
    /// Fatal error from the reader or waiter. Followed by channel close.
    Error(String),
}

#[derive(Error, Debug)]
pub enum TerminalError {
    #[error("spawn failed: {0}")]
    Spawn(String),

    #[error("io: {0}")]
    Io(String),

    #[error("session `{0}` not found")]
    NotFound(String),

    #[error("session `{0}` already exists")]
    AlreadyExists(String),
}

/// One PTY-backed child process plus its event fan-out.
///
/// Held behind an `Arc` — subscribers can clone freely. Dropping the session
/// closes the master PTY which signals EOF to the slave; most CLIs treat
/// that as a clean shutdown.
pub struct TerminalSession {
    id: String,
    /// Writer half of the master. Held behind a mutex so `write()` calls
    /// from concurrent IPC handlers serialize.
    writer: Mutex<Box<dyn Write + Send>>,
    /// Master held only for `resize` (and to release on drop). The reader
    /// has its own cloned reader handle; the writer is `take`n above.
    master: Mutex<Option<Box<dyn MasterPty + Send>>>,
    /// Lets `kill()` send a signal without waiting on the child.
    killer: Mutex<Box<dyn ChildKiller + Send + Sync>>,
    /// Current status. Written by the waiter thread on exit; read by IPC.
    status: Arc<RwLock<TerminalStatus>>,
    events_tx: broadcast::Sender<TerminalEvent>,
}

impl TerminalSession {
    /// Open a PTY, spawn the command, start the reader and waiter tasks.
    /// Returns once the child has been launched — output starts flowing
    /// through the broadcast channel as soon as subscribers attach.
    pub fn spawn(id: impl Into<String>, spec: SpawnSpec) -> Result<Arc<Self>, TerminalError> {
        let id = id.into();
        info!(session_id = %id, command = %spec.command, cwd = %spec.cwd, "spawning terminal");

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: spec.rows,
                cols: spec.cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| TerminalError::Spawn(format!("openpty: {e}")))?;

        let mut cmd = CommandBuilder::new(&spec.command);
        for arg in &spec.args {
            cmd.arg(arg);
        }
        cmd.cwd(spec.cwd.as_str());
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }

        let child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| TerminalError::Spawn(format!("spawn: {e}")))?;
        // Drop the slave handle: we only need the master to read/write/resize.
        drop(pair.slave);

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| TerminalError::Spawn(format!("take_writer: {e}")))?;
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| TerminalError::Spawn(format!("try_clone_reader: {e}")))?;
        let killer = child.clone_killer();

        let (events_tx, _) = broadcast::channel::<TerminalEvent>(OUTPUT_BUFFER_SLOTS);
        let status = Arc::new(RwLock::new(TerminalStatus::Running));

        let session = Arc::new(Self {
            id: id.clone(),
            writer: Mutex::new(writer),
            master: Mutex::new(Some(pair.master)),
            killer: Mutex::new(killer),
            status: status.clone(),
            events_tx: events_tx.clone(),
        });

        // Reader: pulls bytes off the master into the broadcast channel.
        // Exits on EOF (set when the child exits and the kernel closes the
        // slave end) or on read error.
        let reader_id = id.clone();
        let reader_tx = events_tx.clone();
        tokio::task::spawn_blocking(move || {
            reader_loop(reader_id, reader, reader_tx);
        });

        // Waiter: blocks on child.wait() and emits the final Exited event
        // when the process terminates. Also updates `status`.
        let waiter_id = id.clone();
        let waiter_tx = events_tx;
        let waiter_status = status;
        tokio::task::spawn_blocking(move || {
            waiter_loop(waiter_id, child, waiter_status, waiter_tx);
        });

        Ok(session)
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    /// Subscribe to the event stream. Late subscribers miss earlier output —
    /// the consumer is responsible for its own scrollback (typically the
    /// xterm.js buffer on the webview side).
    pub fn subscribe(&self) -> broadcast::Receiver<TerminalEvent> {
        self.events_tx.subscribe()
    }

    pub async fn status(&self) -> TerminalStatus {
        self.status.read().await.clone()
    }

    /// Forward bytes to the PTY master (== child stdin).
    pub async fn write(&self, bytes: &[u8]) -> Result<(), TerminalError> {
        let mut w = self.writer.lock().await;
        w.write_all(bytes).map_err(|e| TerminalError::Io(format!("write: {e}")))?;
        w.flush().map_err(|e| TerminalError::Io(format!("flush: {e}")))?;
        Ok(())
    }

    /// Update the PTY's reported geometry. Call on every xterm.js resize so
    /// `$LINES`/`$COLUMNS` and SIGWINCH propagate correctly.
    pub async fn resize(&self, cols: u16, rows: u16) -> Result<(), TerminalError> {
        let master = self.master.lock().await;
        if let Some(m) = master.as_ref() {
            m.resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| TerminalError::Io(format!("resize: {e}")))?;
        }
        Ok(())
    }

    /// Send SIGKILL (or platform equivalent) to the child. The waiter task
    /// will observe the exit and emit `Exited { code: None }`.
    pub async fn kill(&self) -> Result<(), TerminalError> {
        self.killer
            .lock()
            .await
            .kill()
            .map_err(|e| TerminalError::Io(format!("kill: {e}")))?;
        Ok(())
    }
}

impl Drop for TerminalSession {
    fn drop(&mut self) {
        // Closing the master sends EOF to the slave; most CLIs exit cleanly
        // on that. We don't need to abort the blocking tasks — the reader
        // sees EOF and returns; the waiter unblocks when wait() resolves.
        if let Ok(mut master) = self.master.try_lock() {
            let _ = master.take();
        }
    }
}

/// Multi-session registry. Owned by the IPC layer.
pub struct TerminalManager {
    sessions: RwLock<std::collections::HashMap<String, Arc<TerminalSession>>>,
}

impl Default for TerminalManager {
    fn default() -> Self {
        Self::new()
    }
}

impl TerminalManager {
    pub fn new() -> Self {
        Self {
            sessions: RwLock::new(std::collections::HashMap::new()),
        }
    }

    /// Spawn a session and register it under `id`. Fails if `id` already
    /// has a live session — callers should `remove` first if they want to
    /// replace.
    pub async fn spawn(
        &self,
        id: impl Into<String>,
        spec: SpawnSpec,
    ) -> Result<Arc<TerminalSession>, TerminalError> {
        let id = id.into();
        {
            let map = self.sessions.read().await;
            if map.contains_key(&id) {
                return Err(TerminalError::AlreadyExists(id));
            }
        }
        let session = TerminalSession::spawn(id.clone(), spec)?;
        self.sessions.write().await.insert(id, session.clone());
        Ok(session)
    }

    pub async fn get(&self, id: &str) -> Option<Arc<TerminalSession>> {
        self.sessions.read().await.get(id).cloned()
    }

    /// Remove from the registry. The returned `Arc` is the last strong ref
    /// the manager held; if other clones exist, the session stays alive
    /// until they drop.
    pub async fn remove(&self, id: &str) -> Option<Arc<TerminalSession>> {
        self.sessions.write().await.remove(id)
    }

    pub async fn list(&self) -> Vec<Arc<TerminalSession>> {
        self.sessions.read().await.values().cloned().collect()
    }
}

fn reader_loop(
    session_id: String,
    mut reader: Box<dyn Read + Send>,
    tx: broadcast::Sender<TerminalEvent>,
) {
    let mut buf = [0u8; READ_BUF_SIZE];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => {
                debug!(session_id = %session_id, "PTY reader hit EOF");
                break;
            }
            Ok(n) => {
                // `send` errors only if there are zero subscribers — that's
                // fine, the bytes are dropped and the reader keeps draining
                // so the child doesn't backpressure on a full PTY buffer.
                let _ = tx.send(TerminalEvent::Output(buf[..n].to_vec()));
            }
            Err(e) => {
                warn!(session_id = %session_id, error = %e, "PTY read error");
                let _ = tx.send(TerminalEvent::Error(format!("pty read: {e}")));
                break;
            }
        }
    }
}

fn waiter_loop(
    session_id: String,
    mut child: Box<dyn portable_pty::Child + Send + Sync>,
    status: Arc<RwLock<TerminalStatus>>,
    tx: broadcast::Sender<TerminalEvent>,
) {
    let new_status = match child.wait() {
        Ok(status_code) => {
            let code = if status_code.success() {
                Some(0_i32)
            } else {
                Some(status_code.exit_code() as i32)
            };
            info!(session_id = %session_id, code = ?code, "child exited");
            TerminalStatus::Exited { code }
        }
        Err(e) => {
            warn!(session_id = %session_id, error = %e, "child.wait failed");
            TerminalStatus::Error {
                message: format!("wait: {e}"),
            }
        }
    };

    // We're on a blocking thread; reach back into the tokio runtime to
    // grab the RwLock. `try_current` works because Tauri / tests run
    // inside a multi-threaded tokio runtime.
    if let Ok(handle) = tokio::runtime::Handle::try_current() {
        handle.block_on(async {
            *status.write().await = new_status.clone();
        });
    }

    let event = match new_status {
        TerminalStatus::Exited { code } => TerminalEvent::Exited { code },
        TerminalStatus::Error { message } => TerminalEvent::Error(message),
        TerminalStatus::Running => unreachable!("waiter only sets terminal statuses"),
    };
    let _ = tx.send(event);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use tokio::time::timeout;

    fn tmpdir() -> Utf8PathBuf {
        let d = tempfile::tempdir().unwrap();
        let p = Utf8PathBuf::from_path_buf(d.path().to_path_buf()).unwrap();
        // Leak the handle so the dir survives the test.
        std::mem::forget(d);
        p
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn spawn_echo_emits_output_and_exit() {
        let session = TerminalSession::spawn(
            "t-echo",
            SpawnSpec {
                command: "/bin/sh".into(),
                args: vec!["-c".into(), "printf 'hello\\n'".into()],
                env: vec![],
                cwd: tmpdir(),
                rows: 24,
                cols: 80,
            },
        )
        .unwrap();

        let mut rx = session.subscribe();
        let mut saw_output = false;
        let mut saw_exit = false;
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);

        while tokio::time::Instant::now() < deadline && !saw_exit {
            match timeout(Duration::from_millis(500), rx.recv()).await {
                Ok(Ok(TerminalEvent::Output(bytes))) => {
                    if String::from_utf8_lossy(&bytes).contains("hello") {
                        saw_output = true;
                    }
                }
                Ok(Ok(TerminalEvent::Exited { code })) => {
                    assert_eq!(code, Some(0));
                    saw_exit = true;
                }
                Ok(Ok(TerminalEvent::Error(msg))) => panic!("error: {msg}"),
                Ok(Err(_)) => break,
                Err(_) => continue,
            }
        }
        assert!(saw_output, "should have observed `hello` in the output");
        assert!(saw_exit, "should have observed the exit event");
        assert!(matches!(
            session.status().await,
            TerminalStatus::Exited { code: Some(0) }
        ));
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn write_feeds_child_stdin() {
        let session = TerminalSession::spawn(
            "t-cat",
            SpawnSpec {
                command: "/bin/sh".into(),
                // Read one line and echo it back, then exit. `head -n 1` gives
                // a deterministic stop condition.
                args: vec!["-c".into(), "head -n 1".into()],
                env: vec![],
                cwd: tmpdir(),
                rows: 24,
                cols: 80,
            },
        )
        .unwrap();

        // Give the child a moment to be ready to read.
        tokio::time::sleep(Duration::from_millis(100)).await;

        let mut rx = session.subscribe();
        session.write(b"ping\n").await.unwrap();

        let mut seen = String::new();
        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        while tokio::time::Instant::now() < deadline && !seen.contains("ping") {
            match timeout(Duration::from_millis(500), rx.recv()).await {
                Ok(Ok(TerminalEvent::Output(bytes))) => {
                    seen.push_str(&String::from_utf8_lossy(&bytes));
                }
                Ok(Ok(TerminalEvent::Exited { .. })) => break,
                _ => continue,
            }
        }
        assert!(
            seen.contains("ping"),
            "should have seen the echoed input. saw: {seen:?}"
        );
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn kill_terminates_child() {
        let session = TerminalSession::spawn(
            "t-sleep",
            SpawnSpec {
                command: "/bin/sh".into(),
                args: vec!["-c".into(), "sleep 30".into()],
                env: vec![],
                cwd: tmpdir(),
                rows: 24,
                cols: 80,
            },
        )
        .unwrap();

        let mut rx = session.subscribe();
        session.kill().await.unwrap();

        let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
        let mut saw_exit = false;
        while tokio::time::Instant::now() < deadline && !saw_exit {
            match timeout(Duration::from_millis(500), rx.recv()).await {
                Ok(Ok(TerminalEvent::Exited { .. })) => saw_exit = true,
                Ok(Ok(_)) => continue,
                Ok(Err(_)) => break,
                Err(_) => continue,
            }
        }
        assert!(saw_exit, "kill should have produced an Exited event");
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn manager_round_trip() {
        let mgr = TerminalManager::new();
        let s = mgr
            .spawn(
                "s1",
                SpawnSpec {
                    command: "/bin/sh".into(),
                    args: vec!["-c".into(), "sleep 1".into()],
                    env: vec![],
                    cwd: tmpdir(),
                    rows: 24,
                    cols: 80,
                },
            )
            .await
            .unwrap();
        assert!(mgr.get("s1").await.is_some());
        assert_eq!(mgr.list().await.len(), 1);

        // Duplicate spawn fails.
        let dup = mgr
            .spawn(
                "s1",
                SpawnSpec {
                    command: "/bin/true".into(),
                    args: vec![],
                    env: vec![],
                    cwd: tmpdir(),
                    rows: 24,
                    cols: 80,
                },
            )
            .await;
        assert!(matches!(dup, Err(TerminalError::AlreadyExists(_))));

        let removed = mgr.remove("s1").await.unwrap();
        let _ = removed.kill().await;
        drop(s);
        assert!(mgr.get("s1").await.is_none());
    }
}
