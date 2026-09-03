import type { StatusKind } from "../../lib/sessionStatus";
import { STATUS_LABEL } from "../../lib/sessionStatus";

interface Props {
  status: StatusKind;
  /// Rendered at 7px by default; `sm` (5px) fits inside chips and tab rows.
  size?: "sm" | "md";
  /// Omit the title when the dot sits next to a text label that already says
  /// the same thing — a redundant tooltip is noise.
  labelled?: boolean;
  className?: string;
}

const SIZE: Record<NonNullable<Props["size"]>, string> = {
  md: "size-[7px]",
  sm: "size-[5px]",
};

const TONE: Record<StatusKind, string> = {
  working: "bg-st-working animate-status-breathe",
  /// The only ring animation in the app. `blocked` means the agent cannot
  /// proceed without the user, so it is the one state allowed to nag.
  blocked: "bg-st-blocked animate-status-ring",
  /// `done` means the process exited cleanly — which after an app restart is
  /// *every* session. Rendering that in success-green would turn the sidebar
  /// into a wall of green ticks, so it stays muted: filled (it ran) but quiet
  /// (nothing is happening). Only live states get a real color.
  done: "bg-st-idle opacity-55",
  error: "bg-st-blocked",
  idle: "bg-transparent border-[1.5px] border-st-idle",
};

/// The single source of truth for "what state is this session in", used by
/// every surface that shows one.
export function StatusDot({
  status,
  size = "md",
  labelled = true,
  className = "",
}: Props) {
  return (
    <span
      className={`shrink-0 block rounded-full transition-colors duration-[var(--t-base)] ease-smooth ${SIZE[size]} ${TONE[status]} ${className}`.trim()}
      title={labelled ? STATUS_LABEL[status] : undefined}
      aria-hidden={labelled ? undefined : true}
      role={labelled ? "img" : undefined}
      aria-label={labelled ? STATUS_LABEL[status] : undefined}
    />
  );
}
