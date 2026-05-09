//! Session state machine.
//!
//! Adapters announce transitions by emitting `AgentEvent::StateChanged`; this
//! module validates each transition before the orchestrator commits it. The
//! contract is asymmetric on purpose: a misbehaving adapter cannot drag a
//! session into an illegal state — the worst it can do is force the session
//! into `Error`, which the orchestrator does explicitly when [`Session::apply`]
//! rejects a transition.
//!
//! Transition graph (per `/Users/melon/.claude/plans/sleepy-roaming-graham.md`):
//!
//! ```text
//! Initializing ──► Idle ──► Running ──► AwaitingPermission ──► Running
//!                    ▲        │  ▲ │           │
//!                    │        │  │ └──► Cancelling ──► Done(Cancelled)
//!                    │        ▼  │
//!                    │      Done(EndTurn|MaxTokens|Refusal|...)
//!                    │        │
//!                    └────────┘   (next prompt; Done also goes straight to Running)
//!
//!  (any) ──► Error  (terminal; recovery requires a fresh adapter)
//! ```

use thiserror::Error;
use ycode_adapter::SessionState;

/// In-memory state for one session. Shared across the orchestrator's tasks
/// behind a `Mutex` (transitions are infrequent — contention is not a concern).
#[derive(Debug)]
pub struct Session {
    id: String,
    state: SessionState,
}

impl Session {
    /// All sessions begin in `Initializing`. The adapter MUST transition to
    /// `Idle` (or `Error`) during `start()`.
    pub fn new(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            state: SessionState::Initializing,
        }
    }

    /// Construct from a state read out of the database (app restart path).
    pub fn restore(id: impl Into<String>, state: SessionState) -> Self {
        Self {
            id: id.into(),
            state,
        }
    }

    pub fn id(&self) -> &str {
        &self.id
    }

    pub fn state(&self) -> &SessionState {
        &self.state
    }

    /// Validate `next` against the current state and commit it. Returns the
    /// prior state so the orchestrator can persist the diff and notify
    /// subscribers. Rejects illegal transitions with a structured error.
    ///
    /// Transitions to `Error` are ALWAYS allowed — adapters use this when they
    /// crash or violate protocol, and the orchestrator uses it to demote a
    /// rejected transition.
    pub fn apply(&mut self, next: SessionState) -> Result<SessionState, TransitionError> {
        if !is_allowed(&self.state, &next) {
            return Err(TransitionError {
                session_id: self.id.clone(),
                from: state_label(&self.state),
                to: state_label(&next),
            });
        }
        let prior = std::mem::replace(&mut self.state, next);
        Ok(prior)
    }

    /// Demote into `Error` regardless of source state. Idempotent.
    pub fn force_error(&mut self, message: String) -> SessionState {
        std::mem::replace(&mut self.state, SessionState::Error { message })
    }
}

/// Pure transition predicate. Exposed for testing.
pub fn is_allowed(from: &SessionState, to: &SessionState) -> bool {
    use SessionState::*;
    // Error is universally accessible — it's the escape hatch.
    if matches!(to, Error { .. }) {
        return true;
    }
    match (from, to) {
        // Startup
        (Initializing, Idle) => true,

        // Idle → next turn
        (Idle, Running { .. }) => true,

        // Mid-turn structured pause
        (Running { .. }, AwaitingPermission { .. }) => true,
        (AwaitingPermission { .. }, Running { .. }) => true,

        // Cancellation
        (Running { .. }, Cancelling) => true,
        (AwaitingPermission { .. }, Cancelling) => true,
        (Cancelling, Done { .. }) => true,

        // Turn completion
        (Running { .. }, Done { .. }) => true,

        // Post-turn: prompt again, or relax to Idle.
        (Done { .. }, Running { .. }) => true,
        (Done { .. }, Idle) => true,

        // Everything else is illegal.
        _ => false,
    }
}

#[derive(Error, Debug, Clone)]
#[error("illegal state transition for session {session_id}: {from} → {to}")]
pub struct TransitionError {
    pub session_id: String,
    pub from: &'static str,
    pub to: &'static str,
}

