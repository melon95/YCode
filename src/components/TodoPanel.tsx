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

/// 面板整体是个 container:窄到 500px 以下时概览换行、行内边距收紧、
/// 拖拽把手让位(见下面的 `@max-[500px]:`)。
const PANEL =
  "h-full min-h-0 overflow-y-auto pt-4 px-3.5 pb-[22px] bg-bg [container-type:inline-size]";

/// 拖拽重排的手感提示。grab 光标覆盖整行(含标题),"可拖"这件事才是
/// 一致的,而不是只在状态标签上才出现。标题默认的 `cursor: text` 被这里
/// 盖掉;真正的编辑光标在重命名时替换标题的那个 input 上。
/// `todo-item` 是无样式钩子:TodoPanel.test.tsx 用 `closest(".todo-item")`
/// 从标题找回整行来做拖拽重排的断言。
const ROW = `todo-item group/row flex min-h-12 items-center gap-2 py-[7px] px-[9px]
  border border-transparent rounded-sm relative
  transition-[border-color,background-color,opacity] duration-[var(--duration-fast)] ease-out
  hover:border-rule hover:bg-control-hover
  @max-[500px]:gap-[7px] @max-[500px]:px-2`.replace(/\s+/g, " ");

/// 空态两行:第二行比第一行再轻一档。
const ACTIVE_EMPTY = `flex min-h-40 flex-col items-center justify-center gap-[5px]
  text-text-soft font-ui text-[11px] text-center
  [&>span:last-child]:text-subtle [&>span:last-child]:text-[10px]`.replace(
  /\s+/g,
  " ",
);

/// 归档页返回键、「已完成」折叠头、「查看全部」都是同一种低声量文字按钮。
/// 6px 而不是 8px —— 迁移前 design-system.css 把这几个的圆角统一压到
/// `--radius-sm`,它加载在 styles.css 之后,同特异性下胜出。
const QUIET_BTN = `flex items-center border-0 rounded-sm bg-transparent cursor-pointer
  hover:bg-control-hover`.replace(/\s+/g, " ");

const TODO_LIST = "list-none m-0 p-0 flex flex-col gap-1";

const WEEK_LIST = "list-none mt-1 mx-0 mb-0 p-0 flex flex-col gap-2";

const PANEL_ERROR =
  "mt-1 mx-2 mb-2 py-1.5 px-2.5 rounded-sm bg-accent-10 text-accent text-xs";

const SUMMARY_ITEM = `grid grid-cols-[auto_auto] items-baseline gap-[5px] text-subtle
  font-ui text-[9px] font-[650] tracking-[0.04em] uppercase`.replace(/\s+/g, " ");
const SUMMARY_NUM = "text-text-soft font-mono text-xs font-[650] tracking-normal";
const SUMMARY_RULE = "w-px h-3.5 bg-rule-strong @max-[500px]:mx-0.5";

/// 活动列表里的状态小标题(「进行中」/「队列」)。末尾那个计数换等宽。
const GROUP_HEADER = `list-none flex items-center justify-between mt-2 first:mt-0
  pt-1 px-[9px] pb-[3px] font-ui text-[9px] font-bold tracking-[0.09em] uppercase text-subtle
  [&>span:last-child]:text-muted [&>span:last-child]:font-mono
  [&>span:last-child]:text-[9px] [&>span:last-child]:tracking-normal`.replace(
  /\s+/g,
  " ",
);

/// 「已完成」的周计数、归档页标题旁的总数,同一枚数字。
const DONE_COUNT = "ml-auto font-bold text-subtle";

