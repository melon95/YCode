//! Filesystem layout for installed LSPs.
//!
//! All servers live under `<data_dir>/lsp/<server_id>/`. The data dir is the
//! same one used by the rest of ycode (sqlite db, etc.) via `directories`.

use camino::Utf8PathBuf;
use directories::ProjectDirs;

use crate::LspError;

pub fn data_root() -> Result<Utf8PathBuf, LspError> {
    let dirs = ProjectDirs::from("dev", "ycode", "ycode").ok_or(LspError::NoDataDir)?;
    let path = dirs.data_dir().to_path_buf();
    Utf8PathBuf::from_path_buf(path).map_err(|_| LspError::NoDataDir)
}

pub fn lsp_root() -> Result<Utf8PathBuf, LspError> {
    Ok(data_root()?.join("lsp"))
}

/// Per-server install directory.
pub fn server_root(server_id: &str) -> Result<Utf8PathBuf, LspError> {
    Ok(lsp_root()?.join(server_id))
}
