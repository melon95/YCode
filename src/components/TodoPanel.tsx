// Per-project todo list. Single-column list: each row has a clickable status
// box that cycles todo → doing → done, a status tag (TODO / DOING) for the
// in-progress states, and the title (struck through + muted when done).
// Double-click a title to rename; hover to reveal a delete button. A trailing
// input row appends new todos. Data is fetched on mount and refreshed live via
// the `TodosChanged` event (which also fires for MCP-driven changes made by an
// AI agent) — see App.tsx.

import { useEffect, useRef, useState } from "react";
import { createTodo, deleteTodo, listTodos, updateTodo } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { TodoView } from "../lib/types";

type Status = "todo" | "doing" | "done";

const NEXT_STATUS: Record<Status, Status> = {
  todo: "doing",
  doing: "done",
  done: "todo",
};

export function TodoPanel({ projectId }: { projectId: string }) {
  const todos = useStore((s) => s.todos[projectId]);
  const setTodos = useStore((s) => s.setTodos);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingText, setEditingText] = useState("");

  const refresh = () => {
    listTodos(projectId)
      .then((list) => setTodos(projectId, list))
      .catch((e) => setError(String(e)));
  };

  // Fetch on mount / project switch. Subsequent updates arrive via the
  // TodosChanged event handled in App.tsx, but we also refresh after our own
  // mutations below in case the event bus lags.
  useEffect(() => {
    refresh();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [projectId]);

  const cycleStatus = (todo: TodoView) => {
    const next = NEXT_STATUS[(todo.status as Status) ?? "todo"];
    updateTodo(todo.id, { status: next })
      .then(refresh)
      .catch((e) => setError(String(e)));
  };

  // Pending single-click timer, used to disambiguate a row click (advance
  // status) from a double-click on the title (edit). A double-click clears it
  // before it fires.
  const clickTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (clickTimer.current) clearTimeout(clickTimer.current);
  }, []);

  // Click anywhere on a todo/doing row to advance its status
  // (todo → doing → done). Done rows aren't advanced by a row click — use the
  // checkbox to reopen them.
  const handleRowClick = (todo: TodoView) => {
    const status = (todo.status as Status) ?? "todo";
    if (status === "done") return;
    if (editingId === todo.id) return;
    if (clickTimer.current) clearTimeout(clickTimer.current);
    clickTimer.current = setTimeout(() => {
      clickTimer.current = null;
      cycleStatus(todo);
    }, 200);
  };

  const beginEdit = (todo: TodoView) => {
    if (clickTimer.current) {
      clearTimeout(clickTimer.current);
      clickTimer.current = null;
    }
    setEditingId(todo.id);
    setEditingText(todo.title);
  };

  const addTodo = () => {
    const title = draft.trim();
    if (!title) return;
    // Clear the draft only after a successful create so a failed IPC doesn't
    // throw away what the user typed.
    createTodo(projectId, title)
      .then(() => {
        setDraft("");
        refresh();
      })
      .catch((e) => setError(String(e)));
  };

  const commitEdit = () => {
    if (editingId === null) return;
    const id = editingId;
    const title = editingText.trim();
    setEditingId(null);
    if (!title) return;
    updateTodo(id, { title })
      .then(refresh)
      .catch((e) => setError(String(e)));
  };

  const removeTodo = (id: string) => {
    deleteTodo(id)
      .then(refresh)
      .catch((e) => setError(String(e)));
  };

  const list = todos ?? [];

  return (
    <div className="todo-panel">
      {error && <div className="todo-panel-error">{error}</div>}
      <ul className="todo-list">
        {list.map((todo) => {
          const status = (todo.status as Status) ?? "todo";
          const done = status === "done";
          const editing = editingId === todo.id;
          return (
            <li
              key={todo.id}
              className={
                "todo-item status-" + status + (done || editing ? "" : " clickable")
              }
              onClick={() => handleRowClick(todo)}
            >
              <button
                type="button"
                className={"todo-check" + (done ? " checked" : "")}
                onClick={(e) => {
                  e.stopPropagation();
                  cycleStatus(todo);
                }}
                aria-label={`Status: ${status} (click to change)`}
                title={`${status} — click to cycle`}
              >
                {done ? <CheckIcon /> : null}
              </button>
              {!done && (
                <span className={"todo-tag tag-" + status}>
                  {status.toUpperCase()}
                </span>
              )}
              {editing ? (
                <input
                  className="todo-edit-input"
                  value={editingText}
                  autoFocus
                  onChange={(e) => setEditingText(e.target.value)}
                  onBlur={commitEdit}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") commitEdit();
                    if (e.key === "Escape") setEditingId(null);
                  }}
                />
              ) : (
                <span
                  className="todo-title"
                  onDoubleClick={() => beginEdit(todo)}
                  title={statusDatesTooltip(todo)}
                >
                  {todo.title}
                </span>
              )}
              <button
                type="button"
                className="todo-delete"
                onClick={(e) => {
                  e.stopPropagation();
                  removeTodo(todo.id);
                }}
                aria-label="Delete todo"
                title="Delete"
              >
                ×
              </button>
            </li>
          );
        })}
        <li className="todo-item todo-add-row">
          <span className="todo-check todo-add-bullet" aria-hidden />
          <input
            className="todo-add-input"
            placeholder="Add a todo…"
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter") addTodo();
            }}
          />
        </li>
      </ul>
      {list.length === 0 && (
        <div className="todo-empty">No todos yet — add one below or ask your agent.</div>
      )}
    </div>
  );
}

function fmt(ms: number | null): string | null {
  if (ms == null) return null;
  try {
    return new Date(ms).toLocaleString();
  } catch {
    return null;
  }
}

/** Multi-line hover tooltip with the per-status timestamps. */
function statusDatesTooltip(todo: TodoView): string {
  const lines = [`Created: ${fmt(todo.created_at_ms) ?? "—"}`];
  const started = fmt(todo.started_at_ms);
  if (started) lines.push(`Started: ${started}`);
  const done = fmt(todo.done_at_ms);
  if (done) lines.push(`Done: ${done}`);
  lines.push("", "Double-click to edit");
  return lines.join("\n");
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M5 12l5 5L20 6" />
    </svg>
  );
}
