//! Session orchestrator, state machine, and permission broker — the
//! load-bearing logic of ycode.
//!
//! ## Layout
//!
//! - [`session`] — the validated state machine. Adapters announce transitions
//!   by emitting `AgentEvent::StateChanged`; this module rejects illegal ones.
//! - [`permission`] — bookkeeping for outstanding permission requests.
//! - [`orchestrator`] — per-session runner: drives the adapter event loop,
//!   persists, fans out to UI subscribers.
//!
//! Higher-level multi-session management (registry of `SessionRunner`s) lives
//! in the Tauri layer for now; ycode-cli composes a single runner directly.

pub mod manager;
pub mod orchestrator;
pub mod permission;
pub mod session;

pub use manager::{AdapterFactoryFn, ManagerError, SessionManager, SessionRecord};
pub use orchestrator::{
    ended_cleanly, is_terminal, OrchestratorError, SessionRunner, SessionStart,
};
pub use permission::{BrokerError, OutstandingPermission, PermissionBroker};
pub use session::{is_allowed, state_label, Session, TransitionError};
