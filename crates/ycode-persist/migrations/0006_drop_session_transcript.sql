-- Drop the PTY transcript table.
--
-- Per the AgentDeck plan §6.1 / §8.3 the agent jsonl files (~/.claude/projects
-- and ~/.codex/sessions) are the source of truth for historical conversation
-- content. We no longer copy-store PTY bytes — historical browsing happens
-- through the introspect module that seeks the original jsonl by byte offset.
DROP TABLE IF EXISTS session_transcript_chunks;
