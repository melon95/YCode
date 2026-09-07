import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { i18next } from "../lib/i18n";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import {
  createTodo,
  deleteTodo,
  listTodos,
  reorderTodos,
  updateTodo,
} from "../lib/ipc";
import { useStore } from "../lib/store";
import type { TodoView } from "../lib/types";
import { TodoPanel } from "./TodoPanel";

vi.mock("../lib/ipc", () => ({
  createTodo: vi.fn(),
  deleteTodo: vi.fn(),
  listTodos: vi.fn(),
  reorderTodos: vi.fn(),
  updateTodo: vi.fn(),
}));

const now = Date.now();
const fixtures: TodoView[] = [
  {
    id: "active-1",
    project_id: "project-a",
    title: "Polish task workflow",
    status: "doing",
    sort_order: 0,
    started_at_ms: now - 2 * 60 * 60 * 1000,
    done_at_ms: null,
    created_at_ms: now - 24 * 60 * 60 * 1000,
    updated_at_ms: now - 2 * 60 * 60 * 1000,
  },
  {
    id: "queued-1",
    project_id: "project-a",
    title: "Review responsive layout",
    status: "todo",
    sort_order: 1,
    started_at_ms: null,
    done_at_ms: null,
    created_at_ms: now - 30 * 60 * 1000,
    updated_at_ms: now - 30 * 60 * 1000,
  },
  {
    id: "done-1",
    project_id: "project-a",
    title: "Unify workspace target",
    status: "done",
    sort_order: 2,
    started_at_ms: now - 48 * 60 * 60 * 1000,
    done_at_ms: now - 20 * 60 * 60 * 1000,
    created_at_ms: now - 72 * 60 * 60 * 1000,
    updated_at_ms: now - 20 * 60 * 60 * 1000,
  },
];

const initialState = useStore.getState();

describe("TodoPanel task flow", () => {
  beforeEach(() => {
    vi.clearAllMocks();
    localStorage.clear();
    useStore.setState(initialState, true);
    vi.mocked(listTodos).mockResolvedValue(fixtures);
    vi.mocked(createTodo).mockResolvedValue(fixtures[1]);
    vi.mocked(updateTodo).mockResolvedValue(fixtures[0]);
    vi.mocked(deleteTodo).mockResolvedValue();
    vi.mocked(reorderTodos).mockResolvedValue();
  });

  afterEach(cleanup);

  it("renders real task counts, groups, and status timing", async () => {
    render(<TodoPanel projectId="project-a" />);

    expect(await screen.findByText("Polish task workflow")).toBeInTheDocument();
    // 三格各一条:进行中 / 排队中 / 已完成。拼词条而不是写死字面量 ——
    // 这条断言要验的是计数,不是某种语言的措辞。
    expect(screen.getByLabelText(i18next.t("todo.overviewAria"))).toHaveTextContent(
      `1${i18next.t("todo.doing")}1${i18next.t("todo.queued")}1${i18next.t("todo.done")}`,
    );
    // 「进行中」同时出现在概览、分组标题和状态标签里,只需确认存在。
    expect(screen.getAllByText(i18next.t("todo.doing")).length).toBeGreaterThan(0);
    expect(screen.getByText(i18next.t("todo.queue"))).toBeInTheDocument();
    expect(
      screen.getByText(
        `${i18next.t("todo.verbStarted")} ${i18next.t("time.hoursAgo", { count: 2 })}`,
      ),
    ).toBeInTheDocument();
    expect(
      screen.getByText(
        `${i18next.t("todo.verbAdded")} ${i18next.t("time.minutesAgo", { count: 30 })}`,
      ),
    ).toBeInTheDocument();
  });

  it("adds a task through the capture field", async () => {
    const user = userEvent.setup();
    render(<TodoPanel projectId="project-a" />);

    const input = await screen.findByRole("textbox", { name: i18next.t("todo.newAria") });
    await user.type(input, "  Ship the task panel  ");
    await user.keyboard("{Enter}");

    await waitFor(() =>
      expect(createTodo).toHaveBeenCalledWith(
        "project-a",
        "Ship the task panel",
      ),
    );
    expect(input).toHaveValue("");
  });

  it("keeps completion an explicit checkbox action", async () => {
    const user = userEvent.setup();
    render(<TodoPanel projectId="project-a" />);

    const completeButtons = await screen.findAllByRole("button", {
      name: i18next.t("todo.doneToggleOff"),
    });
    await user.click(completeButtons[0]);

    await waitFor(() =>
      expect(updateTodo).toHaveBeenCalledWith("active-1", { status: "done" }),
    );
  });

  it("reorders active todos with pointer events", async () => {
    const secondActive: TodoView = {
      ...fixtures[0],
      id: "active-2",
      title: "Run desktop verification",
      sort_order: 1,
    };
    vi.mocked(listTodos).mockResolvedValue([
      fixtures[0],
      secondActive,
      { ...fixtures[1], sort_order: 2 },
      { ...fixtures[2], sort_order: 3 },
    ]);
    render(<TodoPanel projectId="project-a" />);

    const sourceTitle = await screen.findByText("Polish task workflow");
    const targetTitle = screen.getByText("Run desktop verification");
    const source = sourceTitle.closest(".todo-item");
    const target = targetTitle.closest(".todo-item");
    const handle = source?.querySelector(".todo-drag-handle");
    expect(source).not.toBeNull();
    expect(target).not.toBeNull();
    expect(handle).not.toBeNull();
    Object.defineProperty(target, "getBoundingClientRect", {
      value: () => ({ top: 0, height: 100 }),
    });
    const originalElementFromPoint = document.elementFromPoint;
    document.elementFromPoint = vi.fn(() => target);

    fireEvent.pointerDown(handle!, {
      button: 0,
      pointerId: 1,
      clientX: 10,
      clientY: 10,
    });
    fireEvent.pointerMove(handle!, { pointerId: 1, clientX: 10, clientY: 80 });
    fireEvent.pointerUp(handle!, { pointerId: 1, clientX: 10, clientY: 80 });
    document.elementFromPoint = originalElementFromPoint;

    await waitFor(() =>
      expect(reorderTodos).toHaveBeenCalledWith("project-a", [
        "active-2",
        "active-1",
        "queued-1",
        "done-1",
      ]),
    );
    expect(updateTodo).not.toHaveBeenCalled();
  });
});
