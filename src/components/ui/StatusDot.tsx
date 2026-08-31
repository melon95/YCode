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

/// The single source of truth for "what state is this session in", used by
/// every surface that shows one. Only `blocked` animates: the eye should be
/// pulled to the one session that cannot proceed without the user.
export function StatusDot({
  status,
  size = "md",
  labelled = true,
  className = "",
}: Props) {
  return (
    <span
      className={`status-dot status-${status} status-${size} ${className}`.trim()}
      title={labelled ? STATUS_LABEL[status] : undefined}
      aria-hidden={labelled ? undefined : true}
      role={labelled ? "img" : undefined}
      aria-label={labelled ? STATUS_LABEL[status] : undefined}
    />
  );
}
