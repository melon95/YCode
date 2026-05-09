//! Session CRUD.

use crate::{models::SessionRow, now_ms, PersistError};
use sqlx::SqlitePool;
use ycode_adapter::SessionState;

pub struct SessionRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewSession {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub repo_root: String,
    pub worktree_path: String,
    pub branch: String,
    pub base_ref: String,
    pub initial_state: SessionState,
}

impl<'a> SessionRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn insert(&self, new: NewSession) -> Result<SessionRow, PersistError> {
        let now = now_ms();
        let state_json = serde_json::to_string(&new.initial_state)?;
        let row = SessionRow {
            id: new.id,
            title: new.title,
            agent_profile: new.agent_profile,
            repo_root: new.repo_root,
            worktree_path: new.worktree_path,
            branch: new.branch,
            base_ref: new.base_ref,
            state: state_json,
            created_at: now,
            updated_at: now,
            archived_at: None,
        };
        sqlx::query(
            "INSERT INTO sessions \
             (id, title, agent_profile, repo_root, worktree_path, branch, base_ref, state, created_at, updated_at, archived_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)",
        )
        .bind(&row.id)
        .bind(&row.title)
        .bind(&row.agent_profile)
        .bind(&row.repo_root)
        .bind(&row.worktree_path)
        .bind(&row.branch)
        .bind(&row.base_ref)
        .bind(&row.state)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get(&self, id: &str) -> Result<SessionRow, PersistError> {
        sqlx::query_as::<_, SessionRow>("SELECT * FROM sessions WHERE id = ?")
            .bind(id)
            .fetch_optional(self.pool)
            .await?
            .ok_or_else(|| PersistError::SessionNotFound(id.to_string()))
    }

    /// Live (non-archived) sessions, most-recently-updated first.
    pub async fn list_live(&self) -> Result<Vec<SessionRow>, PersistError> {
        Ok(sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions WHERE archived_at IS NULL ORDER BY updated_at DESC",
        )
        .fetch_all(self.pool)
        .await?)
    }

    pub async fn list_all(&self) -> Result<Vec<SessionRow>, PersistError> {
        Ok(
            sqlx::query_as::<_, SessionRow>("SELECT * FROM sessions ORDER BY updated_at DESC")
                .fetch_all(self.pool)
                .await?,
        )
    }

    pub async fn update_state(
        &self,
        id: &str,
        state: &SessionState,
    ) -> Result<(), PersistError> {
        let state_json = serde_json::to_string(state)?;
        let now = now_ms();
        let res = sqlx::query("UPDATE sessions SET state = ?, updated_at = ? WHERE id = ?")
            .bind(&state_json)
            .bind(now)
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }

    pub async fn archive(&self, id: &str) -> Result<(), PersistError> {
        let now = now_ms();
        let res = sqlx::query(
            "UPDATE sessions SET archived_at = ?, updated_at = ? WHERE id = ? AND archived_at IS NULL",
        )
        .bind(now)
        .bind(now)
        .bind(id)
        .execute(self.pool)
        .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Db;

    fn fixture(id: &str) -> NewSession {
        NewSession {
            id: id.into(),
            title: "test".into(),
            agent_profile: "claude-code".into(),
            repo_root: "/tmp/repo".into(),
            worktree_path: "/tmp/wt".into(),
            branch: "ycode/abc".into(),
            base_ref: "deadbeef".into(),
            initial_state: SessionState::Initializing,
        }
    }

    #[tokio::test]
    async fn insert_get_list_archive() {
        let db = Db::open_in_memory().await.unwrap();

        let inserted = db.sessions().insert(fixture("01")).await.unwrap();
        assert_eq!(inserted.id, "01");

        let fetched = db.sessions().get("01").await.unwrap();
        assert_eq!(fetched.title, "test");

        let live = db.sessions().list_live().await.unwrap();
        assert_eq!(live.len(), 1);

        db.sessions().archive("01").await.unwrap();
        assert!(db.sessions().list_live().await.unwrap().is_empty());
        assert_eq!(db.sessions().list_all().await.unwrap().len(), 1);
    }

    #[tokio::test]
    async fn update_state_persists_json() {
        let db = Db::open_in_memory().await.unwrap();
        db.sessions().insert(fixture("02")).await.unwrap();

        let new_state = SessionState::Running { turn_id: "t-1".into() };
        db.sessions().update_state("02", &new_state).await.unwrap();

        let row = db.sessions().get("02").await.unwrap();
        let parsed: SessionState = serde_json::from_str(&row.state).unwrap();
        assert!(matches!(parsed, SessionState::Running { .. }));
    }

    #[tokio::test]
    async fn missing_session_errors() {
        let db = Db::open_in_memory().await.unwrap();
        assert!(matches!(
            db.sessions().get("nope").await,
            Err(PersistError::SessionNotFound(_))
        ));
    }
}
