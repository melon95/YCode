//! PTY/screen-scraping adapter for CLI agents without ACP support (e.g. Codex).
//!
//! ## Honest scope
//!
//! - Cleaned-text streaming (vt100-stripped).
//! - Coarse heuristic state labels (`running`, `done`).
//! - y/n permission interception via `heuristics::codex::CodexProfile`.
//!
//! ## Things this adapter cannot do (capabilities are explicit about it)
//!
//! - Structured tool call introspection.
//! - `Plan` updates.
//! - `fs/*` proxying (no protocol surface to intercept on).
//! - `ModeChanged`.
//!
//! ## Threading
//!
//! `portable-pty` is blocking; the reader runs on a dedicated `std::thread`
//! and bridges into tokio via [`tokio::sync::mpsc::Sender::blocking_send`].
//! The vt100 parser lives on that thread; only cleaned strings cross the
//! thread boundary.

mod events;
mod heuristics;

use std::io::Read;
use std::sync::Arc;
use std::time::Duration;

use async_trait::async_trait;
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use tokio::sync::Mutex;
use tokio::task::JoinHandle;
use tracing::{debug, info, warn};
use ycode_adapter::{
    AdapterError, AgentAdapter, AgentEvent, Capabilities, EventSender, SessionState, SpawnSpec,
    StopReason,
};

use crate::events::EmitFn;
use crate::heuristics::HeuristicProfile;

const PTY_CAPS: Capabilities = Capabilities {
    streaming_text: true,
    structured_tool_calls: false,
    structured_permissions: false,
    plans: false,
    cancel: true,
    modes: false,
};

/// Builder hook: which heuristic profile to use for parsing this CLI's output.
/// Configured via `AgentLaunchProfile::heuristic_profile` in `ycode-config`.
pub struct PtyAdapterConfig {
    pub heuristic_profile: String,
}

pub struct PtyAdapter {
    config: PtyAdapterConfig,
    /// Writer half of the PTY master, owned for prompt/cancel/answer keystrokes.
    writer: Arc<Mutex<Option<Box<dyn std::io::Write + Send>>>>,
    /// Master PTY kept alive for the duration of the session. Dropping it
    /// closes the slave; we hold it until shutdown.
    master: Arc<Mutex<Option<Box<dyn MasterPty + Send>>>>,
    /// Outstanding permission request — answer_permission writes a keystroke
    /// only if a request is currently expected.
    outstanding_permission: Arc<Mutex<Option<String>>>,
    reader_task: Mutex<Option<JoinHandle<()>>>,
}

impl PtyAdapter {
    pub fn new(config: PtyAdapterConfig) -> Self {
        Self {
            config,
            writer: Arc::new(Mutex::new(None)),
            master: Arc::new(Mutex::new(None)),
            outstanding_permission: Arc::new(Mutex::new(None)),
            reader_task: Mutex::new(None),
        }
    }
}

