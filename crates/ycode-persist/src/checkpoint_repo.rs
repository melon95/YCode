//! Durable metadata for git-backed agent-turn checkpoints.

use crate::{models::CheckpointRow, now_ms, PersistError};
use sqlx::SqlitePool;

pub const CHECKPOINT_KINDS: &[&str] = &["initial", "turn"];

pub struct CheckpointRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewCheckpoint {
    pub id: String,
    pub session_id: String,
    pub project_id: String,
    pub commit_sha: String,
    pub ref_name: String,
    pub kind: String,
    pub source: Option<String>,
    pub event_kind: Option<String>,
    pub body_preview: Option<String>,
}

#[derive(Clone, Debug, sqlx::FromRow)]
pub struct CheckpointListRow {
    pub id: String,
    pub session_id: String,
    pub project_id: String,
    pub sequence: i64,
    pub commit_sha: String,
    pub ref_name: String,
    pub kind: String,
    pub source: Option<String>,
    pub event_kind: Option<String>,
    pub body_preview: Option<String>,
    pub created_at: i64,
    pub session_title: String,
    pub agent_profile: String,
    /// Smallest sequence still stored for this row's session. Pruning deletes
    /// low-sequence rows, so "is there a previous turn to diff against" must
    /// compare against what actually survives in the DB, not against zero.
    pub session_min_sequence: i64,
}

