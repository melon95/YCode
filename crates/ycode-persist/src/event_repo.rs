//! Event log: per-session ordered transcript with bounded payload size.

use crate::{models::EventRow, now_ms, PersistError};
use sqlx::SqlitePool;
use ycode_adapter::AgentEvent;

pub struct EventRepo<'a> {
    pool: &'a SqlitePool,
}

/// Hard cap on persisted `RawOutput.bytes` size. Keeps a runaway PTY adapter
/// from filling the database with terminal vomit.
const RAW_OUTPUT_BUDGET: usize = 64 * 1024;

impl<'a> EventRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    /// Append an event. The next `seq` is computed inside the transaction, so
    /// concurrent writers for the same session won't collide on the unique
    /// `(session_id, seq)` index.
    pub async fn append(
        &self,
        session_id: &str,
        event: &AgentEvent,
    ) -> Result<EventRow, PersistError> {
        let mut tx = self.pool.begin().await?;
        let next_seq: i64 =
            sqlx::query_scalar("SELECT COALESCE(MAX(seq), -1) + 1 FROM events WHERE session_id = ?")
                .bind(session_id)
                .fetch_one(&mut *tx)
                .await?;

        let truncated = truncate_raw_output(event);
        let payload = serde_json::to_string(&truncated)?;
        let ts = now_ms();

        let id: i64 = sqlx::query_scalar(
            "INSERT INTO events (session_id, seq, ts, payload) VALUES (?, ?, ?, ?) RETURNING id",
        )
        .bind(session_id)
        .bind(next_seq)
        .bind(ts)
        .bind(&payload)
        .fetch_one(&mut *tx)
        .await?;

        tx.commit().await?;

        Ok(EventRow {
            id,
            session_id: session_id.into(),
            seq: next_seq,
            ts,
            payload,
        })
    }

    /// Replay events in order. `from_seq` defaults to 0 (the start).
    pub async fn replay(
        &self,
        session_id: &str,
        from_seq: i64,
    ) -> Result<Vec<EventRow>, PersistError> {
        Ok(sqlx::query_as::<_, EventRow>(
            "SELECT * FROM events WHERE session_id = ? AND seq >= ? ORDER BY seq ASC",
        )
        .bind(session_id)
        .bind(from_seq)
        .fetch_all(self.pool)
        .await?)
    }
}

/// If the event is `RawOutput` larger than the budget, return a truncated
/// copy. Otherwise return the input unchanged. Truncation keeps the head of
/// the buffer; the tail is more often interesting but the head is more often
/// human-meaningful for error diagnosis.
fn truncate_raw_output(event: &AgentEvent) -> AgentEvent {
    match event {
        AgentEvent::RawOutput { bytes } if bytes.len() > RAW_OUTPUT_BUDGET => {
            let mut truncated = bytes[..RAW_OUTPUT_BUDGET].to_vec();
            truncated.extend_from_slice(b"\n[ycode: truncated]\n");
            AgentEvent::RawOutput { bytes: truncated }
        }
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_repo::NewSession;
    use crate::Db;
    use ycode_adapter::SessionState;

    async fn seeded_db() -> Db {
        let db = Db::open_in_memory().await.unwrap();
        db.sessions()
            .insert(NewSession {
                id: "s1".into(),
                title: "t".into(),
                agent_profile: "claude-code".into(),
                repo_root: "/r".into(),
                worktree_path: "/w".into(),
                branch: "b".into(),
                base_ref: "0".into(),
                initial_state: SessionState::Idle,
            })
            .await
            .unwrap();
        db
    }

    #[tokio::test]
    async fn append_assigns_monotonic_seq() {
        let db = seeded_db().await;
        let r0 = db
            .events()
            .append(
                "s1",
                &AgentEvent::AssistantText {
                    chunk_id: "c0".into(),
                    text: "hello".into(),
                    final_chunk: false,
                },
            )
            .await
            .unwrap();
        let r1 = db
            .events()
            .append(
                "s1",
                &AgentEvent::AssistantText {
                    chunk_id: "c1".into(),
                    text: "world".into(),
                    final_chunk: true,
                },
            )
            .await
            .unwrap();
        assert_eq!(r0.seq, 0);
        assert_eq!(r1.seq, 1);
    }

    #[tokio::test]
    async fn raw_output_is_truncated() {
        let db = seeded_db().await;
        let big = vec![b'x'; 200 * 1024];
        let row = db
            .events()
            .append("s1", &AgentEvent::RawOutput { bytes: big })
            .await
            .unwrap();
        let parsed: AgentEvent = serde_json::from_str(&row.payload).unwrap();
        match parsed {
            AgentEvent::RawOutput { bytes } => {
                // 64 KiB plus the small marker tail.
                assert!(bytes.len() < 70 * 1024);
                assert!(bytes.len() > 64 * 1024);
            }
            _ => panic!("expected RawOutput"),
        }
    }

    #[tokio::test]
    async fn replay_returns_in_order() {
        let db = seeded_db().await;
        for i in 0..5 {
            db.events()
                .append(
                    "s1",
                    &AgentEvent::AssistantText {
                        chunk_id: format!("c{i}"),
                        text: format!("t{i}"),
                        final_chunk: false,
                    },
                )
                .await
                .unwrap();
        }
        let rows = db.events().replay("s1", 0).await.unwrap();
        assert_eq!(rows.len(), 5);
        for (i, r) in rows.iter().enumerate() {
            assert_eq!(r.seq, i as i64);
        }
        let from_2 = db.events().replay("s1", 2).await.unwrap();
        assert_eq!(from_2.len(), 3);
    }
}
