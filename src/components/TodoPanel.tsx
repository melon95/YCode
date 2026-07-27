// Per-project task flow built on the existing todo state machine. The overview,
// capture field, grouped counts, and per-row timestamps are all derived from
// real TodoView data; no engineering/session relationship is implied until the
// task-worktree schema exists. Clicking an active row toggles todo/doing, while
// completion stays an explicit checkbox action. Double-click renames, drag
// reorders within a status group, and completed work remains grouped by week.

import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  createTodo,
  deleteTodo,
  listTodos,
  updateTodo,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { TodoView } from "../lib/types";
import { useTodoReorder } from "./useTodoReorder";

type Status = "todo" | "doing" | "done";

// How many weeks of completed todos to show inline before the rest is only
// reachable through the "View all" archive page.
const MAX_INLINE_WEEKS = 10;
const EMPTY_TODOS: TodoView[] = [];

export function TodoPanel({ projectId }: { projectId: string }) {
  const todos = useStore((s) => s.todos[projectId]);
  const setTodos = useStore((s) => s.setTodos);
  const [error, setError] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [editingId, setEditingId] = useState<string | null>(null);
  const [editingText, setEditingText] = useState("");
  // Completed todos live in a collapsed section at the bottom so the active
  // list stays focused. Collapsed by default; persists for the panel's life.
  const [showDone, setShowDone] = useState(false);
  // Full-panel archive page listing *every* completed week (the inline section
  // is capped at MAX_INLINE_WEEKS). Toggled by the "View all" link.
  const [showArchive, setShowArchive] = useState(false);

  const refresh = useCallback(() => {
    listTodos(projectId)
      .then((list) => setTodos(projectId, list))
      .catch((e) => setError(String(e)));
  }, [projectId, setTodos]);
  const list = todos ?? EMPTY_TODOS;
  const todoReorder = useTodoReorder({
    projectId,
    todos: list,
    setTodos,
    onError: setError,
    refresh,
  });

  // Fetch on mount / project switch. Subsequent updates arrive via the
  // TodosChanged event handled in App.tsx, but we also refresh after our own
  // mutations below in case the event bus lags.
  useEffect(() => {
    refresh();
  }, [refresh]);

  const setStatus = (todo: TodoView, next: Status) => {
    updateTodo(todo.id, { status: next })
      .then(refresh)
      .catch((e) => setError(String(e)));
  };

  // Row click toggles between the two active states only — it never completes a
  // todo. Completion is an explicit checkbox tick (see `toggleDone`).
  const toggleActive = (todo: TodoView) => {
    const status = (todo.status as Status) ?? "todo";
    setStatus(todo, status === "doing" ? "todo" : "doing");
  };

  // Checkbox tick: mark done, or reopen a done item back to todo.
  const toggleDone = (todo: TodoView) => {
    const status = (todo.status as Status) ?? "todo";
    setStatus(todo, status === "done" ? "todo" : "done");
  };

  // Pending single-click timer, used to disambiguate a row click (advance
  // status) from a double-click on the title (edit). A double-click clears it
  // before it fires.
  const clickTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => () => {
    if (clickTimer.current) clearTimeout(clickTimer.current);
  }, []);

  // Click anywhere on a todo/doing row to toggle it between todo and doing.
  // Done rows aren't affected by a row click — use the checkbox to reopen them.
  const handleRowClick = (todo: TodoView) => {
    if (todoReorder.consumeSuppressedClick()) return;
    const status = (todo.status as Status) ?? "todo";
    if (status === "done") return;
    if (editingId === todo.id) return;
    if (clickTimer.current) clearTimeout(clickTimer.current);
    clickTimer.current = setTimeout(() => {
      clickTimer.current = null;
      toggleActive(todo);
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

  const renderTodo = (todo: TodoView, opts?: { draggable?: boolean }) => {
    const status = (todo.status as Status) ?? "todo";
    const done = status === "done";
    const editing = editingId === todo.id;
    const canDrag = !!opts?.draggable && !editing;
    return (
      <li
        key={todo.id}
        data-todo-reorder-id={canDrag ? todo.id : undefined}
        className={
          "todo-item status-" +
          status +
          (done || editing ? "" : " clickable") +
          (canDrag ? " draggable" : "") +
          (todoReorder.dragId === todo.id ? " dragging" : "") +
          (todoReorder.dropTarget?.id === todo.id
            ? ` drop-${todoReorder.dropTarget.edge}`
            : "")
        }
        onClick={() => handleRowClick(todo)}
      >
        <button
          type="button"
          className={"todo-check" + (done ? " checked" : "")}
          onClick={(e) => {
            e.stopPropagation();
            toggleDone(todo);
          }}
          aria-label={done ? "Completed — click to reopen" : "Mark completed"}
          title={done ? "Completed — click to reopen" : "Mark completed"}
        >
          {done ? <CheckIcon /> : null}
        </button>
        <div className="todo-item-content">
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
            <>
              <span
                className="todo-title"
                onDoubleClick={() => beginEdit(todo)}
                title={statusDatesTooltip(todo)}
              >
                {todo.title}
              </span>
              <span className="todo-item-meta">{statusTimeLabel(todo, status)}</span>
            </>
          )}
        </div>
        {!done && (
          <span className={"todo-tag tag-" + status}>
            <span className="todo-tag-dot" aria-hidden />
            {status === "doing" ? "Active" : "Queued"}
          </span>
        )}
        {canDrag && (
          <span
            className="todo-drag-handle"
            aria-hidden
            title="Drag to reorder"
            onPointerDown={(event) => todoReorder.handlePointerDown(event, todo)}
            onClick={(event) => event.stopPropagation()}
          >
            <GripIcon />
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
          <TrashIcon />
        </button>
      </li>
    );
  };

  // Completed todos sink to a collapsible group at the bottom; the active todos
  // split into DOING then TODO sub-groups (their "category") above the add-row.
  const { doing, todo, done } = useMemo(() => {
    const groups: Record<Status, TodoView[]> = {
      doing: [],
      todo: [],
      done: [],
    };
    for (const item of list) {
      const status = item.status as Status;
      (groups[status] ?? groups.todo).push(item);
    }
    return groups;
  }, [list]);
  // Bucket completed todos by the week they were finished, newest week first.
  // Recomputed only when the completed set changes.
  const weeks = useMemo(() => groupByWeek(done), [done]);
  const inlineWeeks = weeks.slice(0, MAX_INLINE_WEEKS);
  const hiddenWeeks = weeks.length - inlineWeeks.length;

  const renderWeek = (w: WeekGroup) => (
    <li key={w.weekStart} className="todo-week">
      <div className="todo-week-header">
        <span className="todo-week-label">{w.label}</span>
        <span className="todo-week-count">{w.items.length}</span>
      </div>
      <ul className="todo-list">{w.items.map((t) => renderTodo(t))}</ul>
    </li>
  );

  // The archive is a full-panel page (not a modal) that lists every completed
  // week, reachable via "View all" when the inline section is capped.
  if (showArchive) {
    return (
      <div className="todo-panel todo-archive">
        {error && <div className="todo-panel-error">{error}</div>}
        <div className="todo-archive-header">
          <button
            type="button"
            className="todo-archive-back"
            onClick={() => setShowArchive(false)}
          >
            <BackIcon />
            <span>Back</span>
          </button>
          <span className="todo-archive-title">All completed</span>
          <span className="todo-done-count">{done.length}</span>
        </div>
        {weeks.length === 0 ? (
          <div className="empty">Nothing completed yet.</div>
        ) : (
          <ul className="todo-week-list">{weeks.map(renderWeek)}</ul>
        )}
      </div>
    );
  }

  return (
    <div className="todo-panel">
      {error && <div className="todo-panel-error">{error}</div>}
      <header className="todo-panel-overview">
        <div className="todo-panel-heading">
          <h2>Task flow</h2>
          <p>Move work between the queue and active focus.</p>
        </div>
        <div className="todo-panel-summary" aria-label="Task summary">
          <span className="todo-summary-item summary-active">
            <strong>{doing.length}</strong>
            <span>Active</span>
          </span>
          <span className="todo-summary-rule" aria-hidden />
          <span className="todo-summary-item">
            <strong>{todo.length}</strong>
            <span>Queued</span>
          </span>
          {done.length > 0 && (
            <>
              <span className="todo-summary-rule" aria-hidden />
              <span className="todo-summary-item">
                <strong>{done.length}</strong>
                <span>Done</span>
              </span>
            </>
          )}
        </div>
      </header>
      <form
        className="todo-capture"
        onSubmit={(event) => {
          event.preventDefault();
          addTodo();
        }}
      >
        <PlusIcon />
        <input
          className="todo-add-input"
          aria-label="New task"
          placeholder="Add a task"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button
          type="submit"
          className="todo-capture-submit"
          aria-label="Add task"
          title="Add task"
          disabled={!draft.trim()}
        >
          <kbd>↵</kbd>
        </button>
      </form>
      <ul className="todo-list" {...todoReorder.containerHandlers}>
        {doing.length > 0 && (
          <li className="todo-group-header">
            <span>In progress</span>
            <span>{doing.length}</span>
          </li>
        )}
        {doing.map((t) => renderTodo(t, { draggable: true }))}
        {todo.length > 0 && (
          <li className="todo-group-header">
            <span>Queue</span>
            <span>{todo.length}</span>
          </li>
        )}
        {todo.map((t) => renderTodo(t, { draggable: true }))}
        {doing.length === 0 && todo.length === 0 && (
          <li className="todo-active-empty">
            <span>Nothing in flight.</span>
            <span>Add a task above when you are ready.</span>
          </li>
        )}
      </ul>
      {done.length > 0 && (
        <div className="todo-done-section">
          <button
            type="button"
            className={"todo-done-toggle" + (showDone ? " open" : "")}
            onClick={() => setShowDone((v) => !v)}
            aria-expanded={showDone}
          >
            <ChevronIcon />
            <span className="todo-done-label">Completed</span>
            <span className="todo-done-count">{done.length}</span>
          </button>
          {showDone && (
            <>
              <ul className="todo-week-list">{inlineWeeks.map(renderWeek)}</ul>
              {hiddenWeeks > 0 && (
                <button
                  type="button"
                  className="todo-view-all"
                  onClick={() => setShowArchive(true)}
                >
                  View all completed
                  <span className="todo-view-all-hint">
                    +{hiddenWeeks} more {hiddenWeeks === 1 ? "week" : "weeks"}
                  </span>
                </button>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

type WeekGroup = { weekStart: number; label: string; items: TodoView[] };

/** Local-time timestamp of Monday 00:00 for the week containing `ms`. */
function weekStartMs(ms: number): number {
  const d = new Date(ms);
  d.setHours(0, 0, 0, 0);
  // getDay(): 0=Sun … 6=Sat. Shift so Monday is the start of the week.
  const mondayOffset = (d.getDay() + 6) % 7;
  d.setDate(d.getDate() - mondayOffset);
  return d.getTime();
}

/** "This week" / "Last week", else the week's date span (e.g. "Jun 2 – Jun 8"). */
function weekLabel(weekStart: number, currentWeekStart: number): string {
  const weeksAgo = Math.round((currentWeekStart - weekStart) / WEEK_MS);
  if (weeksAgo <= 0) return "This week";
  if (weeksAgo === 1) return "Last week";
  const opts: Intl.DateTimeFormatOptions = { month: "short", day: "numeric" };
  const start = new Date(weekStart).toLocaleDateString(undefined, opts);
  const end = new Date(weekStart + 6 * 24 * 60 * 60 * 1000).toLocaleDateString(
    undefined,
    opts,
  );
  return `${start} – ${end}`;
}

/**
 * Bucket completed todos into weeks by their `done_at_ms` (falling back to
 * update/create time for legacy rows without a done stamp). Weeks are ordered
 * newest-first, and each week's items newest-completed-first.
 */
function groupByWeek(done: TodoView[]): WeekGroup[] {
  const currentWeekStart = weekStartMs(Date.now());
  const buckets = new Map<number, TodoView[]>();
  for (const t of done) {
    const ms = t.done_at_ms ?? t.updated_at_ms ?? t.created_at_ms;
    const ws = weekStartMs(ms);
    const bucket = buckets.get(ws);
    if (bucket) bucket.push(t);
    else buckets.set(ws, [t]);
  }
  return Array.from(buckets.entries())
    .map(([ws, items]) => ({
      weekStart: ws,
      label: weekLabel(ws, currentWeekStart),
      items: items.sort(
        (a, b) => (b.done_at_ms ?? 0) - (a.done_at_ms ?? 0),
      ),
    }))
    .sort((a, b) => b.weekStart - a.weekStart);
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

function statusTimeLabel(todo: TodoView, status: Status): string {
  const timestamp =
    status === "doing"
      ? (todo.started_at_ms ?? todo.updated_at_ms)
      : status === "done"
        ? (todo.done_at_ms ?? todo.updated_at_ms)
        : todo.created_at_ms;
  const verb = status === "doing" ? "Started" : status === "done" ? "Completed" : "Added";
  return `${verb} ${relativeTime(timestamp)}`;
}

function relativeTime(ms: number): string {
  const elapsed = Math.max(0, Date.now() - ms);
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (elapsed < minute) return "just now";
  if (elapsed < hour) return `${Math.floor(elapsed / minute)}m ago`;
  if (elapsed < day) return `${Math.floor(elapsed / hour)}h ago`;
  if (elapsed < 7 * day) return `${Math.floor(elapsed / day)}d ago`;
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
  }).format(new Date(ms));
}

function ChevronIcon() {
  return (
    <svg
      className="todo-done-chevron"
      viewBox="0 0 24 24"
      width="12"
      height="12"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M9 6l6 6-6 6" />
    </svg>
  );
}

function BackIcon() {
  return (
    <svg
      viewBox="0 0 24 24"
      width="14"
      height="14"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.5"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="M15 6l-6 6 6 6" />
    </svg>
  );
}

function CheckIcon() {
  return (
    <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M5 12l5 5L20 6" />
    </svg>
  );
}

function PlusIcon() {
  return (
    <svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden>
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

function GripIcon() {
  return (
    <svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor" aria-hidden>
      <circle cx="5" cy="4" r="1" />
      <circle cx="11" cy="4" r="1" />
      <circle cx="5" cy="8" r="1" />
      <circle cx="11" cy="8" r="1" />
      <circle cx="5" cy="12" r="1" />
      <circle cx="11" cy="12" r="1" />
    </svg>
  );
}

function TrashIcon() {
  return (
    <svg viewBox="0 0 24 24" width="13" height="13" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d="M4 7h16M9 7V4h6v3M7 7l1 13h8l1-13M10 11v5M14 11v5" />
    </svg>
  );
}
