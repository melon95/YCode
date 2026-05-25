//! Session CRUD. Under terminal-first the row is just identity + bookkeeping
//! — runtime status lives in the in-memory TerminalManager.

use crate::{models::SessionRow, now_ms, PersistError};
use sqlx::SqlitePool;

pub struct SessionRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewSession {
    pub id: String,
    pub title: String,
    pub agent_profile: String,
    pub agent_session_id: Option<String>,
    pub agent_thread_name: Option<String>,
    pub project_id: String,
}

impl<'a> SessionRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn insert(&self, new: NewSession) -> Result<SessionRow, PersistError> {
        let now = now_ms();
        let row = SessionRow {
            id: new.id,
            title: new.title,
            agent_profile: new.agent_profile,
            agent_session_id: new.agent_session_id,
            agent_thread_name: new.agent_thread_name,
            project_id: new.project_id,
            last_exit_code: None,
            created_at: now,
            updated_at: now,
            archived_at: None,
        };
        sqlx::query(
            "INSERT INTO sessions \
             (id, title, agent_profile, agent_session_id, agent_thread_name, project_id, last_exit_code, created_at, updated_at, archived_at) \
             VALUES (?, ?, ?, ?, ?, ?, NULL, ?, ?, NULL)",
        )
        .bind(&row.id)
        .bind(&row.title)
        .bind(&row.agent_profile)
        .bind(&row.agent_session_id)
        .bind(&row.agent_thread_name)
        .bind(&row.project_id)
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

    /// All non-archived sessions belonging to a given project, newest first.
    pub async fn list_for_project(
        &self,
        project_id: &str,
    ) -> Result<Vec<SessionRow>, PersistError> {
        Ok(sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions WHERE project_id = ? AND archived_at IS NULL ORDER BY updated_at DESC",
        )
        .bind(project_id)
        .fetch_all(self.pool)
        .await?)
    }

    /// All live (non-archived) sessions across every project.
    pub async fn list_live(&self) -> Result<Vec<SessionRow>, PersistError> {
        Ok(sqlx::query_as::<_, SessionRow>(
            "SELECT * FROM sessions WHERE archived_at IS NULL ORDER BY updated_at DESC",
        )
        .fetch_all(self.pool)
        .await?)
    }

    /// Record the child's exit code. Bumps `updated_at` so the row sorts to
    /// the top of recency lists when a session just died.
    pub async fn set_exit_code(&self, id: &str, code: Option<i32>) -> Result<(), PersistError> {
        let now = now_ms();
        let res =
            sqlx::query("UPDATE sessions SET last_exit_code = ?, updated_at = ? WHERE id = ?")
                .bind(code.map(|c| c as i64))
                .bind(now)
                .bind(id)
                .execute(self.pool)
                .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }

    /// Persist a user-chosen title. Bumps `updated_at` so the row floats to
    /// the top of recency lists immediately after the rename.
    pub async fn update_title(&self, id: &str, title: &str) -> Result<(), PersistError> {
        let now = now_ms();
        let res = sqlx::query("UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?")
            .bind(title)
            .bind(now)
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }

    /// Bump `updated_at` without changing other fields. Used when title or
    /// runtime status changes in a way callers want surfaced to the UI.
    pub async fn touch(&self, id: &str) -> Result<(), PersistError> {
        let res = sqlx::query("UPDATE sessions SET updated_at = ? WHERE id = ?")
            .bind(now_ms())
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }

    pub async fn update_agent_thread_name(
        &self,
        id: &str,
        thread_name: &str,
    ) -> Result<(), PersistError> {
        let res = sqlx::query("UPDATE sessions SET agent_thread_name = ? WHERE id = ?")
            .bind(thread_name)
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::SessionNotFound(id.to_string()));
        }
        Ok(())
    }

    pub async fn update_agent_session_id(
        &self,
        id: &str,
        agent_session_id: &str,
    ) -> Result<(), PersistError> {
        let res = sqlx::query("UPDATE sessions SET agent_session_id = ? WHERE id = ?")
            .bind(agent_session_id)
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

    fn fixture(id: &str, project_id: &str) -> NewSession {
        NewSession {
            id: id.into(),
            title: "test".into(),
            agent_profile: "claude-code".into(),
            agent_session_id: None,
            agent_thread_name: None,
            project_id: project_id.into(),
        }
    }

    async fn seed_project(db: &Db) {
        db.projects()
            .insert(crate::NewProject {
                id: "p-test".into(),
                name: "test".into(),
                repo_path: "/tmp/repo".into(),
            })
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn insert_get_list_archive() {
        let db = Db::open_in_memory().await.unwrap();
        seed_project(&db).await;

        let inserted = db.sessions().insert(fixture("01", "p-test")).await.unwrap();
        assert_eq!(inserted.id, "01");
        assert!(inserted.last_exit_code.is_none());

        let fetched = db.sessions().get("01").await.unwrap();
        assert_eq!(fetched.title, "test");

        let live = db.sessions().list_live().await.unwrap();
        assert_eq!(live.len(), 1);

        db.sessions().archive("01").await.unwrap();
        assert!(db.sessions().list_live().await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn set_exit_code_round_trip() {
        let db = Db::open_in_memory().await.unwrap();
        seed_project(&db).await;
        db.sessions().insert(fixture("02", "p-test")).await.unwrap();

        db.sessions().set_exit_code("02", Some(1)).await.unwrap();
        let row = db.sessions().get("02").await.unwrap();
        assert_eq!(row.last_exit_code, Some(1));

        // None (signal-killed) is also representable.
        db.sessions().set_exit_code("02", None).await.unwrap();
        let row = db.sessions().get("02").await.unwrap();
        assert!(row.last_exit_code.is_none());
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
