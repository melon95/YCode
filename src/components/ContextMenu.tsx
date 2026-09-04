// Minimal right-click context menu. Pointer-down anywhere outside or any
// scroll/resize event closes it — there's no submenu support, no keyboard
// nav, no portal-into-body trickery beyond a fixed-position div. Add more
// only when something actually needs it.

import { useEffect, useRef } from "react";
import { useEscapeGuard } from "../lib/useEscapeGuard";

export interface ContextMenuItem {
  label: string;
  onSelect: () => void;
  disabled?: boolean;
}

export function ContextMenu({
  x,
  y,
  items,
  onClose,
}: {
  x: number;
  y: number;
  items: ContextMenuItem[];
  onClose: () => void;
}) {
  const ref = useRef<HTMLUListElement>(null);

  // Escape via the shared guard (dismiss-only, no fullscreen exit).
  useEscapeGuard(onClose);

  useEffect(() => {
    const onDown = (e: PointerEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    const onAway = () => onClose();
    window.addEventListener("pointerdown", onDown, true);
    window.addEventListener("scroll", onAway, true);
    window.addEventListener("resize", onAway);
    window.addEventListener("blur", onAway);
    return () => {
      window.removeEventListener("pointerdown", onDown, true);
      window.removeEventListener("scroll", onAway, true);
      window.removeEventListener("resize", onAway);
      window.removeEventListener("blur", onAway);
    };
  }, [onClose]);

  return (
    <ul
      ref={ref}
      className="fixed z-1000 min-w-[180px] p-1 m-0 list-none bg-panel
        border border-rule-strong rounded-md shadow-menu text-[13px]"
      style={{ left: x, top: y }}
      role="menu"
    >
      {items.map((it) => (
        <li key={it.label} role="none">
          <button
            type="button"
            role="menuitem"
            className="w-full flex items-center min-h-[30px] py-1.5 px-2.5
              bg-transparent border-0 rounded-sm text-[inherit] font-[inherit] text-left cursor-pointer
              not-disabled:hover:bg-control-hover
              disabled:opacity-40 disabled:cursor-not-allowed"
            disabled={it.disabled}
            onClick={() => {
              if (it.disabled) return;
              it.onSelect();
              onClose();
            }}
          >
            {it.label}
          </button>
        </li>
      ))}
    </ul>
  );
}
