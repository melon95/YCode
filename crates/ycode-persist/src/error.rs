use thiserror::Error;

#[derive(Error, Debug)]
pub enum PersistError {
    #[error("connection: {0}")]
    Connection(String),

    #[error("migration: {0}")]
    Migration(String),

    #[error("sqlx: {0}")]
    Sqlx(#[from] sqlx::Error),

    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    #[error("session not found: {0}")]
    SessionNotFound(String),

    #[error("permission not found: {0}")]
    PermissionNotFound(String),
}