impl<'a> CheckpointRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn insert(&self, new: NewCheckpoint) -> Result<CheckpointRow, PersistError> {
        if !CHECKPOINT_KINDS.contains(&new.kind.as_str()) {
            return Err(PersistError::InvalidCheckpointKind(new.kind));
        }
        let created_at = now_ms();
        // Derive the next sequence inside the INSERT statement. SQLite
        // serializes writers, and the UNIQUE(session_id, sequence) constraint
        // remains the final guard if two completion hooks race.
        sqlx::query(
            "INSERT INTO session_checkpoints \
             (id, session_id, project_id, sequence, commit_sha, ref_name, kind, source, event_kind, body_preview, created_at) \
             SELECT ?, ?, ?, COALESCE(MAX(sequence), -1) + 1, ?, ?, ?, ?, ?, ?, ? \
             FROM session_checkpoints WHERE session_id = ?",
        )
        .bind(&new.id)
        .bind(&new.session_id)
        .bind(&new.project_id)
        .bind(&new.commit_sha)
        .bind(&new.ref_name)
        .bind(&new.kind)
        .bind(&new.source)
        .bind(&new.event_kind)
        .bind(&new.body_preview)
        .bind(created_at)
        .bind(&new.session_id)
        .execute(self.pool)
        .await?;
        self.get(&new.id).await
    }

    pub async fn get(&self, id: &str) -> Result<CheckpointRow, PersistError> {
        sqlx::query_as::<_, CheckpointRow>("SELECT * FROM session_checkpoints WHERE id = ?")
            .bind(id)
            .fetch_optional(self.pool)
            .await?
            .ok_or_else(|| PersistError::CheckpointNotFound(id.to_string()))
    }

    pub async fn previous(
        &self,
        session_id: &str,
        sequence: i64,
    ) -> Result<Option<CheckpointRow>, PersistError> {
        Ok(sqlx::query_as::<_, CheckpointRow>(
            "SELECT * FROM session_checkpoints \
             WHERE session_id = ? AND sequence < ? ORDER BY sequence DESC LIMIT 1",
        )
        .bind(session_id)
        .bind(sequence)
        .fetch_optional(self.pool)
        .await?)
    }

    pub async fn latest_for_session(
        &self,
        session_id: &str,
    ) -> Result<Option<CheckpointRow>, PersistError> {
        Ok(sqlx::query_as::<_, CheckpointRow>(
            "SELECT * FROM session_checkpoints \
             WHERE session_id = ? ORDER BY sequence DESC LIMIT 1",
        )
        .bind(session_id)
        .fetch_optional(self.pool)
        .await?)
    }

    pub async fn list_for_project(
        &self,
        project_id: &str,
    ) -> Result<Vec<CheckpointListRow>, PersistError> {
        // The window MIN is computed once per partition rather than as a
        // per-row correlated subquery, keeping the list query a single pass.
        Ok(sqlx::query_as::<_, CheckpointListRow>(
            "SELECT c.*, s.title AS session_title, s.agent_profile, \
             MIN(c.sequence) OVER (PARTITION BY c.session_id) AS session_min_sequence \
             FROM session_checkpoints c \
             JOIN sessions s ON s.id = c.session_id \
             WHERE c.project_id = ? \
             ORDER BY c.created_at DESC, c.id DESC",
        )
        .bind(project_id)
        .fetch_all(self.pool)
        .await?)
    }

    pub async fn refs_for_project(&self, project_id: &str) -> Result<Vec<String>, PersistError> {
        Ok(sqlx::query_scalar::<_, String>(
            "SELECT ref_name FROM session_checkpoints WHERE project_id = ?",
        )
        .bind(project_id)
        .fetch_all(self.pool)
        .await?)
    }

    pub async fn refs_for_session(&self, session_id: &str) -> Result<Vec<String>, PersistError> {
        Ok(sqlx::query_scalar::<_, String>(
            "SELECT ref_name FROM session_checkpoints WHERE session_id = ?",
        )
        .bind(session_id)
        .fetch_all(self.pool)
        .await?)
    }

    pub async fn delete_for_session(&self, session_id: &str) -> Result<(), PersistError> {
        sqlx::query("DELETE FROM session_checkpoints WHERE session_id = ?")
            .bind(session_id)
            .execute(self.pool)
            .await?;
        Ok(())
    }

    /// Drop this session's oldest checkpoints until only `keep` remain, and
    /// return their git refs so the caller can delete the objects too.
    ///
    /// The rows go first and the refs second — losing a ref whose row is gone
    /// only wastes disk until `git gc`, whereas a row pointing at a deleted
    /// ref is a checkpoint the user can see in the timeline but not restore.
    pub async fn prune_for_session(
        &self,
        session_id: &str,
        keep: u32,
    ) -> Result<Vec<String>, PersistError> {
        // `keep` of zero would wipe the session's whole timeline on the next
        // turn — treat it as "keep the current one" rather than as a licence
        // to delete everything.
        let keep = keep.max(1);
        let stale = sqlx::query_scalar::<_, String>(
            "SELECT ref_name FROM session_checkpoints WHERE session_id = ? \
             ORDER BY sequence DESC LIMIT -1 OFFSET ?",
        )
        .bind(session_id)
        .bind(keep as i64)
        .fetch_all(self.pool)
        .await?;
        if stale.is_empty() {
            return Ok(stale);
        }
        sqlx::query(
            "DELETE FROM session_checkpoints WHERE session_id = ? AND id IN (\
               SELECT id FROM session_checkpoints WHERE session_id = ? \
               ORDER BY sequence DESC LIMIT -1 OFFSET ?)",
        )
        .bind(session_id)
        .bind(session_id)
        .bind(keep as i64)
        .execute(self.pool)
        .await?;
        Ok(stale)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{project_repo::NewProject, session_repo::NewSession, Db};

    async fn fixture() -> Db {
        let db = Db::open_in_memory().await.unwrap();
        db.projects()
            .insert(NewProject {
                id: "p1".into(),
                name: "project".into(),
                repo_path: "/tmp/repo".into(),
            })
            .await
            .unwrap();
        db.sessions()
            .insert(NewSession {
                id: "s1".into(),
                title: "Review workspace".into(),
                agent_profile: "codex".into(),
                agent_session_id: None,
                agent_thread_name: None,
                project_id: "p1".into(),
                worktree_path: None,
                branch: None,
                base_branch: None,
            })
            .await
            .unwrap();
        db
    }

    fn new_checkpoint(id: &str, kind: &str) -> NewCheckpoint {
        NewCheckpoint {
            id: id.into(),
            session_id: "s1".into(),
            project_id: "p1".into(),
            commit_sha: format!("sha-{id}"),
            ref_name: format!("refs/ycode/checkpoints/s1/{id}"),
            kind: kind.into(),
            source: Some("codex".into()),
            event_kind: Some("turn_complete".into()),
            body_preview: Some(format!("preview {id}")),
        }
    }

    #[tokio::test]
    async fn sequences_and_lists_checkpoints() {
        let db = fixture().await;
        let initial = db
            .checkpoints()
            .insert(new_checkpoint("c0", "initial"))
            .await
            .unwrap();
        let turn = db
            .checkpoints()
            .insert(new_checkpoint("c1", "turn"))
            .await
            .unwrap();
        assert_eq!(initial.sequence, 0);
        assert_eq!(turn.sequence, 1);

        let previous = db
            .checkpoints()
            .previous("s1", turn.sequence)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(previous.id, initial.id);

        let listed = db.checkpoints().list_for_project("p1").await.unwrap();
        assert_eq!(listed.len(), 2);
        assert_eq!(listed[0].session_title, "Review workspace");
    }

    #[tokio::test]
    async fn rejects_invalid_kind() {
        let db = fixture().await;
        let err = db
            .checkpoints()
            .insert(new_checkpoint("bad", "manual"))
            .await
            .unwrap_err();
        assert!(matches!(err, PersistError::InvalidCheckpointKind(_)));
    }

    #[tokio::test]
    async fn prune_drops_oldest_and_returns_their_refs() {
        let db = fixture().await;
        db.checkpoints()
            .insert(new_checkpoint("c0", "initial"))
            .await
            .unwrap();
        for n in 1..5 {
            db.checkpoints()
                .insert(new_checkpoint(&format!("c{n}"), "turn"))
                .await
                .unwrap();
        }

        let stale = db.checkpoints().prune_for_session("s1", 2).await.unwrap();
        assert_eq!(
            stale,
            vec![
                "refs/ycode/checkpoints/s1/c2",
                "refs/ycode/checkpoints/s1/c1",
                "refs/ycode/checkpoints/s1/c0",
            ],
            "oldest three go, newest first in the returned list"
        );

        let left = db.checkpoints().refs_for_session("s1").await.unwrap();
        assert_eq!(left.len(), 2);
        let newest = db
            .checkpoints()
            .latest_for_session("s1")
            .await
            .unwrap()
            .unwrap();
        assert_eq!(newest.id, "c4", "pruning never touches the newest");
    }

    #[tokio::test]
    async fn prune_under_the_limit_is_a_no_op() {
        let db = fixture().await;
        db.checkpoints()
            .insert(new_checkpoint("c0", "initial"))
            .await
            .unwrap();
        let stale = db.checkpoints().prune_for_session("s1", 50).await.unwrap();
        assert!(stale.is_empty());
        assert_eq!(db.checkpoints().refs_for_session("s1").await.unwrap().len(), 1);
    }

    /// After pruning, the oldest surviving row is the new floor of the
    /// timeline: `session_min_sequence` must track what actually remains in
    /// the DB (not zero), because `has_previous` — and with it the review
    /// UI's "can I diff this turn" decision — is derived from it.
    #[tokio::test]
    async fn list_reports_min_sequence_of_surviving_rows() {
        let db = fixture().await;
        db.checkpoints()
            .insert(new_checkpoint("c0", "initial"))
            .await
            .unwrap();
        for n in 1..5 {
            db.checkpoints()
                .insert(new_checkpoint(&format!("c{n}"), "turn"))
                .await
                .unwrap();
        }

        let listed = db.checkpoints().list_for_project("p1").await.unwrap();
        assert!(listed.iter().all(|row| row.session_min_sequence == 0));

        db.checkpoints().prune_for_session("s1", 2).await.unwrap();
        let listed = db.checkpoints().list_for_project("p1").await.unwrap();
        assert_eq!(listed.len(), 2);
        assert!(
            listed.iter().all(|row| row.session_min_sequence == 3),
            "min sequence follows the oldest survivor, got {:?}",
            listed
                .iter()
                .map(|r| (r.sequence, r.session_min_sequence))
                .collect::<Vec<_>>()
        );
        // The oldest survivor has no lower-sequence row left to diff against.
        let oldest = listed.iter().find(|r| r.sequence == 3).unwrap();
        assert_eq!(oldest.sequence, oldest.session_min_sequence);
        let newest = listed.iter().find(|r| r.sequence == 4).unwrap();
        assert!(newest.sequence > newest.session_min_sequence);
    }

    /// `keep: 0` would otherwise wipe the timeline on every capture, leaving
    /// the user with a review panel that is always empty.
    #[tokio::test]
    async fn prune_keeps_at_least_one() {
        let db = fixture().await;
        db.checkpoints()
            .insert(new_checkpoint("c0", "initial"))
            .await
            .unwrap();
        db.checkpoints()
            .insert(new_checkpoint("c1", "turn"))
            .await
            .unwrap();
        db.checkpoints().prune_for_session("s1", 0).await.unwrap();
        assert_eq!(db.checkpoints().refs_for_session("s1").await.unwrap().len(), 1);
    }
}
