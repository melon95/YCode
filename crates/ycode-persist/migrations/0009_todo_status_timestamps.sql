-- Per-status timestamps for todos.
--
-- `started_at` records when a todo most recently entered the `doing` status;
-- `done_at` records when it most recently entered `done`. Both are NULL until
-- the todo first reaches that status. They're written on transition *into* the
-- state (see TodoRepo::update) and not cleared on the way out, so they read as
-- "last started / last completed".

ALTER TABLE project_todos ADD COLUMN started_at INTEGER;
ALTER TABLE project_todos ADD COLUMN done_at INTEGER;

-- Best-effort backfill for rows that already exist: we don't have the real
-- transition times, so approximate with `updated_at` (the last time the row
-- changed, which for a done/doing row is most likely the status flip).
UPDATE project_todos SET done_at = updated_at WHERE status = 'done';
UPDATE project_todos SET started_at = updated_at
  WHERE status IN ('doing', 'done') AND started_at IS NULL;
