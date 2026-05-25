-- Agent-native resume metadata.
--
-- `agent_session_id` is an exact CLI conversation id when we can control or
-- discover it. `agent_thread_name` is the CLI-emitted title/thread label and
-- is useful for CLIs such as Codex that can resume by thread name.

ALTER TABLE sessions ADD COLUMN agent_session_id TEXT;
ALTER TABLE sessions ADD COLUMN agent_thread_name TEXT;
