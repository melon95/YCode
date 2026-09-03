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
//
// The `settings-card` / `settings-group-label` / `settings-note` class names
// are kept as bare selector hooks: the spacing *between* a card and the next
// group's label is written as sibling rules in redesign.css so a page never
// has to hand-place margins, and a utility on the element itself can't see
// what precedes it.

import type { ReactNode } from "react";

/* ---------- structure ---------- */

/// The small caps label above a card. Groups rows without nesting them in
/// another box, which is what the preview does between "生命周期" and
/// "Worktree 隔离".
///
/// The preview's 0.14em tracking is tuned for all-caps Latin. These labels
/// are mostly Chinese, where that much tracking pulls the characters apart.
export function SettingGroupLabel({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={`settings-group-label mb-2 font-mono text-[9.5px] font-medium tracking-[0.1em] uppercase text-whisper ${className}`.trim()}
    >
      {children}
    </div>
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
      className={`settings-card border rounded-[14px] overflow-hidden bg-surface ${
        tone === "danger" ? "border-st-blocked-edge" : "border-rule"
      } ${className}`.trim()}
    >
      {children}
    </div>
  );
}

/// The paragraph under a card that explains a boundary rather than a control
/// — e.g. why hooks can't break your agent.
export function SettingNote({ children }: { children: ReactNode }) {
  return (
    <p className="settings-note mt-2.5 mx-0 mb-0 py-[11px] px-[13px] border border-rule rounded-[10px] bg-surface text-[11.5px]/[1.55] text-muted [&_b]:text-text [&_b]:font-semibold">
      {children}
    </p>
  );
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
      className={`flex items-center gap-3 py-3 px-3.5 border-t border-rule first:border-t-0 ${
        pendingReason ? "opacity-50" : ""
      }`}
      title={pendingReason}
    >
      {icon && (
        <span className="flex-none size-[26px] rounded-lg flex items-center justify-center bg-panel-raised text-muted">
          {icon}
        </span>
      )}
      <span className="flex-1 min-w-0 flex flex-col gap-[3px]">
        {/* Rows whose name carries a leading status dot (the notifications
            page) need it baseline-aligned with the text rather than sitting
            on it. */}
        <span className="text-[12.5px] font-semibold text-text inline-flex items-center gap-[7px]">
          {name}
        </span>
        {/* The preview's `.dsub` is body type, not mono — these are
            sentences, and mono makes a sentence look like a file path. */}
        {desc && (
          <span className="text-[11px]/[1.45] font-normal text-subtle [&_code]:font-mono [&_code]:text-[10.5px] [&_.mono]:font-mono [&_.mono]:text-[10.5px]">
            {desc}
          </span>
        )}
      </span>
      {pendingReason && (
        <span className="flex-none font-mono text-[10px] text-subtle border border-rule rounded-[5px] py-0.5 px-1.5">
          待实现
        </span>
      )}
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

/// 开关的外观 —— 设置页与 composer 共用,可见性/几何只在这里改。
/// 关闭态用下沉底色:panel-raised 在浅色卡片上几乎隐形。
///
/// 拆成纯展示件是因为 composer 的 Worktree 开关整行本身就是 `<button>`,
/// 塞不进另一个 `<button>`;那里渲染成 `<span>` 复用同一套外观。
export function ToggleTrack({
  checked,
  className = "",
}: {
  checked: boolean;
  className?: string;
}) {
  return (
    <span
      className={`flex-none inline-block relative w-8 h-[18px] border rounded-[99px]
        transition-colors duration-[var(--t-base)] ease-smooth ${
          checked
            ? "bg-st-working border-transparent"
            : "bg-panel-sunken border-rule-strong"
        } ${className}`
        .replace(/\s+/g, " ")
        .trim()}
      aria-hidden
    >
      {/* 轨道内高 16px(18 - 2×1px 边框),13px 圆 → 上下各 1.5px。 */}
      <span
        className={`absolute top-1/2 -translate-y-1/2 size-[13px] rounded-full
          transition-[left] duration-[var(--t-base)] ease-smooth ${
            checked ? "left-[15px] bg-white" : "left-0.5 bg-bg"
          }`
          .replace(/\s+/g, " ")
          .trim()}
      />
    </span>
  );
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
      className="flex-none p-0 border-none bg-transparent inline-flex cursor-pointer disabled:opacity-45 disabled:cursor-not-allowed"
      onClick={() => onChange?.(!checked)}
    >
      <ToggleTrack checked={checked} />
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

const CHIP_BASE = `font-mono text-[9.5px] border rounded-[5px] py-[3px] px-[7px]
  transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth`;

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
    <div
      className="flex-none flex gap-1.5 flex-wrap"
      role="radiogroup"
      aria-label={label}
    >
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
            className={`${CHIP_BASE} disabled:opacity-45 disabled:cursor-not-allowed ${
              on
                ? "text-st-done border-transparent bg-st-done-tint cursor-default"
                : "text-subtle border-rule bg-transparent cursor-pointer not-disabled:hover:border-rule-strong not-disabled:hover:text-muted"
            }`
              .replace(/\s+/g, " ")
              .trim()}
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
      className={`font-mono text-[11px] overflow-hidden text-ellipsis whitespace-nowrap ${
        align === "end"
          ? "flex-1 min-w-0 text-right text-subtle"
          : "flex-none text-muted"
      }`}
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
  const toned =
    tone === "on"
      ? "text-st-done bg-st-done-tint border-transparent"
      : tone === "warn"
        ? "text-st-working bg-st-working-tint border-transparent"
        : "text-subtle bg-transparent border-rule";
  return (
    <span
      className={`${CHIP_BASE} cursor-default ${toned}`
        .replace(/\s+/g, " ")
        .trim()}
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
      className={`flex-none inline-flex items-center justify-center gap-[5px]
        min-w-control-sm h-control-sm py-0 px-[7px] border border-transparent rounded-sm
        bg-transparent text-muted text-[11.5px] cursor-pointer
        transition-[background-color,border-color,color] duration-[var(--t-fast)] ease-smooth
        disabled:opacity-40 disabled:cursor-not-allowed ${
          tone === "danger"
            ? "not-disabled:hover:bg-st-blocked-tint not-disabled:hover:border-transparent not-disabled:hover:text-st-blocked"
            : "not-disabled:hover:bg-panel-raised not-disabled:hover:border-rule not-disabled:hover:text-text"
        }`
        .replace(/\s+/g, " ")
        .trim()}
      onClick={onClick}
      disabled={disabled || !onClick}
      title={title ?? label}
      aria-label={label}
    >
      {children}
    </button>
  );
}
