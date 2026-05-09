//! Permission broker — bookkeeping for outstanding `RequestPermission` events.
//!
//! Living inside the orchestrator's per-session task. Two responsibilities:
//!
//! 1. Validate that `answer_permission(request_id, _)` from the UI references
//!    an actual outstanding request, so a stale UI click can't poke the adapter
//!    with a fabricated id.
//! 2. Snapshot the request metadata (tool name, summary, options) so we can
//!    persist on receive and resolve on answer without a round-trip back to
//!    the adapter.
//!
//! The broker DOES NOT route the answer to the adapter — the orchestrator
//! does that by calling `AgentAdapter::answer_permission` directly. Each
//! adapter then routes the answer internally; for ACP that means waking a
//! `oneshot` the JSON-RPC handler is awaiting on (see plan day-3 risk note:
//! the handler must not block the reader task).

use std::collections::HashMap;
use thiserror::Error;
use ycode_adapter::PermissionOption;

#[derive(Debug, Default)]
pub struct PermissionBroker {
    outstanding: HashMap<String, OutstandingPermission>,
}

#[derive(Clone, Debug)]
pub struct OutstandingPermission {
    pub request_id: String,
    pub tool_name: String,
    pub summary: String,
    pub options: Vec<PermissionOption>,
}

impl PermissionBroker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record an incoming request. Returns an error if a duplicate
    /// `request_id` is already outstanding — that should never happen and
    /// indicates an adapter bug.
    pub fn register(&mut self, perm: OutstandingPermission) -> Result<(), BrokerError> {
        if self.outstanding.contains_key(&perm.request_id) {
            return Err(BrokerError::Duplicate(perm.request_id));
        }
        self.outstanding.insert(perm.request_id.clone(), perm);
        Ok(())
    }

    /// Look up and remove a request. Returns `Unknown` if the id was never
    /// registered or was already answered.
    pub fn take(&mut self, request_id: &str) -> Result<OutstandingPermission, BrokerError> {
        self.outstanding
            .remove(request_id)
            .ok_or_else(|| BrokerError::Unknown(request_id.to_string()))
    }

    pub fn contains(&self, request_id: &str) -> bool {
        self.outstanding.contains_key(request_id)
    }

    /// Snapshot — used on shutdown to surface what's stranded.
    pub fn outstanding(&self) -> impl Iterator<Item = &OutstandingPermission> {
        self.outstanding.values()
    }

    pub fn len(&self) -> usize {
        self.outstanding.len()
    }

    pub fn is_empty(&self) -> bool {
        self.outstanding.is_empty()
    }
}

#[derive(Error, Debug, Clone)]
pub enum BrokerError {
    #[error("permission request `{0}` not found or already answered")]
    Unknown(String),
    #[error("duplicate permission request `{0}` — adapter bug")]
    Duplicate(String),
}

#[cfg(test)]
mod tests {
    use super::*;
    use ycode_adapter::PermissionKind;

    fn fixture(id: &str) -> OutstandingPermission {
        OutstandingPermission {
            request_id: id.into(),
            tool_name: "write_file".into(),
            summary: "write hello".into(),
            options: vec![PermissionOption {
                option_id: "allow_once".into(),
                name: "Allow once".into(),
                kind: PermissionKind::AllowOnce,
            }],
        }
    }

    #[test]
    fn register_take_roundtrip() {
        let mut b = PermissionBroker::new();
        b.register(fixture("p1")).unwrap();
        assert!(b.contains("p1"));
        let taken = b.take("p1").unwrap();
        assert_eq!(taken.request_id, "p1");
        assert!(!b.contains("p1"));
    }

    #[test]
    fn duplicate_register_fails() {
        let mut b = PermissionBroker::new();
        b.register(fixture("p1")).unwrap();
        assert!(matches!(
            b.register(fixture("p1")),
            Err(BrokerError::Duplicate(_))
        ));
    }

    #[test]
    fn take_unknown_fails() {
        let mut b = PermissionBroker::new();
        assert!(matches!(b.take("nope"), Err(BrokerError::Unknown(_))));
    }
}
