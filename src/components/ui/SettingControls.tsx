// Card-row primitives for the settings pages.
//
// Every page in the redesign preview is the same handful of shapes stacked:
// a labelled row, a toggle, a segmented picker, a read-only mono value.
// Building them once here is what keeps thirteen pages reading as one
// product instead of thirteen little dialects.
//
// It is also where the project's "no fake controls" rule is enforced. A row
// whose backing feature doesn't exist yet passes `pendingReason`: it dims,
// gets a 待实现 tag, and its control goes inert with the reason as the
// tooltip. That is deliberately more work than just deleting the row —
// "not yet, and here's why" answers the question the user came with.

import type { ReactNode } from "react";

/* ---------- structure ---------- */

/// The small caps label above a card. Groups rows without nesting them in
/// another box, which is what the preview does between "生命周期" and
/// "Worktree 隔离".
export function SettingGroupLabel({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div className={`settings-group-label ${className}`.trim()}>{children}</div>
  );
}

export function SettingCard({
  children,
  tone,
  className = "",
}: {
  children: ReactNode;
  /// `danger` outlines the card in the blocked hue — for destructive actions.
  tone?: "danger";
  className?: string;
}) {
  return (
    <div
      className={
        `settings-card${tone === "danger" ? " is-danger" : ""} ${className}`.trim()
      }
    >
      {children}
    </div>
  );
}

/// The paragraph under a card that explains a boundary rather than a control
/// — e.g. why hooks can't break your agent.
export function SettingNote({ children }: { children: ReactNode }) {
  return <p className="settings-note">{children}</p>;
}

interface RowProps {
  name: ReactNode;
  desc?: ReactNode;
  /// Leading glyph. Used by the rows that stand for a *thing* (an agent, a
  /// panel, a language server) rather than a preference.
  icon?: ReactNode;
  /// Why this row's feature isn't available. Presence of this dims the row,
  /// tags it, and is surfaced as the tooltip.
  pendingReason?: string;
  children?: ReactNode;
}

export function SettingRow({
  name,
  desc,
  icon,
  pendingReason,
  children,
}: RowProps) {
  return (
    <div
      className={`settings-row${pendingReason ? " is-pending" : ""}`}
      title={pendingReason}
    >
      {icon && <span className="settings-row-icon">{icon}</span>}
      <span className="settings-row-main">
        <span className="settings-row-name">{name}</span>
        {desc && <span className="settings-row-desc">{desc}</span>}
      </span>
      {pendingReason && <span className="settings-tag">待实现</span>}
      {children}
    </div>
  );
}

/* ---------- controls ---------- */

interface ToggleProps {
  checked: boolean;
  onChange?: (next: boolean) => void;
  disabled?: boolean;
  /// Announced to screen readers — the visual label lives in the row, which
  /// the switch itself has no association with.
  label: string;
  title?: string;
}

export function SettingToggle({
  checked,
  onChange,
  disabled,
  label,
  title,
}: ToggleProps) {
  const inert = disabled || !onChange;
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      title={title}
      disabled={inert}
      className={`settings-toggle${checked ? " is-on" : ""}`}
      onClick={() => onChange?.(!checked)}
    >
      <span className="settings-toggle-knob" aria-hidden />
    </button>
  );
}

export interface ChipOption<T extends string> {
  value: T;
  label: string;
  /// Per-option reason. Lets a picker offer two live choices and one that
  /// isn't wired yet, without splitting the row in two.
  disabledReason?: string;
}

interface ChipsProps<T extends string> {
  options: ReadonlyArray<ChipOption<T>>;
  value: T;
  onChange?: (next: T) => void;
  disabled?: boolean;
  label: string;
}

/// A segmented single-choice picker. Preferred over a `<select>` for short
/// option sets: the alternatives stay visible, so the current value reads as
/// a position rather than a word you have to open a menu to compare.
export function SettingChips<T extends string>({
  options,
  value,
  onChange,
  disabled,
  label,
}: ChipsProps<T>) {
  const inert = disabled || !onChange;
  return (
    <div className="settings-chips" role="radiogroup" aria-label={label}>
      {options.map((opt) => {
        const optInert = inert || Boolean(opt.disabledReason);
        const on = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="radio"
            aria-checked={on}
            disabled={optInert}
            title={opt.disabledReason}
            className={`settings-chip${on ? " is-on" : ""}`}
            onClick={() => onChange?.(opt.value)}
          >
            {opt.label}
          </button>
        );
      })}
    </div>
  );
}

/// A read-only value in mono type. `align="end"` is the preview's `.val2`:
/// long paths push to the right edge so the labels stay in one column.
export function SettingValue({
  children,
  align = "start",
  title,
}: {
  children: ReactNode;
  align?: "start" | "end";
  title?: string;
}) {
  return (
    <span
      className={`settings-value${align === "end" ? " is-end" : ""}`}
      title={title}
    >
      {children}
    </span>
  );
}

/// The static counterpart to `SettingChips` — a fact about the row, not a
/// choice. `tone="on"` is the green "已启用" state, `warn` the amber one.
export function SettingChip({
  children,
  tone,
  title,
}: {
  children: ReactNode;
  tone?: "on" | "warn";
  title?: string;
}) {
  return (
    <span
      className={`settings-chip is-static${tone ? ` is-${tone}` : ""}`}
      title={title}
    >
      {children}
    </span>
  );
}

/// Right-aligned action inside a row (edit, install, rebuild, remove).
export function SettingAction({
  children,
  onClick,
  tone,
  disabled,
  title,
  label,
}: {
  children: ReactNode;
  onClick?: () => void;
  tone?: "danger";
  disabled?: boolean;
  title?: string;
  label: string;
}) {
  return (
    <button
      type="button"
      className={`settings-action-btn${tone === "danger" ? " is-danger" : ""}`}
      onClick={onClick}
      disabled={disabled || !onClick}
      title={title ?? label}
      aria-label={label}
    >
      {children}
    </button>
  );
}
