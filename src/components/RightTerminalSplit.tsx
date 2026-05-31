// Recursive binary-split terminal host for the right pane. Each leaf owns one
// ManualTerminal (= one PTY); each internal split node has a draggable gutter.
// Tree state lives in RightPane and is keyed by project id, so switching
// projects preserves the layout. Reloading the app reverts to a single pane —
// in-memory only, by design.
//
// Rendering is intentionally FLAT, not recursive: the tree is walked once to
// compute leaf/gutter rectangles in % of the host, and React sees a stable
// flat list keyed by paneId. This matters when closing a pane — if rendering
// were recursive, the SplitNode wrapper around a surviving leaf would change
// return type (split → leaf), forcing React to unmount the child
// TerminalPaneCard and kill its PTY. With the flat approach, closing a pane
// just removes one entry from the leaves array; every other leaf's React
// identity is preserved and its shell keeps running.
//
// All panes spawn in the project root (the cwd prop is fixed for the host's
// lifetime), so new panes inherit the project shell directory without any
// cwd-tracking logic.

import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { ManualTerminal } from "./ManualTerminal";

export type SplitOrientation = "horizontal" | "vertical";
export type SplitDirection = "left" | "right" | "up" | "down";
export type SplitPath = Array<"first" | "second">;

export type SplitTree =
  | { kind: "leaf"; paneId: string }
  | {
      kind: "split";
      orientation: SplitOrientation;
      ratio: number; // 0..1, fraction occupied by `first`
      first: SplitTree;
      second: SplitTree;
    };

export interface ProjectSplitState {
  tree: SplitTree;
  nextPaneId: number;
}

export function newSplitState(): ProjectSplitState {
  return {
    tree: { kind: "leaf", paneId: "pane-1" },
    nextPaneId: 2,
  };
}

export function splitPane(
  state: ProjectSplitState,
  targetPaneId: string,
  direction: SplitDirection,
): ProjectSplitState {
  const newPaneId = `pane-${state.nextPaneId}`;
  const orientation: SplitOrientation =
    direction === "left" || direction === "right" ? "vertical" : "horizontal";
  // "Split Right/Down": new pane becomes SECOND (right or below).
  // "Split Left/Up":    new pane becomes FIRST  (left or above).
  const newIsFirst = direction === "left" || direction === "up";
  const fresh: SplitTree = { kind: "leaf", paneId: newPaneId };

  const replace = (node: SplitTree): SplitTree => {
    if (node.kind === "leaf") {
      if (node.paneId !== targetPaneId) return node;
      return {
        kind: "split",
        orientation,
        ratio: 0.5,
        first: newIsFirst ? fresh : node,
        second: newIsFirst ? node : fresh,
      };
    }
    return {
      ...node,
      first: replace(node.first),
      second: replace(node.second),
    };
  };
  return {
    tree: replace(state.tree),
    nextPaneId: state.nextPaneId + 1,
  };
}

// Remove the target leaf; the surviving sibling takes its slot. The root leaf
// is never removed — the host always shows at least one shell.
export function closePane(
  state: ProjectSplitState,
  targetPaneId: string,
): ProjectSplitState {
  if (state.tree.kind === "leaf") return state;

  const remove = (node: SplitTree): SplitTree | null => {
    if (node.kind === "leaf") {
      return node.paneId === targetPaneId ? null : node;
    }
    const first = remove(node.first);
    const second = remove(node.second);
    if (first === null && second === null) return null;
    if (first === null) return second;
    if (second === null) return first;
    if (first === node.first && second === node.second) return node;
    return { ...node, first, second };
  };

  const newTree = remove(state.tree);
  return { ...state, tree: newTree ?? state.tree };
}

