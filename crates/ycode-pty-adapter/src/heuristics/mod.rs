//! Heuristic profiles for non-ACP CLI agents.
//!
//! Each profile is a small piece of pattern logic that turns cleaned terminal
//! lines into structured events: cleaner-text echoes, state labels,
//! permission-prompt detections. Profiles are intentionally small and
//! disposable — when an upstream agent gains ACP support, its profile should
//! shrink to nothing rather than grow.
//!
//! See `codex.rs` for the load-bearing example. Every profile module has a
//! soft 200-LoC budget; exceeding it is a signal we're chasing strings
//! instead of waiting for upstream to standardize.

pub mod codex;

use crate::events::EmitFn;

/// Stateful pattern detector. Lives on the reader thread; one instance per
/// session. Methods take `&mut self` so the profile can keep small bits of
/// state (e.g. "we're inside a permission prompt now").
pub trait HeuristicProfile: Send + 'static {
    /// Stable identifier used in logs and config (`heuristic_profile` field).
    fn name(&self) -> &'static str;

    /// Called for every cleaned terminal line emitted by the vt100 parser.
    /// The profile uses `emit` to surface structured events.
    fn observe_line(&mut self, line: &str, emit: &mut dyn EmitFn);

    /// Called when the PTY closes / process exits. Last chance to flush any
    /// buffered state.
    fn on_eof(&mut self, _emit: &mut dyn EmitFn) {}
}

/// Look up a profile by id. Add new profiles here.
pub fn make(name: &str) -> Option<Box<dyn HeuristicProfile>> {
    match name {
        "codex" => Some(Box::new(codex::CodexProfile::new())),
        _ => None,
    }
}
