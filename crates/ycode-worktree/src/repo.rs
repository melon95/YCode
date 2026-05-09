//! Repo detection via gix.

use camino::{Utf8Path, Utf8PathBuf};
use serde::{Deserialize, Serialize};
use std::process::Command;

use crate::WorktreeError;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RepoInfo {
    /// The repository's working tree root (NOT the `.git` directory).
    pub root: Utf8PathBuf,
    /// `HEAD` commit SHA. The new worktree branches from this.
    pub head_sha: String,
    /// `true` if `git status` would report dirty. The orchestrator surfaces a
    /// warning at session-create time; we still create the worktree from
    /// `HEAD` (uncommitted changes are NOT carried forward).
    pub is_dirty: bool,
}

impl RepoInfo {
    /// Stable directory name combining the repo's basename with a short hash
    /// of its absolute path. Used by [`WorktreeManager`] to disambiguate two
    /// repos with the same basename.
    pub fn scoped_dirname(&self) -> String {
        let base = self
            .root
            .file_name()
            .unwrap_or("repo")
            .replace(['/', '\\'], "-");
        let mut h: u64 = 0xcbf29ce484222325; // FNV-1a
        for byte in self.root.as_str().bytes() {
            h ^= byte as u64;
            h = h.wrapping_mul(0x100000001b3);
        }
        format!("{base}-{:08x}", (h >> 32) as u32)
    }
}

pub fn detect(path: &Utf8Path) -> Result<RepoInfo, WorktreeError> {
    let repo = gix::discover(path.as_std_path())
        .map_err(|e| WorktreeError::NotAGitRepo(format!("{path}: {e}")))?;

    if repo.kind() == gix::repository::Kind::Bare {
        return Err(WorktreeError::UnsupportedRepoKind(format!(
            "{path} (bare repo)"
        )));
    }

    let work_dir = repo
        .work_dir()
        .ok_or_else(|| WorktreeError::UnsupportedRepoKind(format!("{path} (no work tree)")))?;
    let work_dir = Utf8PathBuf::from_path_buf(work_dir.to_path_buf())
        .map_err(|p| WorktreeError::NonUtf8Path(p.display().to_string()))?;

    let head_sha = repo
        .head_commit()
        .map_err(|e| WorktreeError::Gix(e.to_string()))?
        .id
        .to_string();

    // Best-effort dirty probe via `git status --porcelain`. Untracked files
    // are ignored — plenty of repos have build artifacts the user hasn't
    // gitignored, and surfacing those as "dirty" would generate false alarms.
    let is_dirty = probe_dirty(&work_dir).unwrap_or(false);

    Ok(RepoInfo {
        root: work_dir,
        head_sha,
        is_dirty,
    })
}

fn probe_dirty(work_dir: &Utf8Path) -> Option<bool> {
    let out = Command::new("git")
        .args(["status", "--porcelain", "--untracked-files=no"])
        .current_dir(work_dir.as_std_path())
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    Some(!out.stdout.is_empty())
}