export function updateRatio(
  state: ProjectSplitState,
  path: SplitPath,
  newRatio: number,
): ProjectSplitState {
  const update = (node: SplitTree, idx: number): SplitTree => {
    if (node.kind !== "split") return node;
    if (idx === path.length) {
      return { ...node, ratio: newRatio };
    }
    const branch = path[idx];
    return {
      ...node,
      first: branch === "first" ? update(node.first, idx + 1) : node.first,
      second: branch === "second" ? update(node.second, idx + 1) : node.second,
    };
  };
  return { ...state, tree: update(state.tree, 0) };
}

// ── Layout ───────────────────────────────────────────────────────────────

interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

interface LeafLayout {
  paneId: string;
  rect: Rect; // % of host
}

interface GutterLayout {
  axis: SplitOrientation;
  rect: Rect;        // visible gutter rect in % of host (zero w or h on its axis)
  subtreeRect: Rect; // enclosing split's container — needed for ratio math
  path: SplitPath;
}

interface Layout {
  leaves: LeafLayout[];
  gutters: GutterLayout[];
}

function layoutTree(node: SplitTree, rect: Rect, path: SplitPath): Layout {
  if (node.kind === "leaf") {
    return { leaves: [{ paneId: node.paneId, rect }], gutters: [] };
  }
  if (node.orientation === "vertical") {
    const firstW = rect.w * node.ratio;
    const firstRect: Rect = { x: rect.x, y: rect.y, w: firstW, h: rect.h };
    const secondRect: Rect = {
      x: rect.x + firstW,
      y: rect.y,
      w: rect.w - firstW,
      h: rect.h,
    };
    const gutter: GutterLayout = {
      axis: "vertical",
      rect: { x: rect.x + firstW, y: rect.y, w: 0, h: rect.h },
      subtreeRect: rect,
      path,
    };
    const first = layoutTree(node.first, firstRect, [...path, "first"]);
    const second = layoutTree(node.second, secondRect, [...path, "second"]);
    return {
      leaves: [...first.leaves, ...second.leaves],
      gutters: [gutter, ...first.gutters, ...second.gutters],
    };
  }
  const firstH = rect.h * node.ratio;
  const firstRect: Rect = { x: rect.x, y: rect.y, w: rect.w, h: firstH };
  const secondRect: Rect = {
    x: rect.x,
    y: rect.y + firstH,
    w: rect.w,
    h: rect.h - firstH,
  };
  const gutter: GutterLayout = {
    axis: "horizontal",
    rect: { x: rect.x, y: rect.y + firstH, w: rect.w, h: 0 },
    subtreeRect: rect,
    path,
  };
  const first = layoutTree(node.first, firstRect, [...path, "first"]);
  const second = layoutTree(node.second, secondRect, [...path, "second"]);
  return {
    leaves: [...first.leaves, ...second.leaves],
    gutters: [gutter, ...first.gutters, ...second.gutters],
  };
}

// ── Component ────────────────────────────────────────────────────────────

interface RightTerminalSplitProps {
  tree: SplitTree;
  cwd: string;
  projectId: string;
  visible: boolean;
  onSplit: (paneId: string, direction: SplitDirection) => void;
  onClose: (paneId: string) => void;
  onUpdateRatio: (path: SplitPath, ratio: number) => void;
}

