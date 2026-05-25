-- Durable terminal transcript chunks.
--
-- Sessions are PTY-first: the authoritative UI surface is the terminal stream.
-- Persist the rendered byte stream so switching back to an old session, or
-- restarting the app, can replay the context before any new live output.

CREATE TABLE session_transcript_chunks (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id  TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    seq         INTEGER NOT NULL,
    ts          INTEGER NOT NULL,
    kind        TEXT NOT NULL CHECK (kind IN ('output', 'exit')),
    data        BLOB NOT NULL,
    UNIQUE(session_id, seq)
);

CREATE INDEX idx_session_transcript_session_seq
    ON session_transcript_chunks(session_id, seq);
