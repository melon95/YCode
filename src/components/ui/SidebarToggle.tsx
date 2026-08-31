// The show/hide-sidebar control.
//
// It renders in two places, but never both at once: at the head of the
// sidebar's own toolbar while the sidebar is open, and at the head of the
// canvas toolbar once the sidebar is gone. That's the preview's arrangement,
// and the reason is simple — the control that hides a panel can't live inside
// the panel it hides, so it has to hand off to the neighbouring toolbar.

import { IconButton } from "./IconButton";

interface Props {
  collapsed: boolean;
  onToggle: () => void;
}

export function SidebarToggle({ collapsed, onToggle }: Props) {
  const label = collapsed ? "显示会话列表" : "隐藏会话列表";
  return (
    <IconButton
      onClick={onToggle}
      title={`${label} (⌘B)`}
      aria-label={label}
      className="sidebar-toggle"
    >
      <svg
        width="15"
        height="15"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.9"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden
      >
        <rect x="3" y="4" width="18" height="16" rx="2" />
        <path d="M10 4v16" />
        {/* The chevron points where the click sends the sidebar. */}
        {collapsed ? (
          <path d="M5 10.5 6.5 12 5 13.5" />
        ) : (
          <path d="M6.5 10.5 5 12l1.5 1.5" />
        )}
      </svg>
    </IconButton>
  );
}
