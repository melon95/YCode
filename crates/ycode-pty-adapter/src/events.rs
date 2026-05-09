//! Event emission abstraction for the heuristic layer.
//!
//! Heuristic profiles run on the reader *thread* (portable-pty is blocking),
//! so they can't `await` directly on a tokio sender. Instead they call this
//! trait, which the reader thread implements over a `blocking_send` to a
//! tokio channel.

use ycode_adapter::AgentEvent;

pub trait EmitFn: Send {
    fn emit(&mut self, event: AgentEvent);
}
