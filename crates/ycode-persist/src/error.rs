use thiserror::Error;

#[derive(Error, Debug)]
pub enum PersistError {
    #[error("connection: {0}")]
    Connection(String),

    #[error("migration: {0}")]
    Migration(String),

    #[error("sqlx: {0}")]
    Sqlx(#[from] sqlx::Error),

    #[error("session not found: {0}")]
    SessionNotFound(String),

    #[error("project not found: {0}")]
    ProjectNotFound(String),

    #[error("project `{0}` still has {1} live session(s)")]
    ProjectNotEmpty(String, i64),
}
