//! SQLite persistence layer.
//!
//! Two tables: `projects`, `sessions`. Schema in `migrations/`. Migrations
//! run automatically via [`Db::open`].
//!
//! Connection string conventions:
//! - Production: `sqlite://<data_dir>/ycode.db`
//! - Tests: `sqlite::memory:`

mod error;
pub mod lsp_repo;
mod models;
pub mod project_repo;
pub mod session_repo;
pub mod todo_repo;

pub use error::PersistError;
pub use lsp_repo::{LspInstallationRepo, LspInstallationRow, NewLspInstallation};
pub use models::{ProjectRow, SessionRow, TodoRow};
pub use project_repo::{NewProject, ProjectRepo};
pub use session_repo::{NewSession, SessionRepo};
pub use todo_repo::{NewTodo, TodoRepo, TODO_STATUSES};

use sqlx::sqlite::{SqliteConnectOptions, SqlitePoolOptions};
use sqlx::SqlitePool;
use std::str::FromStr;

/// Opaque handle on the open SQLite pool. Clone freely; it's an `Arc` inside.
#[derive(Clone)]
pub struct Db {
    pool: SqlitePool,
}

impl Db {
    /// Open (and migrate) the database at the given URL.
    pub async fn open(url: &str) -> Result<Self, PersistError> {
        // WAL + busy_timeout: lets readers proceed while a single writer is
        // active and makes contended writes retry rather than fail with
        // SQLITE_BUSY. `:memory:` ignores WAL but the pragma is harmless.
        let opts = SqliteConnectOptions::from_str(url)
            .map_err(|e| PersistError::Connection(e.to_string()))?
            .create_if_missing(true)
            .foreign_keys(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .busy_timeout(std::time::Duration::from_secs(5));

        // For in-memory databases each connection gets a fresh empty DB —
        // collapse the pool to a single connection so the schema persists.
        let max = if url.contains(":memory:") { 1 } else { 8 };
        let pool = SqlitePoolOptions::new()
            .max_connections(max)
            .connect_with(opts)
            .await
            .map_err(|e| PersistError::Connection(e.to_string()))?;

        sqlx::migrate!("./migrations")
            .run(&pool)
            .await
            .map_err(|e| PersistError::Migration(e.to_string()))?;

        Ok(Self { pool })
    }

    pub async fn open_in_memory() -> Result<Self, PersistError> {
        Self::open("sqlite::memory:").await
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn sessions(&self) -> SessionRepo<'_> {
        SessionRepo::new(&self.pool)
    }

    pub fn projects(&self) -> ProjectRepo<'_> {
        ProjectRepo::new(&self.pool)
    }

    pub fn todos(&self) -> TodoRepo<'_> {
        TodoRepo::new(&self.pool)
    }

    pub fn lsp_installations(&self) -> LspInstallationRepo<'_> {
        LspInstallationRepo::new(&self.pool)
    }
}

/// Current unix milliseconds.
pub fn now_ms() -> i64 {
    time::OffsetDateTime::now_utc().unix_timestamp() * 1000
        + (time::OffsetDateTime::now_utc().millisecond() as i64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn open_and_migrate_in_memory() {
        let db = Db::open_in_memory().await.unwrap();
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(count, 0);
    }
}
