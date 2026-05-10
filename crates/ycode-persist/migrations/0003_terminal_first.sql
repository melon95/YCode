-- Terminal-first schema cleanup.
--
-- Under the new architecture sessions are just a (project, command) pair —
-- there is no worktree, no ACP state machine, no structured event log, and
-- no permission broker.
--
-- This migration:
--   • Rebuilds `sessions` without `repo_root` / `worktree_path` / `branch` /
--     `base_ref` / `state`, replacing the JSON state field with a single
--     nullable `last_exit_code`. Live runtime status (Running vs Exited)
--     lives in the in-memory TerminalManager.
--   • Drops the `events` and `permissions` tables — xterm.js' scrollback is
--     the transcript, and there is no permission protocol to record.
--
-- Pre-0002 rows lacking a project_id are dropped (they're from the original
-- adapter prototype and were never user-visible). The migration is destructive
-- on those rows by design.

CREATE TABLE sessions_new (
    id              TEXT PRIMARY KEY,
    title           TEXT NOT NULL,
    agent_profile   TEXT NOT NULL,
    project_id      TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    last_exit_code  INTEGER,
    created_at      INTEGER NOT NULL,
    updated_at      INTEGER NOT NULL,
    archived_at     INTEGER
);

INSERT INTO sessions_new (id, title, agent_profile, project_id, last_exit_code, created_at, updated_at, archived_at)
SELECT id, title, agent_profile, project_id, NULL, created_at, updated_at, archived_at
FROM sessions
WHERE project_id IS NOT NULL;

DROP TABLE permissions;
DROP TABLE events;
DROP TABLE sessions;
ALTER TABLE sessions_new RENAME TO sessions;

CREATE INDEX idx_sessions_archived ON sessions(archived_at);
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);
CREATE INDEX idx_sessions_project ON sessions(project_id);
