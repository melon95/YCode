// Per-project todo list. Single-column list: each row has a status box, a
// status tag (TODO / DOING) for the in-progress states, and the title (struck
// through + muted when done). Clicking a row toggles it between todo and doing;
// only ticking the checkbox marks it done (or reopens a done item). Double-click
// a title to rename; hover to reveal a delete button. A trailing input row
// appends new todos. Completed todos collapse into a per-week grouped section at
// the bottom, capped at the 10 most recent weeks — a "View all" link opens a
// full archive page listing every completed week. Data is fetched on mount and
// refreshed live via the `TodosChanged` event (which also fires for MCP-driven
// changes made by an AI agent) — see App.tsx.

import { useEffect, useMemo, useRef, useState } from "react";
import {
  createTodo,
  deleteTodo,
  listTodos,
  reorderTodos,
  updateTodo,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { TodoView } from "../lib/types";

type Status = "todo" | "doing" | "done";

// How many weeks of completed todos to show inline before the rest is only
// reachable through the "View all" archive page.
const MAX_INLINE_WEEKS = 10;

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

  // ── Drag-to-reorder (active todos only) ──────────────────────────────
  // Reordering is confined to a single status group: you can shuffle the DOING
  // items among themselves and the TODO items among themselves, but not across
  // groups (status is changed by clicking, not dragging). The dragged id is
  // held in state; `dropTargetId` drives the insertion-line highlight.
  const [dragId, setDragId] = useState<string | null>(null);
  const [dropTargetId, setDropTargetId] = useState<string | null>(null);

  const clearDrag = () => {
    setDragId(null);
    setDropTargetId(null);
  };

  // Commit a reorder: move `draggedId` to just before `targetId` within their
  // shared status group, then persist the full new ordering. Applied
  // optimistically so the row settles instantly; the IPC (and its TodosChanged
  // event) reconcile afterwards.
  const commitReorder = (draggedId: string, targetId: string) => {
    if (draggedId === targetId) return;
    const cur = todos ?? [];
    const byId = new Map(cur.map((t) => [t.id, t] as const));
    const dragged = byId.get(draggedId);
    const target = byId.get(targetId);
    if (!dragged || !target) return;
    const groupStatus = dragged.status as Status;
    if ((target.status as Status) !== groupStatus) return; // same group only

    const groupIds = cur
      .filter((t) => (t.status as Status) === groupStatus)
      .map((t) => t.id);
    const from = groupIds.indexOf(draggedId);
    if (from < 0) return;
    groupIds.splice(from, 1);
    const insertAt = groupIds.indexOf(targetId);
    groupIds.splice(insertAt < 0 ? groupIds.length : insertAt, 0, draggedId);

    // Rebuild the whole project order as doing → todo → done, substituting the
    // reordered group. Keeps sort_order globally consistent.
    const idsFor = (status: Status) =>
      status === groupStatus
        ? groupIds
        : cur
            .filter((t) => (t.status as Status) === status)
            .map((t) => t.id);
    const fullOrder = [...idsFor("doing"), ...idsFor("todo"), ...idsFor("done")];

    setTodos(
      projectId,
      fullOrder.map((id) => byId.get(id)).filter((t): t is TodoView => !!t),
    );
    reorderTodos(projectId, fullOrder).catch((e) => {
      setError(String(e));
      refresh();
    });
  };

  const dragHandlers = (todo: TodoView) => ({
    draggable: editingId !== todo.id,
    onDragStart: (e: React.DragEvent) => {
      setDragId(todo.id);
      e.dataTransfer.effectAllowed = "move";
      // Firefox refuses to start a drag unless some data is set.
      try {
        e.dataTransfer.setData("text/plain", todo.id);
      } catch {
        /* older browsers — best effort */
      }
    },
    onDragOver: (e: React.DragEvent) => {
      if (!dragId || dragId === todo.id) return;
      const dragged = (todos ?? []).find((t) => t.id === dragId);
      // Only same-group drops are valid targets.
      if (!dragged || dragged.status !== todo.status) return;
      e.preventDefault();
      e.dataTransfer.dropEffect = "move";
      if (dropTargetId !== todo.id) setDropTargetId(todo.id);
    },
    onDrop: (e: React.DragEvent) => {
      e.preventDefault();
      const draggedId = dragId;
      clearDrag();
      if (draggedId) commitReorder(draggedId, todo.id);
    },
    onDragEnd: clearDrag,
  });

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
        className={
          "todo-item status-" +
          status +
          (done || editing ? "" : " clickable") +
          (canDrag ? " draggable" : "") +
          (dragId === todo.id ? " dragging" : "") +
          (dropTargetId === todo.id ? " drop-target" : "")
        }
        onClick={() => handleRowClick(todo)}
        {...(canDrag ? dragHandlers(todo) : {})}
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
  };

  const list = todos ?? [];
  // Completed todos sink to a collapsible group at the bottom; the active todos
  // split into DOING then TODO sub-groups (their "category") above the add-row.
  const doing = list.filter((t) => (t.status as Status) === "doing");
  const todo = list.filter((t) => (t.status as Status) === "todo");
  const done = list.filter((t) => (t.status as Status) === "done");
  // Only show the "In progress" / "To do" section headers when both groups are
  // populated — a lone header over a single group is just noise.
  const showGroupHeaders = doing.length > 0 && todo.length > 0;
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
      <ul className="todo-list">
        {showGroupHeaders && doing.length > 0 && (
          <li className="todo-group-header">In progress</li>
        )}
        {doing.map((t) => renderTodo(t, { draggable: true }))}
        {showGroupHeaders && (
          <li className="todo-group-header">To do</li>
        )}
        {todo.map((t) => renderTodo(t, { draggable: true }))}
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
