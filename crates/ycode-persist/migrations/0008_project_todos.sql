-- Per-project todo list.
--
-- A todo belongs to exactly one project and carries a workflow status
-- (`todo` / `doing` / `done`). Deleting a project cascades to its todos.
-- `sort_order` keeps a stable manual ordering within a project; new rows
-- get max+1 so they append to the bottom of the list.

CREATE TABLE project_todos (
    id          TEXT PRIMARY KEY,             -- ULID
    project_id  TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
    title       TEXT NOT NULL,
    status      TEXT NOT NULL DEFAULT 'todo', -- 'todo' | 'doing' | 'done'
    sort_order  INTEGER NOT NULL DEFAULT 0,   -- manual order within a project
    created_at  INTEGER NOT NULL,             -- unix ms
    updated_at  INTEGER NOT NULL              -- unix ms
);

CREATE INDEX idx_project_todos_project ON project_todos(project_id);
