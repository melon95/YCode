// Visual grid for picking an `AgentIcon` whitelist key. The first tile is
// a "None" option that clears the selection (renders the placeholder
// letter-avatar in consumers). Selected tile gets an accent border.

import { useMemo } from "react";
import { AgentIcon, REGISTRY } from "./AgentIcon";

interface Props {
  value: string | null | undefined;
  onChange: (icon: string | null) => void;
}

export function IconPicker({ value, onChange }: Props) {
  // Stable key list so the grid order doesn't shift between renders.
  const names = useMemo(() => Object.keys(REGISTRY).sort(), []);
  return (
    <div className="icon-picker">
      <button
        type="button"
        className={
          "icon-picker-tile icon-picker-none" +
          (value == null ? " selected" : "")
        }
        onClick={() => onChange(null)}
        title="No icon (use letter placeholder)"
      >
        <span className="icon-picker-none-mark" aria-hidden>
          —
        </span>
        <span className="icon-picker-label">None</span>
      </button>
      {names.map((name) => (
        <button
          key={name}
          type="button"
          className={
            "icon-picker-tile" + (value === name ? " selected" : "")
          }
          onClick={() => onChange(name)}
          title={name}
        >
          <AgentIcon icon={name} size={24} />
          <span className="icon-picker-label">{name}</span>
        </button>
      ))}
    </div>
  );
}