#[async_trait]
impl AgentAdapter for PtyAdapter {
    fn name(&self) -> &'static str {
        "pty"
    }

    fn capabilities(&self) -> Capabilities {
        PTY_CAPS
    }

    async fn start(
        &mut self,
        spec: SpawnSpec,
        events_tx: EventSender,
    ) -> Result<(), AdapterError> {
        let profile = heuristics::make(&self.config.heuristic_profile).ok_or_else(|| {
            AdapterError::Spawn(format!(
                "unknown heuristic profile `{}`",
                self.config.heuristic_profile
            ))
        })?;

        info!(command = %spec.command, profile = %self.config.heuristic_profile, "spawning PTY agent");
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: 40,
                cols: 120,
                pixel_width: 0,
                pixel_height: 0,
            })
            .map_err(|e| AdapterError::Spawn(format!("openpty: {e}")))?;

        let mut cmd = CommandBuilder::new(&spec.command);
        for arg in &spec.args {
            cmd.arg(arg);
        }
        cmd.cwd(spec.cwd.as_str());
        for (k, v) in &spec.env {
            cmd.env(k, v);
        }

        // The child handle lives for the duration of the session. Drop on
        // shutdown via the master's drop.
        let _child = pair
            .slave
            .spawn_command(cmd)
            .map_err(|e| AdapterError::Spawn(format!("spawn: {e}")))?;
        // Slave drop here is deliberate — we only need the master.
        drop(pair.slave);

        let writer = pair
            .master
            .take_writer()
            .map_err(|e| AdapterError::Spawn(format!("take_writer: {e}")))?;
        let reader = pair
            .master
            .try_clone_reader()
            .map_err(|e| AdapterError::Spawn(format!("try_clone_reader: {e}")))?;

        let outstanding = self.outstanding_permission.clone();
        let events_tx_for_reader = events_tx.clone();
        let reader_handle = tokio::task::spawn_blocking(move || {
            reader_thread(reader, profile, events_tx_for_reader, outstanding);
        });

        *self.writer.lock().await = Some(writer);
        *self.master.lock().await = Some(pair.master);
        *self.reader_task.lock().await = Some(reader_handle);

        // PTY adapter has no protocol handshake; we declare ready immediately.
        let _ = events_tx
            .send(AgentEvent::StateChanged { state: SessionState::Idle })
            .await;
        Ok(())
    }

    async fn prompt(&mut self, text: String) -> Result<(), AdapterError> {
        let mut writer_slot = self.writer.lock().await;
        let writer = writer_slot
            .as_mut()
            .ok_or(AdapterError::InvalidState("not started"))?;
        write_blocking(writer, format!("{text}\n").as_bytes())?;
        Ok(())
    }

    async fn answer_permission(
        &mut self,
        request_id: String,
        option_id: String,
    ) -> Result<(), AdapterError> {
        let mut outstanding = self.outstanding_permission.lock().await;
        match outstanding.as_deref() {
            Some(rid) if rid == request_id => {}
            _ => {
                return Err(AdapterError::UnknownPermission { request_id });
            }
        }
        *outstanding = None;
        let key = match option_id.as_str() {
            "allow_once" | "allow_always" => "y\n",
            "reject_once" | "reject_always" => "n\n",
            _ => "n\n",
        };
        let mut writer_slot = self.writer.lock().await;
        let writer = writer_slot
            .as_mut()
            .ok_or(AdapterError::InvalidState("not started"))?;
        write_blocking(writer, key.as_bytes())?;
        Ok(())
    }

    async fn cancel(&mut self) -> Result<(), AdapterError> {
        let mut writer_slot = self.writer.lock().await;
        let writer = writer_slot
            .as_mut()
            .ok_or(AdapterError::InvalidState("not started"))?;
        // Ctrl-C. Some agents catch it and exit cleanly; if not, shutdown
        // will harder-kill via dropping the master.
        write_blocking(writer, b"\x03")?;
        Ok(())
    }

    async fn shutdown(&mut self) -> Result<(), AdapterError> {
        // Drop the writer first so the child's stdin closes.
        let _ = self.writer.lock().await.take();
        // Drop the master to send EOF to the slave; with most CLIs that
        // triggers a clean exit. Hard kill happens via the OS when slave
        // closes and the child can't write.
        let _ = self.master.lock().await.take();
        if let Some(h) = self.reader_task.lock().await.take() {
            // Give the reader a moment to drain residual output.
            let _ = tokio::time::timeout(Duration::from_millis(250), h).await;
        }
        Ok(())
    }
}

fn write_blocking(
    writer: &mut Box<dyn std::io::Write + Send>,
    bytes: &[u8],
) -> Result<(), AdapterError> {
    use std::io::Write;
    writer
        .write_all(bytes)
        .map_err(|e| AdapterError::Transport(format!("pty write: {e}")))?;
    writer
        .flush()
        .map_err(|e| AdapterError::Transport(format!("pty flush: {e}")))?;
    Ok(())
}

