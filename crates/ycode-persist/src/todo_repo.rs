//! Per-project todo CRUD.
//!
//! A todo belongs to one project (`project_todos.project_id`) and carries a
//! workflow status of `todo` / `doing` / `done`. New todos append to the end
//! of the project's list (sort_order = current max + 1). Deleting a project
//! cascade-deletes its todos via the FK.

use crate::{models::TodoRow, now_ms, PersistError};
use sqlx::SqlitePool;

pub struct TodoRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewTodo {
    pub id: String,
    pub project_id: String,
    pub title: String,
}

/// The three valid workflow states. Kept here so both the repo and callers
/// share one source of truth.
pub const TODO_STATUSES: [&str; 3] = ["todo", "doing", "done"];

fn validate_status(status: &str) -> Result<(), PersistError> {
    if TODO_STATUSES.contains(&status) {
        Ok(())
    } else {
        Err(PersistError::InvalidTodoStatus(status.to_string()))
    }
}

impl<'a> TodoRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    /// Insert a new todo at the bottom of its project's list. Status defaults
    /// to `todo`.
    pub async fn insert(&self, new: NewTodo) -> Result<TodoRow, PersistError> {
        // Next sort_order = max within the project + 1 (0 for the first row).
        let next_order: i64 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(sort_order) + 1, 0) FROM project_todos WHERE project_id = ?",
        )
        .bind(&new.project_id)
        .fetch_one(self.pool)
        .await?;

        let now = now_ms();
        let row = TodoRow {
            id: new.id,
            project_id: new.project_id,
            title: new.title,
            status: "todo".to_string(),
            sort_order: next_order,
            started_at: None,
            done_at: None,
            created_at: now,
            updated_at: now,
        };
        sqlx::query(
            "INSERT INTO project_todos \
             (id, project_id, title, status, sort_order, started_at, done_at, created_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&row.id)
        .bind(&row.project_id)
        .bind(&row.title)
        .bind(&row.status)
        .bind(row.sort_order)
        .bind(row.started_at)
        .bind(row.done_at)
        .bind(row.created_at)
        .bind(row.updated_at)
        .execute(self.pool)
        .await?;
        Ok(row)
    }

    pub async fn get(&self, id: &str) -> Result<TodoRow, PersistError> {
        sqlx::query_as::<_, TodoRow>("SELECT * FROM project_todos WHERE id = ?")
            .bind(id)
            .fetch_optional(self.pool)
            .await?
            .ok_or_else(|| PersistError::TodoNotFound(id.to_string()))
    }

    /// All todos for a project, in manual order (oldest tie-break).
    pub async fn list_for_project(&self, project_id: &str) -> Result<Vec<TodoRow>, PersistError> {
        Ok(sqlx::query_as::<_, TodoRow>(
            "SELECT * FROM project_todos WHERE project_id = ? ORDER BY sort_order ASC, created_at ASC",
        )
        .bind(project_id)
        .fetch_all(self.pool)
        .await?)
    }

    /// Partial update: `title` and/or `status`. Always refreshes `updated_at`.
    /// Returns the updated row. Errors if the row is missing or `status` is
    /// invalid.
    pub async fn update(
        &self,
        id: &str,
        title: Option<&str>,
        status: Option<&str>,
    ) -> Result<TodoRow, PersistError> {
        if let Some(s) = status {
            validate_status(s)?;
        }
        // Fetch first so we can apply a partial patch and return the full row
        // without a second round-trip's worth of branching SQL.
        let mut row = self.get(id).await?;
        let now = now_ms();
        if let Some(t) = title {
            row.title = t.to_string();
        }
        if let Some(s) = status {
            // Stamp the per-status timestamp on transition *into* a state
            // (old status differs). Re-applying the same status is a no-op so
            // it doesn't keep bumping the timestamp.
            if s != row.status {
                match s {
                    "doing" => row.started_at = Some(now),
                    "done" => row.done_at = Some(now),
                    _ => {}
                }
            }
            row.status = s.to_string();
        }
        row.updated_at = now;

        sqlx::query(
            "UPDATE project_todos \
             SET title = ?, status = ?, started_at = ?, done_at = ?, updated_at = ? \
             WHERE id = ?",
        )
        .bind(&row.title)
        .bind(&row.status)
        .bind(row.started_at)
        .bind(row.done_at)
        .bind(row.updated_at)
        .bind(id)
        .execute(self.pool)
        .await?;
        Ok(row)
    }

    /// Persist a manual ordering: assign `sort_order = position` to each id in
    /// `ordered_ids`, scoped to `project_id`. Ids not belonging to the project
    /// (or unknown) are silently skipped. Runs in one transaction so the list
    /// never observes a half-applied order.
    pub async fn reorder(
        &self,
        project_id: &str,
        ordered_ids: &[String],
    ) -> Result<(), PersistError> {
        let mut tx = self.pool.begin().await?;
        for (idx, id) in ordered_ids.iter().enumerate() {
            sqlx::query(
                "UPDATE project_todos SET sort_order = ? WHERE id = ? AND project_id = ?",
            )
            .bind(idx as i64)
            .bind(id)
            .bind(project_id)
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn delete(&self, id: &str) -> Result<(), PersistError> {
        let res = sqlx::query("DELETE FROM project_todos WHERE id = ?")
            .bind(id)
            .execute(self.pool)
            .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::TodoNotFound(id.to_string()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{project_repo::NewProject, Db};

    async fn seeded_db() -> Db {
        let db = Db::open_in_memory().await.unwrap();
        db.projects()
            .insert(NewProject {
                id: "p1".into(),
                name: "proj".into(),
                repo_path: "/tmp/p1".into(),
            })
            .await
            .unwrap();
        db
    }

    fn todo_fixture(id: &str) -> NewTodo {
        NewTodo {
            id: id.into(),
            project_id: "p1".into(),
            title: format!("todo-{id}"),
        }
    }

    #[tokio::test]
    async fn insert_defaults_to_todo_and_appends() {
        let db = seeded_db().await;
        let a = db.todos().insert(todo_fixture("a")).await.unwrap();
        let b = db.todos().insert(todo_fixture("b")).await.unwrap();
        assert_eq!(a.status, "todo");
        assert_eq!(a.sort_order, 0);
        assert_eq!(b.sort_order, 1);
    }

    #[tokio::test]
    async fn list_is_ordered() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();
        db.todos().insert(todo_fixture("b")).await.unwrap();
        let list = db.todos().list_for_project("p1").await.unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].id, "a");
        assert_eq!(list[1].id, "b");
    }

    #[tokio::test]
    async fn update_partial_and_status_validation() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();

        let updated = db
            .todos()
            .update("a", None, Some("doing"))
            .await
            .unwrap();
        assert_eq!(updated.status, "doing");
        assert_eq!(updated.title, "todo-a");

        let renamed = db.todos().update("a", Some("new title"), None).await.unwrap();
        assert_eq!(renamed.title, "new title");
        assert_eq!(renamed.status, "doing");

        assert!(matches!(
            db.todos().update("a", None, Some("bogus")).await,
            Err(PersistError::InvalidTodoStatus(_))
        ));
    }

    #[tokio::test]
    async fn status_timestamps_set_on_transition() {
        let db = seeded_db().await;
        let created = db.todos().insert(todo_fixture("a")).await.unwrap();
        assert!(created.started_at.is_none());
        assert!(created.done_at.is_none());

        let doing = db.todos().update("a", None, Some("doing")).await.unwrap();
        assert!(doing.started_at.is_some());
        assert!(doing.done_at.is_none());
        let first_started = doing.started_at;

        let done = db.todos().update("a", None, Some("done")).await.unwrap();
        assert_eq!(done.started_at, first_started, "started_at preserved");
        assert!(done.done_at.is_some());

        // Re-applying the same status must NOT re-stamp the timestamp.
        let again = db.todos().update("a", Some("renamed"), Some("done")).await.unwrap();
        assert_eq!(again.done_at, done.done_at, "same-status update keeps done_at");

        // A title-only update leaves both stamps untouched.
        let title_only = db.todos().update("a", Some("x"), None).await.unwrap();
        assert_eq!(title_only.started_at, first_started);
        assert_eq!(title_only.done_at, done.done_at);
    }

    #[tokio::test]
    async fn reorder_assigns_positions() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();
        db.todos().insert(todo_fixture("b")).await.unwrap();
        db.todos().insert(todo_fixture("c")).await.unwrap();

        db.todos()
            .reorder("p1", &["c".into(), "a".into(), "b".into()])
            .await
            .unwrap();

        let list = db.todos().list_for_project("p1").await.unwrap();
        assert_eq!(
            list.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(),
            ["c", "a", "b"]
        );
        assert_eq!(list[0].sort_order, 0);
        assert_eq!(list[1].sort_order, 1);
        assert_eq!(list[2].sort_order, 2);
    }

    #[tokio::test]
    async fn reorder_ignores_foreign_ids() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();
        // "ghost" is not a real todo — it must be skipped, not error.
        db.todos()
            .reorder("p1", &["ghost".into(), "a".into()])
            .await
            .unwrap();
        let list = db.todos().list_for_project("p1").await.unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].sort_order, 1);
    }

    #[tokio::test]
    async fn delete_and_missing() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();
        db.todos().delete("a").await.unwrap();
        assert!(matches!(
            db.todos().get("a").await,
            Err(PersistError::TodoNotFound(_))
        ));
        assert!(matches!(
            db.todos().delete("a").await,
            Err(PersistError::TodoNotFound(_))
        ));
    }

    #[tokio::test]
    async fn project_delete_cascades_to_todos() {
        let db = seeded_db().await;
        db.todos().insert(todo_fixture("a")).await.unwrap();
        db.projects().delete("p1").await.unwrap();
        let list = db.todos().list_for_project("p1").await.unwrap();
        assert!(list.is_empty());
    }
}