/// Stable, low-cardinality label used in errors and metrics. Keep in sync with
/// `SessionState` variants.
pub fn state_label(s: &SessionState) -> &'static str {
    use SessionState::*;
    match s {
        Initializing => "Initializing",
        Idle => "Idle",
        Running { .. } => "Running",
        AwaitingPermission { .. } => "AwaitingPermission",
        Cancelling => "Cancelling",
        Done { .. } => "Done",
        Error { .. } => "Error",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ycode_adapter::StopReason;

    fn running() -> SessionState {
        SessionState::Running {
            turn_id: "t1".into(),
        }
    }

    fn await_perm() -> SessionState {
        SessionState::AwaitingPermission {
            request_id: "r1".into(),
            tool: "write_file".into(),
            summary: "write hello.txt".into(),
        }
    }

    fn done() -> SessionState {
        SessionState::Done {
            stop_reason: StopReason::EndTurn,
        }
    }

    #[test]
    fn happy_path_transitions_succeed() {
        let mut s = Session::new("s1");
        assert!(s.apply(SessionState::Idle).is_ok());
        assert!(s.apply(running()).is_ok());
        assert!(s.apply(await_perm()).is_ok());
        assert!(s
            .apply(SessionState::Running {
                turn_id: "t1".into()
            })
            .is_ok());
        assert!(s.apply(done()).is_ok());
        assert!(s.apply(SessionState::Idle).is_ok());
    }

    #[test]
    fn idle_to_idle_is_rejected() {
        let mut s = Session::new("s1");
        s.apply(SessionState::Idle).unwrap();
        let err = s.apply(SessionState::Idle).unwrap_err();
        assert_eq!(err.from, "Idle");
        assert_eq!(err.to, "Idle");
    }

    #[test]
    fn cannot_skip_running_to_awaiting_permission() {
        let mut s = Session::new("s1");
        s.apply(SessionState::Idle).unwrap();
        assert!(s.apply(await_perm()).is_err());
    }

    #[test]
    fn cancel_path() {
        let mut s = Session::new("s1");
        s.apply(SessionState::Idle).unwrap();
        s.apply(running()).unwrap();
        s.apply(SessionState::Cancelling).unwrap();
        s.apply(SessionState::Done {
            stop_reason: StopReason::Cancelled,
        })
        .unwrap();
    }

    #[test]
    fn error_is_always_reachable() {
        for from in [
            SessionState::Initializing,
            SessionState::Idle,
            running(),
            await_perm(),
            SessionState::Cancelling,
            done(),
        ] {
            let mut s = Session::restore("s1", from.clone());
            assert!(s
                .apply(SessionState::Error {
                    message: "x".into()
                })
                .is_ok());
        }
    }

    #[test]
    fn force_error_overrides_any_state() {
        let mut s = Session::new("s1");
        s.apply(SessionState::Idle).unwrap();
        s.apply(running()).unwrap();
        let prior = s.force_error("crashed".into());
        assert_eq!(state_label(&prior), "Running");
        assert!(matches!(s.state(), SessionState::Error { .. }));
    }

    #[test]
    fn done_back_to_running_for_next_prompt() {
        let mut s = Session::new("s1");
        s.apply(SessionState::Idle).unwrap();
        s.apply(running()).unwrap();
        s.apply(done()).unwrap();
        s.apply(SessionState::Running {
            turn_id: "t2".into(),
        })
        .unwrap();
    }

    #[test]
    fn error_is_terminal() {
        let mut s = Session::restore(
            "s1",
            SessionState::Error {
                message: "x".into(),
            },
        );
        // Error → anything-but-Error is rejected.
        assert!(s.apply(SessionState::Idle).is_err());
        assert!(s.apply(running()).is_err());
        // Error → Error is allowed (idempotent re-error during shutdown).
        assert!(s
            .apply(SessionState::Error {
                message: "y".into()
            })
            .is_ok());
    }
}
