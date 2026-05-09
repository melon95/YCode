//! Shell-out wrappers around `git worktree`.
//!
//! Encapsulated here so that when gitoxide gains full worktree support we can
//! swap the implementation without touching callers. All commands run with
//! the parent repo as `cwd`.

use camino::Utf8Path;
use std::process::Command;

use crate::WorktreeError;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CleanupMode {
    /// Default: remove the worktree directory but leave the branch intact so
    /// the user can `git merge` it later.
    KeepBranch,
    /// Remove the worktree directory AND delete the branch. Destructive.
    DeleteBranch,
}

pub fn worktree_add(
    repo_root: &Utf8Path,
    worktree_path: &Utf8Path,
    branch: &str,
    base_ref: &str,
) -> Result<(), WorktreeError> {
    run_git(
        repo_root,
        &[
            "worktree",
            "add",
            "-b",
            branch,
            worktree_path.as_str(),
            base_ref,
        ],
    )
}

pub fn worktree_remove(repo_root: &Utf8Path, worktree_path: &Utf8Path) -> Result<(), WorktreeError> {
    run_git(
        repo_root,
        &["worktree", "remove", "--force", worktree_path.as_str()],
    )
}

pub fn branch_delete(repo_root: &Utf8Path, branch: &str) -> Result<(), WorktreeError> {
    run_git(repo_root, &["branch", "-D", branch])
}

fn run_git(cwd: &Utf8Path, args: &[&str]) -> Result<(), WorktreeError> {
    let output = Command::new("git")
        .args(args)
        .current_dir(cwd.as_std_path())
        .output()
        .map_err(WorktreeError::Io)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(WorktreeError::GitFailed {
            status: output.status.code(),
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }
}
