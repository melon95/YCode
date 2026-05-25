// Layout chooser shown in the top bar. Hidden when only 0/1 panes are
// visible (nothing to switch between); otherwise lists the valid presets
// for the current pane count. The currently-active mode is highlighted.

import { useEffect, useRef, useState } from "react";
import {
  defaultLayoutMode,
  useStore,
  validLayoutModes,
  type LayoutMode,
} from "../lib/store";

const LABELS: Record<LayoutMode, string> = {
  single: "Single",
  stack: "Stack",
  columns: "Columns",
  grid2x2: "Grid 2×2",
  "main-side": "Main + Side",
};

export function LayoutSwitcher() {
  const mode = useStore((s) => s.layout.mode);
  const count = useStore((s) => s.layout.visibleIds.length);
  const setLayoutMode = useStore((s) => s.setLayoutMode);

  const [open, setOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);

  // Click-outside to close.
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (!rootRef.current) return;
      if (!rootRef.current.contains(e.target as Node)) setOpen(false);
    };
    window.addEventListener("mousedown", onClick);
    return () => window.removeEventListener("mousedown", onClick);
  }, [open]);

  // Nothing to switch when there's at most one pane.
  if (count <= 1) return null;

  const valid = validLayoutModes(count);
  // The active mode might be stale if count just shrunk and the reducer
  // hasn't reflowed yet (shouldn't happen, but render defensively).
  const activeMode = valid.includes(mode) ? mode : defaultLayoutMode(count);

  return (
    <div className="layout-switcher" ref={rootRef}>
      <button
        type="button"
        className="layout-switcher-trigger"
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        title={`Layout: ${LABELS[activeMode]}`}
      >
        <LayoutIcon mode={activeMode} />
        <span className="layout-switcher-label">{LABELS[activeMode]}</span>
        <span className="layout-switcher-caret" aria-hidden>▾</span>
      </button>
      {open && (
        <div className="layout-popover" role="menu">
          {valid.map((m) => {
            const active = m === activeMode;
            return (
              <button
                key={m}
                type="button"
                role="menuitemradio"
                aria-checked={active}
                className={"layout-option" + (active ? " active" : "")}
                onClick={() => {
                  setLayoutMode(m);
                  setOpen(false);
                }}
              >
                <LayoutIcon mode={m} large />
                <span className="layout-option-label">{LABELS[m]}</span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

// Canonical-form preview of a mode, regardless of the current pane count
// (e.g. `stack` always shows 3 strips). The first cell is rendered with
// full opacity to evoke the "main" slot in main+side.
function LayoutIcon({ mode, large }: { mode: LayoutMode; large?: boolean }) {
  const w = large ? 36 : 22;
  const h = large ? 24 : 16;
  const cells = iconCells(mode, w, h);
  return (
    <svg
      width={w}
      height={h}
      viewBox={`0 0 ${w} ${h}`}
      className="layout-icon"
      aria-hidden
    >
      {cells.map((c, i) => (
        <rect
          key={i}
          x={c.x}
          y={c.y}
          width={c.w}
          height={c.h}
          rx="1.5"
          fill="currentColor"
          opacity={i === 0 ? 0.95 : 0.45}
        />
      ))}
    </svg>
  );
}

interface Cell {
  x: number;
  y: number;
  w: number;
  h: number;
}

function iconCells(mode: LayoutMode, w: number, h: number): Cell[] {
  const m = 1; // outer margin
  const g = 1.5; // gap between cells
  const W = w - m * 2;
  const H = h - m * 2;
  switch (mode) {
    case "single":
      return [{ x: m, y: m, w: W, h: H }];
    case "stack": {
      const n = 3;
      const cellH = (H - g * (n - 1)) / n;
      return Array.from({ length: n }, (_, i) => ({
        x: m,
        y: m + i * (cellH + g),
        w: W,
        h: cellH,
      }));
    }
    case "columns": {
      const n = 3;
      const cellW = (W - g * (n - 1)) / n;
      return Array.from({ length: n }, (_, i) => ({
        x: m + i * (cellW + g),
        y: m,
        w: cellW,
        h: H,
      }));
    }
    case "grid2x2": {
      const cellW = (W - g) / 2;
      const cellH = (H - g) / 2;
      return [
        { x: m, y: m, w: cellW, h: cellH },
        { x: m + cellW + g, y: m, w: cellW, h: cellH },
        { x: m, y: m + cellH + g, w: cellW, h: cellH },
        { x: m + cellW + g, y: m + cellH + g, w: cellW, h: cellH },
      ];
    }
    case "main-side": {
      const mainW = W * 0.6 - g / 2;
      const sideW = W * 0.4 - g / 2;
      const sideH = (H - g * 2) / 3;
      return [
        { x: m, y: m, w: mainW, h: H },
        { x: m + mainW + g, y: m, w: sideW, h: sideH },
        { x: m + mainW + g, y: m + sideH + g, w: sideW, h: sideH },
        { x: m + mainW + g, y: m + (sideH + g) * 2, w: sideW, h: sideH },
      ];
    }
  }
}
