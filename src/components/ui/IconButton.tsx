import type { ButtonHTMLAttributes, ReactNode } from "react";

interface Props extends ButtonHTMLAttributes<HTMLButtonElement> {
  children: ReactNode;
  /// `danger` tints the hover state red — used for destructive row actions.
  tone?: "default" | "danger" | "accent";
  /// Toolbar buttons are 30px; `sm` (26px) is for dense card headers.
  size?: "sm" | "md";
  /// Renders the pressed/on state (e.g. an open panel's toggle).
  active?: boolean;
  /// Why the control is unavailable. Rendered as the tooltip and announced,
  /// so a disabled entry always explains itself instead of just being dead.
  disabledReason?: string;
}

/// Every icon-only control in the app. Fixing the geometry here is what keeps
/// the three toolbars (sidebar / canvas / panels) on one grid.
export function IconButton({
  children,
  tone = "default",
  size = "md",
  active = false,
  disabledReason,
  className = "",
  disabled,
  title,
  ...rest
}: Props) {
  const isDisabled = disabled || Boolean(disabledReason);
  return (
    <button
      type="button"
      className={`icon-btn2 icon-btn2-${size} icon-btn2-${tone} ${
        active ? "is-active" : ""
      } ${className}`.trim()}
      disabled={isDisabled}
      title={disabledReason ?? title}
      aria-pressed={active || undefined}
      {...rest}
    >
      {children}
    </button>
  );
}
