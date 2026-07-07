-- Correct the isolation flag that an early build of 0010 backfilled ON.
--
-- Background: the first released 0010 shipped with
-- `isolate_sessions INTEGER NOT NULL DEFAULT 1`. Because 0010's ADD COLUMN
-- backfills every pre-existing project, anyone who installed that build had
-- ALL their existing projects silently switched to worktree isolation —
-- contrary to the "isolation is opt-in, default OFF" decision (see 49be01b /
-- af33502).
--
-- 0010 is released and therefore immutable: editing it (as af33502 did) breaks
-- every already-migrated DB with a sqlx "migration was modified" checksum
-- mismatch. So 0010 is restored byte-for-byte and the correction lives here.
--
-- We reset isolation only for projects that never actually ran an isolated
-- session (no session carries a worktree_path). Projects with live/historical
-- worktrees are left ON so isolation isn't yanked out from under anyone who is
-- genuinely using it; they can still toggle it off in the UI.
--
-- We deliberately do NOT rebuild `projects` to flip the column DEFAULT to 0:
-- ProjectRepo::create always binds isolate_sessions explicitly, so the column
-- default is never consulted for new rows, and a fresh DB backfills zero rows.
-- Rebuilding the table (FKs, indexes) would add risk for no behavioral gain.

UPDATE projects
SET isolate_sessions = 0
WHERE id NOT IN (
    SELECT project_id FROM sessions
    WHERE worktree_path IS NOT NULL AND project_id IS NOT NULL
);
