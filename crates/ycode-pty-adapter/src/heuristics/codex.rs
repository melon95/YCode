//! Codex CLI heuristic profile — the load-bearing PTY example.
//!
//! Validated against `codex-cli 0.130.0` output (Nov 2025 build). Real
//! codex frames each turn as three header-style markers on their own
//! lines, which is what these regexes anchor on:
//!
//! 1. `^codex$` — the agent's response section is starting. Treated as the
//!    Idle/Done → `Running` transition.
//! 2. `^tokens used$` — coarse end-of-turn signal printed as a footer.
//!    Treated as the `Running` → `Done(EndTurn)` transition.
//! 3. `Approve ... \(y/n\)` — codex's interactive permission prompt
//!    (TUI/non-`exec` mode). Routed through `RequestPermission` so the
//!    orchestrator's broker handles the round-trip uniformly with ACP
//!    agents.
//!
//! ## 200-LoC alarm
//!
//! Per `/Users/melon/.claude/plans/sleepy-roaming-graham.md`, exceeding 200
//! LoC in this file is a signal that we're chasing terminal strings
//! instead of waiting for codex to adopt ACP. Track upstream rather than
//! expand.

use regex::Regex;
use ulid::Ulid;
use ycode_adapter::{
    AgentEvent, PermissionKind, PermissionOption, SessionState, StopReason,
};

use crate::events::EmitFn;
use crate::heuristics::HeuristicProfile;

pub struct CodexProfile {
    re_permission: Regex,
    re_codex_marker: Regex,
    re_tokens_marker: Regex,
    /// Most recent unanswered permission request id, if any. Used so the
    /// adapter can map the user's "y" / "n" answer back to *this* request.
    pub(crate) outstanding_permission: Option<String>,
    /// Whether we've already announced Running for this turn. Resets on
    /// the next Done marker so the next turn can re-emit cleanly.
    pub(crate) running_announced: bool,
}

impl CodexProfile {
    pub fn new() -> Self {
        // Anchors: codex prints these as discrete lines after vt100 strip.
        let re_permission = Regex::new(r"Approve\s+(.+?)\s*\(y/n\)").unwrap();
        let re_codex_marker = Regex::new(r"^codex$").unwrap();
        let re_tokens_marker = Regex::new(r"^tokens used$").unwrap();
        Self {
            re_permission,
            re_codex_marker,
            re_tokens_marker,
            outstanding_permission: None,
            running_announced: false,
        }
    }
}

impl Default for CodexProfile {
    fn default() -> Self {
        Self::new()
    }
}