export function RightTerminalSplit(props: RightTerminalSplitProps) {
  const hostRef = useRef<HTMLDivElement | null>(null);
  const layout = useMemo(
    () => layoutTree(props.tree, { x: 0, y: 0, w: 100, h: 100 }, []),
    [props.tree],
  );
  const hasMultiplePanes = layout.leaves.length > 1;

  function startGutterDrag(e: React.PointerEvent, g: GutterLayout) {
    e.preventDefault();
    const host = hostRef.current;
    if (!host) return;
    const hostRect = host.getBoundingClientRect();
    // Subtree rect in pixels — pointer math is relative to the split's
    // container, not the whole host, so nested drags compute correctly.
    const subX = hostRect.left + (g.subtreeRect.x / 100) * hostRect.width;
    const subY = hostRect.top + (g.subtreeRect.y / 100) * hostRect.height;
    const subW = (g.subtreeRect.w / 100) * hostRect.width;
    const subH = (g.subtreeRect.h / 100) * hostRect.height;

    const onMove = (ev: PointerEvent) => {
      const raw =
        g.axis === "vertical"
          ? (ev.clientX - subX) / subW
          : (ev.clientY - subY) / subH;
      // Soft clamp so panes don't collapse to zero.
      const clamped = Math.max(0.1, Math.min(0.9, raw));
      props.onUpdateRatio(g.path, clamped);
    };
    const onUp = () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    document.body.style.cursor =
      g.axis === "vertical" ? "col-resize" : "row-resize";
    document.body.style.userSelect = "none";
  }

  return (
    <div ref={hostRef} className="split-host">
      {layout.leaves.map((leaf) => (
        <TerminalPaneCard
          key={leaf.paneId}
          paneId={leaf.paneId}
          cwd={props.cwd}
          projectId={props.projectId}
          visible={props.visible}
          canClose={hasMultiplePanes}
          rect={leaf.rect}
          onSplit={props.onSplit}
          onClose={props.onClose}
        />
      ))}
      {layout.gutters.map((g) => {
        const style: React.CSSProperties =
          g.axis === "vertical"
            ? {
                left: `${g.rect.x}%`,
                top: `${g.rect.y}%`,
                height: `${g.rect.h}%`,
              }
            : {
                top: `${g.rect.y}%`,
                left: `${g.rect.x}%`,
                width: `${g.rect.w}%`,
              };
        return (
          <div
            key={`g-${g.axis}-${g.path.join("/")}`}
            className={`split-gutter split-gutter-${g.axis}`}
            style={style}
            onPointerDown={(e) => startGutterDrag(e, g)}
            role="separator"
            aria-orientation={
              g.axis === "vertical" ? "vertical" : "horizontal"
            }
          />
        );
      })}
    </div>
  );
}

interface TerminalPaneCardProps {
  paneId: string;
  cwd: string;
  projectId: string;
  visible: boolean;
  canClose: boolean;
  rect: Rect;
  onSplit: (paneId: string, direction: SplitDirection) => void;
  onClose: (paneId: string) => void;
}

function TerminalPaneCard(props: TerminalPaneCardProps) {
  const [menu, setMenu] = useState<{ x: number; y: number } | null>(null);

  function handleContextMenu(e: React.MouseEvent) {
    e.preventDefault();
    e.stopPropagation();
    setMenu({ x: e.clientX, y: e.clientY });
  }

  const style: React.CSSProperties = {
    left: `${props.rect.x}%`,
    top: `${props.rect.y}%`,
    width: `${props.rect.w}%`,
    height: `${props.rect.h}%`,
  };

  return (
    <div
      className={
        "terminal-pane-card" + (props.canClose ? " with-header" : "")
      }
      style={style}
      onContextMenu={handleContextMenu}
    >
      {props.canClose && (
        <header className="terminal-pane-card-header">
          <button
            type="button"
            className="pane-close"
            onClick={(e) => {
              e.stopPropagation();
              props.onClose(props.paneId);
            }}
            aria-label="Close pane"
            title="Close pane (shell stops)"
          >
            ×
          </button>
        </header>
      )}
      <div className="terminal-pane-card-body">
        <ManualTerminal
          cwd={props.cwd}
          projectId={props.projectId}
          visible={props.visible}
        />
      </div>
      {menu && (
        <SplitContextMenu
          x={menu.x}
          y={menu.y}
          canClose={props.canClose}
          onDismiss={() => setMenu(null)}
          onPick={(action) => {
            setMenu(null);
            if (action === "close") props.onClose(props.paneId);
            else props.onSplit(props.paneId, action);
          }}
        />
      )}
    </div>
  );
}

