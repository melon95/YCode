//! Git worktree manager — one isolated worktree per session.
//!
//! Detection uses `gix`. Worktree creation/removal shells out to `git`
//! because gitoxide's worktree commands are still incomplete in 0.x. The
//! shell-out lives in `ops.rs` behind a single function so we can swap to
//! native gix later without touching callers.
//!
//! ## Lifecycle and the dirty-parent footgun
//!
//! Each session gets a fresh worktree branched from the parent repo's current
//! `HEAD`. We deliberately do NOT carry uncommitted changes from the parent —
//! the caller is expected to surface a UI warning at session-create time.
//! Sculptor finesses dirty state through containers; we rejected that
//! complexity for MVP, so we own the footgun explicitly.

mod ops;
mod repo;

pub use ops::CleanupMode;
pub use repo::RepoInfo;

use camino::{Utf8Path, Utf8PathBuf};
use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Filesystem layout: `<root>/<repo-name>-<short-hash>/<session-id>/`.
///
/// The intermediate `<repo-name>-<short-hash>` directory disambiguates two
/// repos with the same basename (`work/api` vs `personal/api`).
pub struct WorktreeManager {
    root: Utf8PathBuf,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Worktree {
    pub session_id: String,
    pub repo_root: Utf8PathBuf,
    pub worktree_path: Utf8PathBuf,
    pub branch: String,
    /// Commit SHA the worktree was branched from.
    pub base_ref: String,
}

#[derive(Error, Debug)]
pub enum WorktreeError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),

    #[error("path is not valid UTF-8: {0}")]
    NonUtf8Path(String),

    #[error("not a git repository: {0}")]
    NotAGitRepo(String),

    #[error("submodule and bare repos are not supported by ycode (path: {0})")]
    UnsupportedRepoKind(String),

    #[error("git command failed (status {status:?}): {stderr}")]
    GitFailed { status: Option<i32>, stderr: String },

    #[error("gix: {0}")]
    Gix(String),
}

impl WorktreeManager {
    pub fn new(root: impl Into<Utf8PathBuf>) -> Self {
        Self { root: root.into() }
    }

    pub fn root(&self) -> &Utf8Path {
        &self.root
    }

    /// Walk up from `path` to find a git repository. Rejects bare repos and
    /// any path that's inside a submodule's `.git` directory.
    pub fn detect_repo(&self, path: &Utf8Path) -> Result<RepoInfo, WorktreeError> {
        repo::detect(path)
    }

    /// Create a fresh worktree for a session. The branch is named
    /// `ycode/<session-id-short>`. `session_id` is expected to be a ULID; we
    /// take the leading 10 characters for the branch name.
    pub fn create_for_session(
        &self,
        repo: &RepoInfo,
        session_id: &str,
    ) -> Result<Worktree, WorktreeError> {
        let short = session_id.get(0..10).unwrap_or(session_id);
        let branch = format!("ycode/{short}");
        let parent_dir = self.root.join(repo.scoped_dirname());
        std::fs::create_dir_all(&parent_dir)?;
        let wt_path = parent_dir.join(session_id);

        ops::worktree_add(&repo.root, &wt_path, &branch, &repo.head_sha)?;

        Ok(Worktree {
            session_id: session_id.into(),
            repo_root: repo.root.clone(),
            worktree_path: wt_path,
            branch,
            base_ref: repo.head_sha.clone(),
        })
    }

    /// Tear a worktree down. With `CleanupMode::DeleteBranch` also removes the
    /// branch — opt-in because the user often wants to merge the branch back.
    pub fn cleanup(&self, wt: &Worktree, mode: CleanupMode) -> Result<(), WorktreeError> {
        ops::worktree_remove(&wt.repo_root, &wt.worktree_path)?;
        if mode == CleanupMode::DeleteBranch {
            ops::branch_delete(&wt.repo_root, &wt.branch)?;
        }
        Ok(())
    }

