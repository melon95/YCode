import { useCallback, useRef, useState } from "react";
import type { PointerEvent as ReactPointerEvent } from "react";
import { reorderTodos } from "../lib/ipc";
import type { TodoView } from "../lib/types";

type TodoStatus = "doing" | "todo" | "done";
type DropEdge = "before" | "after";

export interface TodoDropTarget {
  id: string;
  edge: DropEdge;
}

export interface TodoReorderController {
  dragId: string | null;
  dropTarget: TodoDropTarget | null;
  containerHandlers: {
    onPointerMove: (event: ReactPointerEvent<HTMLElement>) => void;
    onPointerUp: (event: ReactPointerEvent<HTMLElement>) => void;
    onPointerCancel: (event: ReactPointerEvent<HTMLElement>) => void;
  };
  handlePointerDown: (
    event: ReactPointerEvent<HTMLElement>,
    todo: TodoView,
  ) => void;
  consumeSuppressedClick: () => boolean;
}

interface Options {
  projectId: string;
  todos: TodoView[];
  setTodos: (projectId: string, todos: TodoView[]) => void;
  onError: (error: string) => void;
  refresh: () => void;
}

const ACTIVE_STATUSES: TodoStatus[] = ["doing", "todo"];

export function useTodoReorder({
  projectId,
  todos,
  setTodos,
  onError,
  refresh,
}: Options): TodoReorderController {
  const [dragId, setDragId] = useState<string | null>(null);
  const [dropTarget, setDropTarget] = useState<TodoDropTarget | null>(null);
  const dragRef = useRef<{
    id: string;
    pointerId: number;
    startX: number;
    startY: number;
    active: boolean;
  } | null>(null);
  const dropTargetRef = useRef<TodoDropTarget | null>(null);
  const suppressClickRef = useRef(false);

  const clearDrag = useCallback(() => {
    dragRef.current = null;
    dropTargetRef.current = null;
    setDragId(null);
    setDropTarget(null);
  }, []);

  const commitReorder = useCallback(
    (draggedId: string, targetId: string, edge: DropEdge) => {
      if (draggedId === targetId) return;
      const byId = new Map(todos.map((todo) => [todo.id, todo] as const));
      const dragged = byId.get(draggedId);
      const target = byId.get(targetId);
      if (!dragged || !target || dragged.status !== target.status) return;

      const groupStatus = dragged.status as TodoStatus;
      if (!ACTIVE_STATUSES.includes(groupStatus)) return;
      const groupIds = todos
        .filter((todo) => todo.status === groupStatus)
        .map((todo) => todo.id);
      const from = groupIds.indexOf(draggedId);
      if (from < 0) return;
      groupIds.splice(from, 1);
      const targetIndex = groupIds.indexOf(targetId);
      if (targetIndex < 0) return;
      groupIds.splice(targetIndex + (edge === "after" ? 1 : 0), 0, draggedId);

      const idsFor = (status: TodoStatus) =>
        status === groupStatus
          ? groupIds
          : todos.filter((todo) => todo.status === status).map((todo) => todo.id);
      const orderedIds = [
        ...idsFor("doing"),
        ...idsFor("todo"),
        ...idsFor("done"),
      ];
      const orderedTodos = orderedIds
        .map((id, index) => {
          const todo = byId.get(id);
          return todo ? { ...todo, sort_order: index } : null;
        })
        .filter((todo): todo is TodoView => todo !== null);

      setTodos(projectId, orderedTodos);
      reorderTodos(projectId, orderedIds).catch((error) => {
        onError(String(error));
        refresh();
      });
    },
    [onError, projectId, refresh, setTodos, todos],
  );

  const handlePointerDown = useCallback(
    (event: ReactPointerEvent<HTMLElement>, todo: TodoView) => {
      if (event.button !== 0 || !ACTIVE_STATUSES.includes(todo.status as TodoStatus)) {
        return;
      }
      dragRef.current = {
        id: todo.id,
        pointerId: event.pointerId,
        startX: event.clientX,
        startY: event.clientY,
        active: false,
      };
      event.currentTarget.setPointerCapture?.(event.pointerId);
    },
    [],
  );

  const onPointerMove = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      if (!drag.active) {
        if (Math.hypot(event.clientX - drag.startX, event.clientY - drag.startY) < 4) {
          return;
        }
        drag.active = true;
        setDragId(drag.id);
      }
      event.preventDefault();

      const target = document
        .elementFromPoint(event.clientX, event.clientY)
        ?.closest<HTMLElement>("[data-todo-reorder-id]");
      const targetId = target?.dataset.todoReorderId;
      const dragged = todos.find((todo) => todo.id === drag.id);
      const targetTodo = todos.find((todo) => todo.id === targetId);
      if (
        !target ||
        !targetId ||
        targetId === drag.id ||
        !dragged ||
        !targetTodo ||
        dragged.status !== targetTodo.status
      ) {
        dropTargetRef.current = null;
        setDropTarget(null);
        return;
      }

      const rect = target.getBoundingClientRect();
      const edge: DropEdge =
        event.clientY < rect.top + rect.height / 2 ? "before" : "after";
      const next = { id: targetId, edge };
      const current = dropTargetRef.current;
      if (current?.id !== next.id || current.edge !== next.edge) {
        dropTargetRef.current = next;
        setDropTarget(next);
      }
    },
    [todos],
  );

  const onPointerUp = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      const target = dropTargetRef.current;
      if (drag.active) {
        suppressClickRef.current = true;
        requestAnimationFrame(() => {
          suppressClickRef.current = false;
        });
      }
      clearDrag();
      if (drag.active && target) commitReorder(drag.id, target.id, target.edge);
    },
    [clearDrag, commitReorder],
  );

  const onPointerCancel = useCallback(
    (event: ReactPointerEvent<HTMLElement>) => {
      const drag = dragRef.current;
      if (!drag || drag.pointerId !== event.pointerId) return;
      clearDrag();
    },
    [clearDrag],
  );

  const consumeSuppressedClick = useCallback(() => {
    if (!suppressClickRef.current) return false;
    suppressClickRef.current = false;
    return true;
  }, []);

  return {
    dragId,
    dropTarget,
    containerHandlers: { onPointerMove, onPointerUp, onPointerCancel },
    handlePointerDown,
    consumeSuppressedClick,
  };
}
