//! Project CRUD.
//!
//! A project is a named container for sessions sharing a repo path. Sessions
//! reference a project via `sessions.project_id`. Deleting a project that
//! still owns live (non-archived) sessions is rejected at this layer.

use crate::{models::ProjectRow, now_ms, PersistError};
use sqlx::SqlitePool;

pub struct ProjectRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewProject {
    pub id: String,
    pub name: String,
    pub repo_path: String,
}

impl<'a> ProjectRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn insert(&self, new: NewProject) -> Result<ProjectRow, PersistError> {
        let row = ProjectRow {
            id: new.id,
            name: new.name,
            repo_path: new.repo_path,
            created_at: now_ms(),
        };
        sqlx::query("INSERT INTO projects (id, name, repo_path, created_at) VALUES (?, ?, ?, ?)")
            .bind(&row.id)
            .bind(&row.name)
            .bind(&row.repo_path)
            .bind(row.created_at)
            .execute(self.pool)
            .await?;
        Ok(row)
    }

    pub async fn get(&self, id: &str) -> Result<ProjectRow, PersistError> {
        sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects WHERE id = ?")
            .bind(id)
            .fetch_optional(self.pool)
            .await?
            .ok_or_else(|| PersistError::ProjectNotFound(id.to_string()))
    }

    /// All projects, newest first.
    pub async fn list(&self) -> Result<Vec<ProjectRow>, PersistError> {
        Ok(
            sqlx::query_as::<_, ProjectRow>("SELECT * FROM projects ORDER BY created_at DESC")
                .fetch_all(self.pool)
                .await?,
        )
    }

    /// Number of non-archived sessions belonging to a project.
    pub async fn live_session_count(&self, id: &str) -> Result<i64, PersistError> {
        let count: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM sessions WHERE project_id = ? AND archived_at IS NULL",
        )
        .bind(id)
        .fetch_one(self.pool)
        .await?;
        Ok(count)
    }

    /// Delete a project. Refuses if any non-archived sessions still reference
    /// it — caller should archive those first. Archived sessions get
    /// cascade-deleted by the FK.
    pub async fn delete(&self, id: &str) -> Result<(), PersistError> {
        let live = self.live_session_count(id).await?;
        if live > 0 {
            return Err(PersistError::ProjectNotEmpty(id.to_string(), live));
        }
        let res = sqlx::query("DELETE FROM projects WHERE id = ?")
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::ProjectNotFound(id.to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{session_repo::NewSession, Db};

    fn project_fixture(id: &str) -> NewProject {
        NewProject {
            id: id.into(),
            name: format!("project-{id}"),
            repo_path: format!("/tmp/repo-{id}"),
        }
    }

    fn session_fixture(id: &str, project_id: &str) -> NewSession {
        NewSession {
            id: id.into(),
            title: "test".into(),
            agent_profile: "claude-code".into(),
            agent_session_id: None,
            agent_thread_name: None,
            project_id: project_id.into(),
        }
    }

    #[tokio::test]
    async fn insert_get_list() {
        let db = Db::open_in_memory().await.unwrap();
        let inserted = db.projects().insert(project_fixture("p1")).await.unwrap();
        assert_eq!(inserted.id, "p1");

        let fetched = db.projects().get("p1").await.unwrap();
        assert_eq!(fetched.name, "project-p1");

        db.projects().insert(project_fixture("p2")).await.unwrap();
        let listed = db.projects().list().await.unwrap();
        assert_eq!(listed.len(), 2);
    }

    #[tokio::test]
    async fn delete_refuses_when_session_lives() {
        let db = Db::open_in_memory().await.unwrap();
        db.projects().insert(project_fixture("p1")).await.unwrap();
        db.sessions()
            .insert(session_fixture("s1", "p1"))
            .await
            .unwrap();

        assert!(matches!(
            db.projects().delete("p1").await,
            Err(PersistError::ProjectNotEmpty(_, 1))
        ));

        db.sessions().archive("s1").await.unwrap();
        assert_eq!(db.projects().live_session_count("p1").await.unwrap(), 0);
        db.projects().delete("p1").await.unwrap();
    }

    #[tokio::test]
    async fn delete_missing_errors() {
        let db = Db::open_in_memory().await.unwrap();
        assert!(matches!(
            db.projects().delete("nope").await,
            Err(PersistError::ProjectNotFound(_))
        ));
    }
}
