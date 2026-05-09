-- ycode initial schema.
-- See plan: /Users/melon/.claude/plans/sleepy-roaming-graham.md (§ State Machine 与持久化)

PRAGMA foreign_keys = ON;

CREATE TABLE sessions (
    id              TEXT PRIMARY KEY,           -- ULID
    title           TEXT NOT NULL,
    agent_profile   TEXT NOT NULL,              -- e.g. "claude-code"
    repo_root       TEXT NOT NULL,              -- canonical path of parent repo
    worktree_path   TEXT NOT NULL,              -- resolved isolated worktree
    branch          TEXT NOT NULL,              -- ycode/<short-id>
    base_ref        TEXT NOT NULL,              -- commit SHA worktree branched from
    state           TEXT NOT NULL,              -- json-encoded SessionState
    created_at      INTEGER NOT NULL,           -- unix ms
    updated_at      INTEGER NOT NULL,
    archived_at     INTEGER                     -- null while live
);

CREATE INDEX idx_sessions_archived ON sessions(archived_at);
CREATE INDEX idx_sessions_updated ON sessions(updated_at DESC);

-- Per-session ordered transcript. RawOutput payloads MUST be truncated to
-- 64 KiB by the writer (the persist layer enforces this).
CREATE TABLE events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    seq             INTEGER NOT NULL,           -- monotonic, gapless, starts at 0
    ts              INTEGER NOT NULL,           -- unix ms
    payload         TEXT NOT NULL,              -- json AgentEvent
    UNIQUE(session_id, seq)
);

CREATE INDEX idx_events_session_seq ON events(session_id, seq);

-- Outstanding and resolved permission requests. We persist these so that a
-- crash mid-permission doesn't strand the session — on restart, unresolved
-- permissions are surfaced again to the UI.
CREATE TABLE permissions (
    request_id      TEXT PRIMARY KEY,
    session_id      TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    tool_name       TEXT NOT NULL,
    summary         TEXT NOT NULL,
    options_json    TEXT NOT NULL,              -- json array of PermissionOption
    decided_option  TEXT,                       -- null until resolved
    decided_at      INTEGER,
    created_at      INTEGER NOT NULL
);

CREATE INDEX idx_permissions_session ON permissions(session_id);
CREATE INDEX idx_permissions_open ON permissions(session_id) WHERE decided_at IS NULL;
