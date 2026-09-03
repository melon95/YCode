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

/// Fixing the geometry here is what keeps the three toolbars
/// (sidebar / canvas / panels) on one grid.
const SIZE: Record<NonNullable<Props["size"]>, string> = {
  md: "size-control",
  sm: "size-control-sm",
};

const TONE: Record<NonNullable<Props["tone"]>, string> = {
  default: "",
  danger:
    "not-disabled:hover:bg-st-blocked-tint not-disabled:hover:border-transparent not-disabled:hover:text-st-blocked",
  accent: "text-accent",
};

/// Every icon-only control in the app.
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
      className={`shrink-0 inline-flex items-center justify-center rounded-md border border-transparent bg-transparent p-0 text-muted cursor-pointer
        transition-[background-color,border-color,color,transform,opacity] duration-[var(--t-fast)] ease-smooth
        not-disabled:hover:bg-panel-raised not-disabled:hover:border-rule not-disabled:hover:text-text
        not-disabled:active:scale-94
        disabled:opacity-38 disabled:cursor-not-allowed
        ${SIZE[size]} ${TONE[tone]} ${
          active
            ? "bg-st-working-tint border-transparent text-st-working"
            : ""
        } ${className}`
        .replace(/\s+/g, " ")
        .trim()}
      disabled={isDisabled}
      title={disabledReason ?? title}
      aria-pressed={active || undefined}
      {...rest}
    >
      {children}
    </button>
  );
}
