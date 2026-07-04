use thiserror::Error;

#[derive(Error, Debug)]
pub enum LspError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("http: {0}")]
    Http(#[from] reqwest::Error),

    #[error("json: {0}")]
    Json(#[from] serde_json::Error),

    #[error("persist: {0}")]
    Persist(#[from] ycode_persist::PersistError),

    #[error("unknown server id: {0}")]
    UnknownServer(String),

    #[error("no asset matches the current platform for {0}")]
    NoMatchingAsset(String),

    #[error("github release lookup failed: {0}")]
    GithubRelease(String),

    #[error("install command `{0}` failed: {1}")]
    InstallCommand(String, String),

    #[error("missing tool `{0}` — install it and retry")]
    MissingTool(String),

    #[error("archive extraction failed: {0}")]
    Extract(String),

    #[error("could not determine ycode data dir")]
    NoDataDir,
}