    /// Worktree directories under `<root>/<repo-name>-<hash>/` that don't
    /// match a session row. The orchestrator calls this on startup; it returns
    /// the orphans and lets the caller decide what to do (we just log).
    pub fn list_orphans(
        &self,
        repo: &RepoInfo,
        known_session_ids: &[String],
    ) -> Result<Vec<Utf8PathBuf>, WorktreeError> {
        let scoped = self.root.join(repo.scoped_dirname());
        if !scoped.as_std_path().exists() {
            return Ok(Vec::new());
        }
        let mut orphans = Vec::new();
        for entry in std::fs::read_dir(scoped.as_std_path())? {
            let entry = entry?;
            let path = entry.path();
            if !path.is_dir() {
                continue;
            }
            let name = match path.file_name().and_then(|s| s.to_str()) {
                Some(s) => s.to_string(),
                None => continue,
            };
            if !known_session_ids.iter().any(|id| id == &name) {
                let path = Utf8PathBuf::from_path_buf(path)
                    .map_err(|p| WorktreeError::NonUtf8Path(p.display().to_string()))?;
                orphans.push(path);
            }
        }
        Ok(orphans)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// Initialise a git repo with one commit. Returns the repo path.
    fn init_repo(dir: &Utf8Path) -> Utf8PathBuf {
        std::fs::create_dir_all(dir).unwrap();
        run_git(dir, &["init", "-b", "main"]);
        run_git(dir, &["config", "user.email", "test@example.com"]);
        run_git(dir, &["config", "user.name", "ycode-test"]);
        run_git(dir, &["config", "commit.gpgsign", "false"]);
        std::fs::write(dir.join("README.md"), "hello").unwrap();
        run_git(dir, &["add", "."]);
        run_git(dir, &["commit", "-m", "initial"]);
        dir.to_path_buf()
    }

    fn run_git(cwd: &Utf8Path, args: &[&str]) {
        let out = Command::new("git").args(args).current_dir(cwd).output().unwrap();
        assert!(
            out.status.success(),
            "git {args:?} failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
    }

    fn tempdir_utf8() -> (tempfile::TempDir, Utf8PathBuf) {
        let td = tempfile::tempdir().unwrap();
        let p = Utf8PathBuf::from_path_buf(td.path().to_path_buf()).unwrap();
        (td, p)
    }

    #[test]
    fn detect_repo_succeeds_for_real_repo() {
        let (_keep, dir) = tempdir_utf8();
        let repo_dir = dir.join("repo");
        init_repo(&repo_dir);

        let mgr = WorktreeManager::new(dir.join("worktrees"));
        let info = mgr.detect_repo(&repo_dir).unwrap();
        assert_eq!(info.root, repo_dir);
        assert!(!info.head_sha.is_empty());
    }

    #[test]
    fn detect_repo_walks_up_from_subdir() {
        let (_keep, dir) = tempdir_utf8();
        let repo_dir = dir.join("repo");
        init_repo(&repo_dir);
        let sub = repo_dir.join("a/b/c");
        std::fs::create_dir_all(&sub).unwrap();

        let mgr = WorktreeManager::new(dir.join("worktrees"));
        let info = mgr.detect_repo(&sub).unwrap();
        assert_eq!(info.root, repo_dir);
    }

    #[test]
    fn detect_repo_fails_outside_any_repo() {
        let (_keep, dir) = tempdir_utf8();
        let mgr = WorktreeManager::new(dir.join("worktrees"));
        let err = mgr.detect_repo(&dir).unwrap_err();
        assert!(matches!(err, WorktreeError::NotAGitRepo(_)));
    }

    #[test]
    fn create_and_cleanup_worktree() {
        let (_keep, dir) = tempdir_utf8();
        let repo_dir = dir.join("repo");
        init_repo(&repo_dir);

        let mgr = WorktreeManager::new(dir.join("worktrees"));
        let info = mgr.detect_repo(&repo_dir).unwrap();

        let wt = mgr.create_for_session(&info, "01HZA12345BCDEFGHIJK").unwrap();
        assert!(wt.worktree_path.as_std_path().exists());
        assert!(wt.worktree_path.join("README.md").as_std_path().exists());
        assert_eq!(wt.branch, "ycode/01HZA12345");

        mgr.cleanup(&wt, CleanupMode::KeepBranch).unwrap();
        assert!(!wt.worktree_path.as_std_path().exists());
        // Branch should still exist (KeepBranch).
        let out = Command::new("git")
            .args(["branch", "--list", &wt.branch])
            .current_dir(&repo_dir)
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&out.stdout);
        assert!(stdout.contains(&wt.branch), "expected branch kept: {stdout}");
    }

    #[test]
    fn list_orphans_finds_unknown_session_dirs() {
        let (_keep, dir) = tempdir_utf8();
        let repo_dir = dir.join("repo");
        init_repo(&repo_dir);

        let mgr = WorktreeManager::new(dir.join("worktrees"));
        let info = mgr.detect_repo(&repo_dir).unwrap();
        let wt = mgr.create_for_session(&info, "01HZAAAAAA0000000000").unwrap();

        // Pretend the DB only knows about a different session.
        let orphans = mgr.list_orphans(&info, &["other-session".into()]).unwrap();
        assert_eq!(orphans.len(), 1);
        assert_eq!(orphans[0], wt.worktree_path);

        // Now the DB knows about it.
        let orphans2 = mgr
            .list_orphans(&info, &["01HZAAAAAA0000000000".into()])
            .unwrap();
        assert!(orphans2.is_empty());

        let _ = mgr.cleanup(&wt, CleanupMode::KeepBranch);
    }
}
