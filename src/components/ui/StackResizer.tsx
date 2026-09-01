import { useCallback, useRef } from "react";

/// 右栏堆叠卡片之间的横向拖拽手柄(Claude Desktop 式:平时几乎不可见,
/// hover / 拖拽时浮出居中短胶囊)。
///
/// 不经过布局库:卡片是 `flex: 1 1 0` 的兄弟节点,拖拽时直接把两侧
/// 相邻的可见卡片高度换算成 flex-grow 权重写到行内样式上。不持久化 ——
/// 卡片组合本身随开关变化,记住一套比例对下一次组合未必有意义。
export function StackResizer() {
  const ref = useRef<HTMLDivElement | null>(null);

  const onPointerDown = useCallback((e: React.PointerEvent<HTMLDivElement>) => {
    const handle = ref.current;
    if (!handle) return;
    // 相邻的可见卡片:向前 / 向后跳过 hidden 与其他 resizer。
    const visibleCard = (
      start: Element | null,
      dir: "previous" | "next",
    ): HTMLElement | null => {
      let el = start;
      while (el) {
        if (
          el instanceof HTMLElement &&
          el.classList.contains("panel-card") &&
          !el.hidden
        ) {
          return el;
        }
        el = dir === "previous" ? el.previousElementSibling : el.nextElementSibling;
      }
      return null;
    };
    const prev = visibleCard(handle.previousElementSibling, "previous");
    const next = visibleCard(handle.nextElementSibling, "next");
    if (!prev || !next) return;

    e.preventDefault();
    handle.setPointerCapture(e.pointerId);
    handle.dataset.active = "true";
    const startY = e.clientY;
    const prevH = prev.getBoundingClientRect().height;
    const nextH = next.getBoundingClientRect().height;
    const total = prevH + nextH;
    const min = 100; // 每张卡至少保住 header + 一点内容

    const onMove = (ev: PointerEvent) => {
      const delta = Math.max(
        min - prevH,
        Math.min(nextH - min, ev.clientY - startY),
      );
      const p = prevH + delta;
      const n = nextH - delta;
      // flex-grow 是无量纲权重,按占比写;basis 归零让权重完全说了算。
      prev.style.flex = `${(p / total) * 2} 1 0`;
      next.style.flex = `${(n / total) * 2} 1 0`;
    };
    const onUp = () => {
      handle.releasePointerCapture(e.pointerId);
      delete handle.dataset.active;
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
  }, []);

  return (
    <div
      ref={ref}
      className="stack-resizer"
      role="separator"
      aria-orientation="horizontal"
      aria-label="调整面板高度"
      onPointerDown={onPointerDown}
    />
  );
}