/// 焦点态的例外写在 styles.css(`.todo-edit-input` / `.todo-add-input`)
/// —— 全局 `:focus-visible` 是 unlayered 的,utility 层压不过它。这里的
/// 类名只是给那两条规则当钩子。
const INPUT = `flex-1 min-w-0 border-0 bg-transparent text-text-soft font-[inherit] text-[13px]
  p-0 outline-none appearance-none shadow-none`.replace(/\s+/g, " ");

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
        className={[
          ROW,
          // hover 时也保持强调色边框 —— 迁移前 `.status-doing` 写在
          // `:hover` 之后、同特异性下胜出,这里靠 `hover:` 变体把优先级追平。
          status === "doing" &&
            "border-accent-12 bg-accent-045 hover:border-accent-12",
          // todo/doing 行点哪儿都能切状态。
          !done && !editing && "cursor-pointer",
          canDrag && "hover:cursor-grab [&:hover_[data-title]]:cursor-grab",
          todoReorder.dragId === todo.id && "opacity-40",
          // 插入位置标记走指针事件,在 Tauri/WKWebView 里是可用的。
          todoReorder.dropTarget?.id === todo.id &&
            (todoReorder.dropTarget.edge === "before"
              ? "shadow-[inset_0_2px_0_var(--color-accent)]"
              : "shadow-[inset_0_-2px_0_var(--color-accent)]"),
        ]
          .filter(Boolean)
          .join(" ")}
        onClick={() => handleRowClick(todo)}
      >
        {/* 状态方块 —— todo/doing 空,done 填充打勾。 */}
        <button
          type="button"
          className={`flex-[0_0_17px] size-[17px] inline-flex items-center justify-center
            border-[1.5px] rounded-[5px] cursor-pointer p-0
            transition-[border-color,background-color] duration-[var(--duration-fast)] ease-out
            hover:border-accent
            ${
              done
                ? "bg-accent border-accent text-white"
                : "bg-transparent text-bg " +
                  (status === "doing"
                    ? "border-accent shadow-[inset_0_0_0_3px_var(--color-accent-35)]"
                    : "border-subtle")
            }`
            .replace(/\s+/g, " ")
            .trim()}
          onClick={(e) => {
            e.stopPropagation();
            toggleDone(todo);
          }}
          aria-label={done ? "已完成 — 点击可重新打开" : "标记为已完成"}
          title={done ? "已完成 — 点击可重新打开" : "标记为已完成"}
        >
          {done ? <CheckIcon /> : null}
        </button>
        <div className="flex-1 min-w-0 flex flex-col gap-[3px]">
          {editing ? (
            // 全局的 `:focus-visible` 光晕在这种无边框矮输入框上会渲染成
            // 两条游离的横线,由 styles.css 里的同名规则关掉。
            <input
              className={`todo-edit-input ${INPUT} min-h-[30px]`}
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
                data-title
                className={`min-w-0 text-[13px] font-[540] leading-[1.3] cursor-text break-words ${
                  done ? "line-through text-subtle" : "text-text-soft"
                }`}
                onDoubleClick={() => beginEdit(todo)}
                title={statusDatesTooltip(todo)}
              >
                {todo.title}
              </span>
              <span className="text-subtle font-ui text-[9px] leading-[1.2]">
                {statusTimeLabel(todo, status)}
              </span>
            </>
          )}
        </div>
        {/* TODO / DOING 标签。在活动行上它就是切状态的点击目标,所以自己
            打上 pointer 光标(压过整行的 grab)加一层 hover 高亮 —— 把
            「点一下换状态」和行其余部分的「拖一下重排」在视觉上分开。 */}
        {!done && (
          <span
            className={[
              "inline-flex flex-none items-center gap-[5px] py-[3px] px-1.5",
              "border rounded-full font-ui text-[8px] font-bold tracking-[0.06em] uppercase",
              "transition-[border-color,background-color] duration-[var(--duration-fast)] ease-out",
              status === "doing"
                ? "text-accent border-accent-25 bg-accent-hover-wash"
                : "text-subtle border-rule",
              !editing &&
                "cursor-pointer hover:border-accent hover:bg-accent-10",
            ]
              .filter(Boolean)
              .join(" ")}
          >
            <span className="size-[5px] rounded-full bg-current" aria-hidden />
            {status === "doing" ? "进行中" : "排队中"}
          </span>
        )}
        {canDrag && (
          <span
            // `todo-drag-handle` 同为无样式钩子:TodoPanel.test.tsx 用它
            // 从行里取出把手来派发 pointer 事件。
            className="todo-drag-handle inline-flex flex-[0_0_16px] w-4 h-5 items-center justify-center
              text-muted opacity-0 cursor-grab touch-none
              transition-[opacity,color] duration-[var(--duration-fast)] ease-out
              active:cursor-grabbing group-hover/row:opacity-72
              @max-[500px]:hidden"
            aria-hidden
            title="拖动以重新排序"
            onPointerDown={(event) => todoReorder.handlePointerDown(event, todo)}
            onClick={(event) => event.stopPropagation()}
          >
            <GripIcon />
          </span>
        )}
        <button
          type="button"
          className="flex-[0_0_18px] size-[18px] inline-flex items-center justify-center
            border-0 rounded-[5px] bg-transparent text-subtle cursor-pointer opacity-0
            transition-[opacity,color,background-color] duration-[var(--duration-fast)] ease-out
            group-hover/row:opacity-100
            hover:bg-highlight-press hover:text-text"
          onClick={(e) => {
            e.stopPropagation();
            removeTodo(todo.id);
          }}
          aria-label="删除 todo"
          title="删除"
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
    <li key={w.weekStart}>
      <div className="flex items-center gap-1.5 py-0.5 px-2">
        <span className="text-[11px] font-bold tracking-[0.03em] text-text-soft">
          {w.label}
        </span>
        <span className="ml-auto text-[11px] font-bold text-subtle">
          {w.items.length}
        </span>
      </div>
      <ul className={TODO_LIST}>{w.items.map((t) => renderTodo(t))}</ul>
    </li>
  );

  // The archive is a full-panel page (not a modal) that lists every completed
  // week, reachable via "View all" when the inline section is capped.
  if (showArchive) {
    return (
      <div className={PANEL}>
        {error && <div className={PANEL_ERROR}>{error}</div>}
        <div className="flex items-center gap-2 pt-0.5 px-1 pb-2.5 border-b border-highlight-hairline mb-2.5">
          <button
            type="button"
            className={`${QUIET_BTN} inline-flex gap-1 pt-1 pr-2 pb-1 pl-1.5 text-text-soft text-xs font-semibold hover:text-text`}
            onClick={() => setShowArchive(false)}
          >
            <BackIcon />
            <span>返回</span>
          </button>
          <span className="text-[13px] font-bold text-text">全部已完成</span>
          <span className={`${DONE_COUNT} text-xs`}>{done.length}</span>
        </div>
        {weeks.length === 0 ? (
          <div className="empty">还没有已完成的 todo。</div>
        ) : (
          <ul className={WEEK_LIST}>{weeks.map(renderWeek)}</ul>
        )}
      </div>
    );
  }

  return (
    <div className={PANEL}>
      {error && <div className={PANEL_ERROR}>{error}</div>}
      <header
        className="flex items-end justify-between gap-5 mt-0.5 mx-0.5 mb-[15px] pt-0 px-0.5 pb-3.5
          border-b border-rule
          @max-[500px]:items-start @max-[500px]:flex-col @max-[500px]:gap-2.5"
      >
        <div className="min-w-0">
          <h2 className="m-0 text-text font-display text-[18px] font-[620] leading-[1.15] tracking-[-0.018em]">
            任务流
          </h2>
          <p className="mt-[5px] mx-0 mb-0 text-subtle font-ui text-[10px] leading-[1.35]">
            在队列与进行中之间流转你的工作。
          </p>
        </div>
        <div
          className="inline-flex flex-none items-center gap-2.5 pb-px @max-[500px]:w-full"
          aria-label="任务概览"
        >
          {/* 进行中的数字用 accent —— 概览里唯一需要先被看到的那个。 */}
          <span className={SUMMARY_ITEM}>
            <strong className={`${SUMMARY_NUM} !text-accent`}>
              {doing.length}
            </strong>
            <span>进行中</span>
          </span>
          <span className={SUMMARY_RULE} aria-hidden />
          <span className={SUMMARY_ITEM}>
            <strong className={SUMMARY_NUM}>{todo.length}</strong>
            <span>排队中</span>
          </span>
          {done.length > 0 && (
            <>
              <span className={SUMMARY_RULE} aria-hidden />
              <span className={SUMMARY_ITEM}>
                <strong className={SUMMARY_NUM}>{done.length}</strong>
                <span>已完成</span>
              </span>
            </>
          )}
        </div>
      </header>
      <form
        className="group/capture flex min-h-10 items-center gap-[9px] mt-0 mx-0.5 mb-[15px] px-2.5
          border border-rule-strong rounded-sm bg-surface text-subtle
          transition-[border-color,box-shadow,background-color] duration-[var(--duration-fast)] ease-out
          focus-within:border-accent focus-within:bg-panel-raised
          focus-within:shadow-[0_0_0_3px_var(--color-accent-10)] focus-within:text-accent
          [&>svg]:flex-none"
        onSubmit={(event) => {
          event.preventDefault();
          addTodo();
        }}
      >
        <PlusIcon />
        <input
          className={`todo-add-input ${INPUT} placeholder:text-subtle`}
          aria-label="新建 todo"
          placeholder="新建 todo…"
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
        <button
          type="submit"
          className="inline-flex flex-none items-center justify-center p-0 border-0 outline-0
            bg-transparent cursor-pointer disabled:cursor-default disabled:opacity-58
            [&>kbd]:flex-none [&>kbd]:min-w-[22px] [&>kbd]:py-0.5 [&>kbd]:px-[5px]
            [&>kbd]:border [&>kbd]:border-rule-strong [&>kbd]:rounded-xs
            [&>kbd]:bg-panel-sunken [&>kbd]:text-subtle [&>kbd]:font-ui [&>kbd]:text-[9px] [&>kbd]:text-center
            enabled:hover:[&>kbd]:border-accent enabled:hover:[&>kbd]:text-accent"
          aria-label="添加 todo"
          title="添加 todo"
          disabled={!draft.trim()}
        >
          <kbd>↵</kbd>
        </button>
      </form>
      <ul className={TODO_LIST} {...todoReorder.containerHandlers}>
        {doing.length > 0 && (
          <li className={GROUP_HEADER}>
            <span>进行中</span>
            <span>{doing.length}</span>
          </li>
        )}
        {doing.map((t) => renderTodo(t, { draggable: true }))}
        {todo.length > 0 && (
          <li className={GROUP_HEADER}>
            <span>队列</span>
            <span>{todo.length}</span>
          </li>
        )}
        {todo.map((t) => renderTodo(t, { draggable: true }))}
        {doing.length === 0 && todo.length === 0 && (
          <li className={ACTIVE_EMPTY}>
            <span>当前没有进行中的任务。</span>
            <span>准备好后,在上方新建一个 todo。</span>
          </li>
        )}
      </ul>
      {/* 底部可折叠的「已完成」分组。 */}
      {done.length > 0 && (
        <div className="mt-2.5 border-t border-highlight-hairline pt-1.5">
          <button
            type="button"
            className={`${QUIET_BTN} gap-1.5 w-full py-[5px] px-2 text-subtle
              text-[11px] font-bold tracking-[0.04em] uppercase hover:text-text-soft
              ${showDone ? "[&>svg]:rotate-90" : ""}`}
            onClick={() => setShowDone((v) => !v)}
            aria-expanded={showDone}
          >
            <ChevronIcon />
            <span>已完成</span>
            <span className={DONE_COUNT}>{done.length}</span>
          </button>
          {showDone && (
            <>
              <ul className={WEEK_LIST}>{inlineWeeks.map(renderWeek)}</ul>
              {hiddenWeeks > 0 && (
                <button
                  type="button"
                  className={`${QUIET_BTN} items-baseline gap-2 w-full mt-1.5 py-1.5 px-2
                    text-accent text-xs font-semibold`}
                  onClick={() => setShowArchive(true)}
                >
                  查看全部已完成
                  <span className="ml-auto text-subtle font-medium">
                    还有 {hiddenWeeks} 周
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

/** 「本周」/「上周」,更早则显示该周的日期区间(如 "Jun 2 – Jun 8")。 */
function weekLabel(weekStart: number, currentWeekStart: number): string {
  const weeksAgo = Math.round((currentWeekStart - weekStart) / WEEK_MS);
  if (weeksAgo <= 0) return "本周";
  if (weeksAgo === 1) return "上周";
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

/** 多行悬停提示,展示各状态对应的时间戳。 */
function statusDatesTooltip(todo: TodoView): string {
  const lines = [`创建于:${fmt(todo.created_at_ms) ?? "—"}`];
  const started = fmt(todo.started_at_ms);
  if (started) lines.push(`开始于:${started}`);
  const done = fmt(todo.done_at_ms);
  if (done) lines.push(`完成于:${done}`);
  lines.push("", "双击可编辑");
  return lines.join("\n");
}

function statusTimeLabel(todo: TodoView, status: Status): string {
  const timestamp =
    status === "doing"
      ? (todo.started_at_ms ?? todo.updated_at_ms)
      : status === "done"
        ? (todo.done_at_ms ?? todo.updated_at_ms)
        : todo.created_at_ms;
  const verb = status === "doing" ? "开始于" : status === "done" ? "完成于" : "添加于";
  return `${verb} ${relativeTime(timestamp)}`;
}

function relativeTime(ms: number): string {
  const elapsed = Math.max(0, Date.now() - ms);
  const minute = 60 * 1000;
  const hour = 60 * minute;
  const day = 24 * hour;
  if (elapsed < minute) return "刚刚";
  if (elapsed < hour) return `${Math.floor(elapsed / minute)} 分钟前`;
  if (elapsed < day) return `${Math.floor(elapsed / hour)} 小时前`;
  if (elapsed < 7 * day) return `${Math.floor(elapsed / day)} 天前`;
  return new Intl.DateTimeFormat(undefined, {
    month: "short",
    day: "numeric",
  }).format(new Date(ms));
}

function ChevronIcon() {
  return (
    <svg
      className="transition-transform duration-[var(--duration-fast)] ease-out"
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
