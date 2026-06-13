//! LSP installation tracking. Mirrors the on-disk install state so the
//! Settings UI doesn't have to stat directories to decide install/uninstall.

use crate::{now_ms, PersistError};
use serde::{Deserialize, Serialize};
use sqlx::SqlitePool;

#[derive(Clone, Debug, Serialize, Deserialize, sqlx::FromRow)]
pub struct LspInstallationRow {
    pub id: String,
    pub version: String,
    pub binary_path: String,
    pub installed_at: i64,
}

#[derive(Clone, Debug)]
pub struct NewLspInstallation {
    pub id: String,
    pub version: String,
    pub binary_path: String,
}

pub struct LspInstallationRepo<'a> {
    pool: &'a SqlitePool,
}

impl<'a> LspInstallationRepo<'a> {
    pub fn new(pool: &'a SqlitePool) -> Self {
        Self { pool }
    }

    /// Insert-or-replace. Re-installing the same server overwrites the prior
    /// row — installer always finishes with a clean dir, so the previous
    /// version label is no longer meaningful.
    pub async fn upsert(&self, new: NewLspInstallation) -> Result<LspInstallationRow, PersistError> {
        let row = LspInstallationRow {
            id: new.id,
            version: new.version,
            binary_path: new.binary_path,
            installed_at: now_ms(),
        };
        sqlx::query(
            "INSERT INTO lsp_installations (id, version, binary_path, installed_at) \
             VALUES (?, ?, ?, ?) \
             ON CONFLICT(id) DO UPDATE SET \
                version = excluded.version, \
                binary_path = excluded.binary_path, \
                installed_at = excluded.installed_at",
        )
        .bind(&row.id)
        .bind(&row.version)
        .bind(&row.binary_path)
        .bind(row.installed_at)
        .execute(self.pool)
        .await?;
        Ok(row)
    }

    pub async fn list(&self) -> Result<Vec<LspInstallationRow>, PersistError> {
        Ok(sqlx::query_as::<_, LspInstallationRow>(
            "SELECT * FROM lsp_installations ORDER BY installed_at DESC",
        )
        .fetch_all(self.pool)
        .await?)
    }

    pub async fn get(&self, id: &str) -> Result<Option<LspInstallationRow>, PersistError> {
        Ok(
            sqlx::query_as::<_, LspInstallationRow>("SELECT * FROM lsp_installations WHERE id = ?")
                .bind(id)
                .fetch_optional(self.pool)
                .await?,
        )
    }

    pub async fn delete(&self, id: &str) -> Result<(), PersistError> {
        sqlx::query("DELETE FROM lsp_installations WHERE id = ?")
            .bind(id)
            .execute(self.pool)
            .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Db;

    #[tokio::test]
    async fn upsert_and_list() {
        let db = Db::open_in_memory().await.unwrap();
        let repo = db.lsp_installations();

        let inserted = repo
            .upsert(NewLspInstallation {
                id: "rust-analyzer".into(),
                version: "2024-08-01".into(),
                binary_path: "/tmp/rust-analyzer".into(),
            })
            .await
            .unwrap();
        assert_eq!(inserted.version, "2024-08-01");

        // Re-install bumps version in place.
        repo.upsert(NewLspInstallation {
            id: "rust-analyzer".into(),
            version: "2024-09-01".into(),
            binary_path: "/tmp/rust-analyzer".into(),
        })
        .await
        .unwrap();

        let all = repo.list().await.unwrap();
        assert_eq!(all.len(), 1);
        assert_eq!(all[0].version, "2024-09-01");

        repo.delete("rust-analyzer").await.unwrap();
        assert!(repo.list().await.unwrap().is_empty());
    }
}
