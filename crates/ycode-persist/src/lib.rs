//! SQLite persistence layer.
//!
//! Three tables: `sessions`, `events`, `permissions`. Schema in
//! `migrations/0001_init.sql`. The repos in this crate translate between
//! domain types from `ycode-adapter` (`SessionState`, `AgentEvent`) and rows.
//!
//! Connection string conventions:
//! - Production: `sqlite://<data_dir>/ycode.db`
//! - Tests: `sqlite::memory:`
//!
//! Migrations run automatically via [`Db::open`].

mod error;
mod event_repo;
mod models;
pub mod permission_repo;
pub mod session_repo;

pub use error::PersistError;
pub use event_repo::EventRepo;
pub use models::{EventRow, PermissionRow, SessionRow};
pub use permission_repo::{NewPermission, PermissionRepo};
pub use session_repo::{NewSession, SessionRepo};

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
    ///
    /// `sqlite:` URLs that point at a file path will create the file if it
    /// doesn't exist. `sqlite::memory:` is supported for tests.
    pub async fn open(url: &str) -> Result<Self, PersistError> {
        // Concurrency tuning: WAL journal lets readers proceed while a single
        // writer is active; busy_timeout makes contended writes retry rather
        // than fail with SQLITE_BUSY. Without these, parallel sessions
        // (S4-style) deadlock on insert. `:memory:` databases ignore the WAL
        // pragma so we set them unconditionally.
        let opts = SqliteConnectOptions::from_str(url)
            .map_err(|e| PersistError::Connection(e.to_string()))?
            .create_if_missing(true)
            .foreign_keys(true)
            .journal_mode(sqlx::sqlite::SqliteJournalMode::Wal)
            .busy_timeout(std::time::Duration::from_secs(5));

        // For in-memory databases the same `:memory:` URL maps to a separate
        // database per connection — every connection gets a fresh empty DB
        // and migrations have to re-run. `max_connections(1)` collapses the
        // pool onto a single shared connection so the schema persists.
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

    /// Open an in-memory database for tests. Migrations applied.
    pub async fn open_in_memory() -> Result<Self, PersistError> {
        Self::open("sqlite::memory:").await
    }

    pub fn pool(&self) -> &SqlitePool {
        &self.pool
    }

    pub fn sessions(&self) -> SessionRepo<'_> {
        SessionRepo::new(&self.pool)
    }

    pub fn events(&self) -> EventRepo<'_> {
        EventRepo::new(&self.pool)
    }

    pub fn permissions(&self) -> PermissionRepo<'_> {
        PermissionRepo::new(&self.pool)
    }
}

/// Helper: current unix milliseconds. Centralised so tests can mock by
/// substituting at the call site.
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
        // After migrate, the three tables exist; selecting from them returns 0 rows.
        let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM sessions")
            .fetch_one(db.pool())
            .await
            .unwrap();
        assert_eq!(count, 0);
    }
}
