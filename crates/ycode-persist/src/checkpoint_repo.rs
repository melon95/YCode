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
        Ok(sqlx::query_as::<_, CheckpointListRow>(
            "SELECT c.*, s.title AS session_title, s.agent_profile \
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
}
