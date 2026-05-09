//! Permission requests and decisions.
//!
//! Persisted so that a crash mid-permission doesn't strand a session: on
//! restart, [`PermissionRepo::open_for_session`] surfaces unresolved requests
//! back to the UI.

use crate::{models::PermissionRow, now_ms, PersistError};
use sqlx::SqlitePool;
use ycode_adapter::PermissionOption;

pub struct PermissionRepo<'a> {
    pool: &'a SqlitePool,
}

#[derive(Clone, Debug)]
pub struct NewPermission {
    pub request_id: String,
    pub session_id: String,
    pub tool_name: String,
    pub summary: String,
    pub options: Vec<PermissionOption>,
}

impl<'a> PermissionRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    pub async fn create(&self, new: NewPermission) -> Result<PermissionRow, PersistError> {
        let now = now_ms();
        let options_json = serde_json::to_string(&new.options)?;
        let row = PermissionRow {
            request_id: new.request_id,
            session_id: new.session_id,
            tool_name: new.tool_name,
            summary: new.summary,
            options_json,
            decided_option: None,
            decided_at: None,
            created_at: now,
        };
        sqlx::query(
            "INSERT INTO permissions \
             (request_id, session_id, tool_name, summary, options_json, decided_option, decided_at, created_at) \
             VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)",
        )
        .bind(&row.request_id)
        .bind(&row.session_id)
        .bind(&row.tool_name)
        .bind(&row.summary)
        .bind(&row.options_json)
        .bind(row.created_at)
        .execute(self.pool)
        .await?;
        Ok(row)
    }

    pub async fn resolve(
        &self,
        request_id: &str,
        option_id: &str,
    ) -> Result<(), PersistError> {
        let now = now_ms();
        let res = sqlx::query(
            "UPDATE permissions SET decided_option = ?, decided_at = ? \
             WHERE request_id = ? AND decided_at IS NULL",
        )
        .bind(option_id)
        .bind(now)
        .bind(request_id)
        .execute(self.pool)
        .await?;
        if res.rows_affected() == 0 {
            return Err(PersistError::PermissionNotFound(request_id.to_string()));
        }
        Ok(())
    }

    /// Unresolved requests for a session, oldest first. Used on app restart
    /// to re-surface anything stranded by a previous crash.
    pub async fn open_for_session(
        &self,
        session_id: &str,
    ) -> Result<Vec<PermissionRow>, PersistError> {
        Ok(sqlx::query_as::<_, PermissionRow>(
            "SELECT * FROM permissions WHERE session_id = ? AND decided_at IS NULL ORDER BY created_at ASC",
        )
        .bind(session_id)
        .fetch_all(self.pool)
        .await?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::session_repo::NewSession;
    use crate::Db;
    use ycode_adapter::{PermissionKind, SessionState};

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

    fn fixture(req: &str) -> NewPermission {
        NewPermission {
            request_id: req.into(),
            session_id: "s1".into(),
            tool_name: "write_file".into(),
            summary: "write hello.txt".into(),
            options: vec![
                PermissionOption {
                    option_id: "allow_once".into(),
                    name: "Allow once".into(),
                    kind: PermissionKind::AllowOnce,
                },
                PermissionOption {
                    option_id: "reject_once".into(),
                    name: "Reject".into(),
                    kind: PermissionKind::RejectOnce,
                },
            ],
        }
    }

    #[tokio::test]
    async fn create_resolve_roundtrip() {
        let db = seeded_db().await;
        db.permissions().create(fixture("p1")).await.unwrap();
        assert_eq!(db.permissions().open_for_session("s1").await.unwrap().len(), 1);
        db.permissions().resolve("p1", "allow_once").await.unwrap();
        assert!(db.permissions().open_for_session("s1").await.unwrap().is_empty());
    }

    #[tokio::test]
    async fn double_resolve_errors() {
        let db = seeded_db().await;
        db.permissions().create(fixture("p1")).await.unwrap();
        db.permissions().resolve("p1", "allow_once").await.unwrap();
        assert!(matches!(
            db.permissions().resolve("p1", "allow_once").await,
            Err(PersistError::PermissionNotFound(_))
        ));
    }
}
