import type { ReactNode } from "react";
import { IconButton } from "./IconButton";

interface Props {
  title: string;
  /// What this panel is currently pointed at — the worktree/branch for
  /// Changes, the checkout for Terminal. With several agent panes running in
  /// different worktrees, a panel without this label is ambiguous: you can't
  /// tell whose diff you're reading.
  bind?: ReactNode;
  count?: ReactNode;
  open: boolean;
  /// Solo mode: this card fills the stack and the others collapse to their
  /// headers. Cheaper than a real maximise because nothing unmounts.
  solo?: boolean;
  onToggleSolo?: () => void;
  onClose?: () => void;
  /// Extra header controls (e.g. the terminal's "new split").
  actions?: ReactNode;
  children: ReactNode;
}

/// One panel in the right column's vertical stack.
///
/// Closed cards stay mounted and hidden rather than unmounting: the terminal
/// panel owns PTYs that die with their React tree, and the file tree pays a
/// full re-scan on remount. Hiding keeps both alive, which is the same trick
/// the pane already used for inactive projects.
export function PanelCard({
  title,
  bind,
  count,
  open,
  solo = false,
  onToggleSolo,
  onClose,
  actions,
  children,
}: Props) {
  return (
    <section
      className={`panel-card${solo ? " is-solo" : ""}`}
      hidden={!open}
      aria-label={title}
    >
      <header className="panel-card-head">
        <span className="pcard-title">{title}</span>
        {bind && <span className="pcard-bind">{bind}</span>}
        {count != null && <span className="pcard-count">{count}</span>}
        <span className="toolbar-spacer" />
        {actions}
        {onToggleSolo && (
          <IconButton
            size="sm"
            active={solo}
            onClick={onToggleSolo}
            title={solo ? "还原" : "放大"}
            aria-label={solo ? "还原面板" : "放大面板"}
          >
            {solo ? <MinimiseIcon /> : <ExpandIcon />}
          </IconButton>
        )}
        {onClose && (
          <IconButton
            size="sm"
            onClick={onClose}
            title="关闭"
            aria-label={`关闭${title}`}
          >
            <CloseIcon />
          </IconButton>
        )}
      </header>
      <div className="panel-card-body">{children}</div>
    </section>
  );
}

function ExpandIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M15 3h6v6M9 21H3v-6M21 3l-7 7M3 21l7-7" />
    </svg>
  );
}
function MinimiseIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M9 3v6H3M21 15h-6v6M3 9l7-7M21 15l-7 7" />
    </svg>
  );
}
function CloseIcon() {
  return (
    <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M18 6 6 18M6 6l12 12" />
    </svg>
  );
}
