-- Per-session git worktree isolation.
--
-- Restores (in a leaner form) the worktree columns that 0001 had and 0003
-- removed. When a project opts into isolation, each session runs in its own
-- `git worktree` on a dedicated branch instead of sharing the project's main
-- working tree. All three session columns are NULL for shared-mode sessions.
--
--   • worktree_path — absolute path of the session's checked-out worktree
--   • branch        — the session's dedicated branch (ycode/<short-id>)
--   • base_branch   — the branch it was forked from, used to merge back
--
-- `projects.isolate_sessions` is the per-project switch, defaulting to OFF:
-- isolation is opt-in, so neither existing projects (backfilled by this ADD
-- COLUMN) nor freshly created ones get worktrees until the user turns it on.
-- `ProjectRepo::create` also writes the value explicitly, so the code-side
-- default and this column default agree.

ALTER TABLE sessions ADD COLUMN worktree_path TEXT;
ALTER TABLE sessions ADD COLUMN branch TEXT;
ALTER TABLE sessions ADD COLUMN base_branch TEXT;

ALTER TABLE projects ADD COLUMN isolate_sessions INTEGER NOT NULL DEFAULT 0;
