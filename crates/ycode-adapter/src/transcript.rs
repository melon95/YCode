//! Canonical transcript model.
//!
//! Adapters and the persist layer both need a way to talk about "the ordered
//! sequence of events that constitute a session's history" without coupling to
//! storage. This module defines that shape; ycode-persist serializes it,
//! ycode-cli renders it as NDJSON.

use crate::events::AgentEvent;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Transcript {
    pub session_id: String,
    pub entries: Vec<TranscriptEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TranscriptEntry {
    /// Monotonic per session, gapless, starts at 0.
    pub seq: u64,
    /// Unix milliseconds.
    pub ts_ms: i64,
    pub event: AgentEvent,
}

impl Transcript {
    pub fn new(session_id: impl Into<String>) -> Self {
        Self {
            session_id: session_id.into(),
            entries: Vec::new(),
        }
    }

    pub fn next_seq(&self) -> u64 {
        self.entries.last().map(|e| e.seq + 1).unwrap_or(0)
    }
}