const MENU_WIDTH = 188;
const MENU_HEIGHT_BASE = 8 + 4 * 32;
const MENU_HEIGHT_WITH_CLOSE = MENU_HEIGHT_BASE + 9 + 32;

interface SplitContextMenuProps {
  x: number;
  y: number;
  canClose: boolean;
  onDismiss: () => void;
  onPick: (action: SplitDirection | "close") => void;
}

function SplitContextMenu(props: SplitContextMenuProps) {
  // Dismiss on outside click (capture-phase, beats xterm's focus grab on
  // mousedown), Escape, or window blur.
  useEffect(() => {
    function onMouseDown(ev: MouseEvent) {
      const target = ev.target as HTMLElement | null;
      if (target && target.closest(".split-menu")) return;
      props.onDismiss();
    }
    function onKey(ev: KeyboardEvent) {
      if (ev.key === "Escape") props.onDismiss();
    }
    function onBlur() {
      props.onDismiss();
    }
    window.addEventListener("mousedown", onMouseDown, true);
    window.addEventListener("keydown", onKey);
    window.addEventListener("blur", onBlur);
    return () => {
      window.removeEventListener("mousedown", onMouseDown, true);
      window.removeEventListener("keydown", onKey);
      window.removeEventListener("blur", onBlur);
    };
  }, [props]);

  const menuHeight = props.canClose ? MENU_HEIGHT_WITH_CLOSE : MENU_HEIGHT_BASE;
  const left = Math.min(props.x, window.innerWidth - MENU_WIDTH - 8);
  const top = Math.min(props.y, window.innerHeight - menuHeight - 8);

  return createPortal(
    <div
      className="split-menu"
      style={{ left: Math.max(8, left), top: Math.max(8, top) }}
      role="menu"
    >
      <button
        type="button"
        role="menuitem"
        onClick={() => props.onPick("right")}
      >
        <SplitIcon direction="right" />
        <span>Split Right</span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => props.onPick("left")}
      >
        <SplitIcon direction="left" />
        <span>Split Left</span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => props.onPick("down")}
      >
        <SplitIcon direction="down" />
        <span>Split Down</span>
      </button>
      <button
        type="button"
        role="menuitem"
        onClick={() => props.onPick("up")}
      >
        <SplitIcon direction="up" />
        <span>Split Up</span>
      </button>
      {props.canClose && (
        <>
          <div className="split-menu-sep" />
          <button
            type="button"
            role="menuitem"
            className="split-menu-danger"
            onClick={() => props.onPick("close")}
          >
            <CloseIcon />
            <span>Close Pane</span>
          </button>
        </>
      )}
    </div>,
    document.body,
  );
}

function SplitIcon({ direction }: { direction: SplitDirection }) {
  // 18×14 outer rect; one filled half indicates where the NEW pane will land.
  const outer = { x: 1, y: 2, w: 16, h: 12 };
  let filled: { x: number; y: number; w: number; h: number };
  switch (direction) {
    case "right":
      filled = { x: 10, y: 3, w: 6, h: 10 };
      break;
    case "left":
      filled = { x: 2, y: 3, w: 6, h: 10 };
      break;
    case "down":
      filled = { x: 2, y: 9, w: 14, h: 4 };
      break;
    case "up":
      filled = { x: 2, y: 3, w: 14, h: 4 };
      break;
  }
  return (
    <svg
      width="18"
      height="16"
      viewBox="0 0 18 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.4"
      aria-hidden
    >
      <rect
        x={outer.x}
        y={outer.y}
        width={outer.w}
        height={outer.h}
        rx="1.5"
      />
      <rect
        x={filled.x}
        y={filled.y}
        width={filled.w}
        height={filled.h}
        rx="1"
        fill="currentColor"
        stroke="none"
      />
    </svg>
  );
}

function CloseIcon() {
  return (
    <svg
      width="18"
      height="16"
      viewBox="0 0 18 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M5 4l8 8M13 4l-8 8" />
    </svg>
  );
}
