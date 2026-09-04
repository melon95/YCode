// Visual grid for picking an `AgentIcon` whitelist key. The first tile is
// a "None" option that clears the selection (renders the placeholder
// letter-avatar in consumers). Selected tile gets an accent border.

import { useMemo } from "react";
import { AgentIcon, REGISTRY } from "./AgentIcon";

interface Props {
  value: string | null | undefined;
  onChange: (icon: string | null) => void;
}

const TILE = `flex flex-col items-center justify-center gap-1.5 py-2.5 px-1
  bg-transparent border border-transparent rounded-none cursor-pointer
  text-text-soft min-h-[60px] font-mono text-[9px] tracking-normal
  transition-[color,border-color,background-color] duration-[var(--duration-fast)] ease-out
  hover:text-text hover:bg-accent-wash`.replace(/\s+/g, " ");

const TILE_ON = "border-accent bg-accent-tint text-accent";

const LABEL =
  "text-[10px] text-center max-w-full overflow-hidden text-ellipsis whitespace-nowrap";

export function IconPicker({ value, onChange }: Props) {
  // Stable key list so the grid order doesn't shift between renders.
  const names = useMemo(() => Object.keys(REGISTRY).sort(), []);
  return (
    <div className="grid grid-cols-[repeat(auto-fill,minmax(72px,1fr))] gap-1 max-h-[260px] overflow-y-auto p-2.5 bg-panel-sunken border border-rule rounded-none">
      <button
        type="button"
        className={`${TILE} ${value == null ? TILE_ON : ""}`}
        onClick={() => onChange(null)}
        title="No icon (use letter placeholder)"
      >
        <span
          className="text-[18px] text-muted size-6 inline-flex items-center justify-center"
          aria-hidden
        >
          —
        </span>
        <span className={`${LABEL} ${value == null ? "text-text" : "text-muted"}`}>
          None
        </span>
      </button>
      {names.map((name) => (
        <button
          key={name}
          type="button"
          className={`${TILE} ${value === name ? TILE_ON : ""}`}
          onClick={() => onChange(name)}
          title={name}
        >
          <AgentIcon icon={name} size={24} />
          <span
            className={`${LABEL} ${value === name ? "text-text" : "text-muted"}`}
          >
            {name}
          </span>
        </button>
      ))}
    </div>
  );
}
