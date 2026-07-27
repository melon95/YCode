-- Durable git snapshots captured before a session starts and after each
-- completed agent turn. The commit objects themselves live in the project's
-- git object database; this table owns ordering and user-facing metadata.

CREATE TABLE session_checkpoints (
    id            TEXT PRIMARY KEY,
    session_id    TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    project_id    TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    sequence      INTEGER NOT NULL,
    commit_sha    TEXT NOT NULL,
    ref_name      TEXT NOT NULL UNIQUE,
    kind          TEXT NOT NULL CHECK (kind IN ('initial', 'turn')),
    source        TEXT,
    event_kind    TEXT,
    body_preview  TEXT,
    created_at    INTEGER NOT NULL,
    UNIQUE (session_id, sequence)
);

CREATE INDEX idx_session_checkpoints_project_created
    ON session_checkpoints(project_id, created_at DESC);
CREATE INDEX idx_session_checkpoints_session_sequence
    ON session_checkpoints(session_id, sequence DESC);
