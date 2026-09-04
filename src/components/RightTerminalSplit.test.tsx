import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SplitContextMenu } from "./RightTerminalSplit";

afterEach(cleanup);

function renderMenu(canClose = true) {
  const onDismiss = vi.fn();
  const onPick = vi.fn();
  render(
    <SplitContextMenu
      x={100}
      y={100}
      canClose={canClose}
      onDismiss={onDismiss}
      onPick={onPick}
    />,
  );
  return { onDismiss, onPick };
}

describe("SplitContextMenu", () => {
  // 这个菜单的失效方式是「点了完全没反应」,肉眼很难归因。
  //
  // 外部点击守卫用 `target.closest(".split-menu")` 区分菜单内外,监听挂在
  // capture 阶段的 mousedown 上(要抢在 xterm 抢焦点之前)。类名一丢,菜单
  // 内的 mousedown 也会被判成「点在外面」→ onDismiss → 菜单卸载 → 后续的
  // click 落在一个已经不存在的按钮上。Tailwind 迁移时正是这样把类名换掉
  // 而守卫留着,五个动作一起变成哑弹。
  it("keeps its actions clickable — the outside-click guard must recognise itself", async () => {
    const user = userEvent.setup();
    const { onDismiss, onPick } = renderMenu();

    await user.click(screen.getByRole("menuitem", { name: "向右分屏" }));

    expect(onPick).toHaveBeenCalledWith("right");
    expect(onDismiss).not.toHaveBeenCalled();
  });

  it("dismisses when the click lands outside", async () => {
    const user = userEvent.setup();
    const { onDismiss, onPick } = renderMenu();

    await user.click(document.body);

    expect(onDismiss).toHaveBeenCalled();
    expect(onPick).not.toHaveBeenCalled();
  });

  it("offers every split direction, plus close when the pane can be closed", () => {
    renderMenu(true);
    for (const label of ["向右分屏", "向左分屏", "向下分屏", "向上分屏"]) {
      expect(screen.getByRole("menuitem", { name: label })).toBeInTheDocument();
    }
    expect(screen.getByRole("menuitem", { name: /关闭/ })).toBeInTheDocument();
  });

  it("hides the close action for the last remaining pane", () => {
    renderMenu(false);
    expect(screen.queryByRole("menuitem", { name: /关闭/ })).toBeNull();
  });
});