impl HeuristicProfile for CodexProfile {
    fn name(&self) -> &'static str {
        "codex"
    }

    fn observe_line(&mut self, line: &str, emit: &mut dyn EmitFn) {
        if let Some(m) = self.re_permission.captures(line) {
            let summary = m.get(1).map(|x| x.as_str().trim().to_string()).unwrap_or_default();
            let request_id = Ulid::new().to_string();
            self.outstanding_permission = Some(request_id.clone());
            emit.emit(AgentEvent::RequestPermission {
                request_id: request_id.clone(),
                tool_name: "codex".into(),
                summary: summary.clone(),
                options: vec![
                    PermissionOption {
                        option_id: "allow_once".into(),
                        name: "Yes".into(),
                        kind: PermissionKind::AllowOnce,
                    },
                    PermissionOption {
                        option_id: "reject_once".into(),
                        name: "No".into(),
                        kind: PermissionKind::RejectOnce,
                    },
                ],
            });
            emit.emit(AgentEvent::StateChanged {
                state: SessionState::AwaitingPermission {
                    request_id,
                    tool: "codex".into(),
                    summary,
                },
            });
            return;
        }

        if self.re_codex_marker.is_match(line) {
            // Only emit Running once per turn — the state machine forbids
            // Running → Running, and codex sometimes prints additional
            // `codex` markers within a single response (e.g. continuation
            // sections). Reset on the next tokens-used boundary.
            if !self.running_announced {
                emit.emit(AgentEvent::StateChanged {
                    state: SessionState::Running {
                        turn_id: Ulid::new().to_string(),
                    },
                });
                self.running_announced = true;
            }
            emit.emit(AgentEvent::HeuristicState {
                label: "codex:answering".into(),
            });
            return;
        }

        if self.re_tokens_marker.is_match(line) {
            emit.emit(AgentEvent::StateChanged {
                state: SessionState::Done {
                    stop_reason: StopReason::EndTurn,
                },
            });
            self.running_announced = false;
            return;
        }
    }

    fn on_eof(&mut self, emit: &mut dyn EmitFn) {
        // If the agent process exits while a permission request is still
        // outstanding, the orchestrator would otherwise hang waiting for an
        // answer that will never come. Surface a fatal error.
        if self.outstanding_permission.take().is_some() {
            emit.emit(AgentEvent::Error {
                message: "agent exited with permission still outstanding".into(),
                fatal: true,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Arc, Mutex};

    /// Test-only collector: records every emitted event.
    struct VecEmit(Arc<Mutex<Vec<AgentEvent>>>);
    impl EmitFn for VecEmit {
        fn emit(&mut self, ev: AgentEvent) {
            self.0.lock().unwrap().push(ev);
        }
    }

    fn collect() -> (VecEmit, Arc<Mutex<Vec<AgentEvent>>>) {
        let v = Arc::new(Mutex::new(Vec::new()));
        (VecEmit(v.clone()), v)
    }

    #[test]
    fn permission_prompt_is_detected() {
        let mut p = CodexProfile::new();
        let (mut emit, log) = collect();
        p.observe_line("Approve write file foo.txt (y/n)", &mut emit);
        let log = log.lock().unwrap();
        assert!(matches!(log[0], AgentEvent::RequestPermission { .. }));
        assert!(matches!(
            log[1],
            AgentEvent::StateChanged {
                state: SessionState::AwaitingPermission { .. }
            }
        ));
    }

    #[test]
    fn codex_marker_emits_running_once() {
        let mut p = CodexProfile::new();
        let (mut emit, log) = collect();
        p.observe_line("codex", &mut emit);
        p.observe_line("codex", &mut emit);
        let log = log.lock().unwrap();
        // First marker → StateChanged(Running) + HeuristicState.
        // Second marker → only HeuristicState (running already announced).
        assert!(matches!(
            log[0],
            AgentEvent::StateChanged {
                state: SessionState::Running { .. }
            }
        ));
        assert!(matches!(log[1], AgentEvent::HeuristicState { .. }));
        assert!(matches!(log[2], AgentEvent::HeuristicState { .. }));
        assert_eq!(log.len(), 3);
    }

    #[test]
    fn tokens_marker_transitions_to_done() {
        let mut p = CodexProfile::new();
        let (mut emit, log) = collect();
        p.observe_line("codex", &mut emit);
        p.observe_line("tokens used", &mut emit);
        let log = log.lock().unwrap();
        let last = log.last().unwrap();
        assert!(matches!(
            last,
            AgentEvent::StateChanged {
                state: SessionState::Done { .. }
            }
        ));
    }

    #[test]
    fn running_resets_after_done_so_next_turn_re_emits() {
        let mut p = CodexProfile::new();
        let (mut emit, log) = collect();
        p.observe_line("codex", &mut emit);
        p.observe_line("tokens used", &mut emit);
        p.observe_line("codex", &mut emit);
        let log = log.lock().unwrap();
        let running_count = log
            .iter()
            .filter(|e| {
                matches!(
                    e,
                    AgentEvent::StateChanged {
                        state: SessionState::Running { .. }
                    }
                )
            })
            .count();
        assert_eq!(running_count, 2, "second turn should re-emit Running");
    }
}