fn reader_thread(
    mut reader: Box<dyn Read + Send>,
    mut profile: Box<dyn HeuristicProfile>,
    events_tx: EventSender,
    outstanding: Arc<Mutex<Option<String>>>,
) {
    let mut parser = vt100::Parser::new(40, 120, 0);
    let mut last_screen = String::new();
    let mut buf = [0u8; 4096];

    let mut emit = ChannelEmit {
        tx: events_tx.clone(),
        outstanding: outstanding.clone(),
        observed_running: false,
        observed_terminal: false,
    };

    loop {
        let n = match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) => {
                warn!(error = %e, "PTY read error");
                break;
            }
        };
        // Keep raw bytes available for diagnostic transcripts.
        emit.emit(AgentEvent::RawOutput {
            bytes: buf[..n].to_vec(),
        });

        parser.process(&buf[..n]);

        // Diff against last snapshot to find newly-finalised lines. Keep this
        // dumb: just take full screen contents and emit any line that wasn't
        // present before.
        let screen = parser.screen().contents();
        let new_text = if screen.starts_with(&last_screen) {
            screen[last_screen.len()..].to_string()
        } else {
            screen.clone()
        };
        last_screen = screen;

        for line in new_text.lines() {
            let line = line.trim_end();
            if line.is_empty() {
                continue;
            }
            profile.observe_line(line, &mut emit);
        }
    }

    profile.on_eof(&mut emit);
    debug!("PTY reader thread exiting");

    // Synthesize a terminal event so the orchestrator doesn't hang. Pick
    // Done vs Error based on whether the heuristic ever announced a turn
    // had begun: emitting Done from Idle is rejected by the state machine
    // (`Idle → Done` is illegal), and that rejection cascades into a fatal
    // demotion that masks the real signal — the agent died without ever
    // engaging with our prompt.
    if emit.observed_terminal {
        // Heuristic already emitted Done/Error/Cancelling → nothing to do.
    } else if emit.observed_running {
        let _ = events_tx.blocking_send(AgentEvent::StateChanged {
            state: SessionState::Done {
                stop_reason: StopReason::Other {
                    detail: "pty_eof".into(),
                },
            },
        });
    } else {
        let _ = events_tx.blocking_send(AgentEvent::Error {
            message: "PTY agent exited before producing a turn".into(),
            fatal: true,
        });
    }
}

/// Bridges heuristic-profile emits into the tokio events channel and keeps
/// the adapter's `outstanding_permission` mirror in sync. Also tracks
/// whether the session has reached Running and whether the heuristic has
/// already emitted its own terminal state — the EOF synthesizer reads these
/// flags to pick a legal final transition.
///
/// Synchronization via `try_lock` because the adapter side rarely contends
/// with us — the heuristic thread races nothing.
struct ChannelEmit {
    tx: EventSender,
    outstanding: Arc<Mutex<Option<String>>>,
    observed_running: bool,
    observed_terminal: bool,
}

impl EmitFn for ChannelEmit {
    fn emit(&mut self, event: AgentEvent) {
        // Update outstanding_permission mirror so the adapter's
        // answer_permission can validate request_ids without reaching into
        // the heuristic profile's private state.
        match &event {
            AgentEvent::RequestPermission { request_id, .. } => {
                if let Ok(mut g) = self.outstanding.try_lock() {
                    *g = Some(request_id.clone());
                }
            }
            AgentEvent::StateChanged {
                state: SessionState::Running { .. },
            } => {
                self.observed_running = true;
                if let Ok(mut g) = self.outstanding.try_lock() {
                    *g = None;
                }
            }
            AgentEvent::StateChanged {
                state: SessionState::Done { .. } | SessionState::Error { .. },
            } => {
                self.observed_terminal = true;
                if let Ok(mut g) = self.outstanding.try_lock() {
                    *g = None;
                }
            }
            AgentEvent::Error { fatal: true, .. } => {
                self.observed_terminal = true;
            }
            _ => {}
        }
        if let Err(e) = self.tx.blocking_send(event) {
            warn!(error = %e, "PTY event channel closed");
        }
    }
}
