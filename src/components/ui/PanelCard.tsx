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
/// 没有入场动画:动画期间(即使只做 opacity)整张卡会被提成独立合成层,
/// 文件树这类大内容卡在 WKWebView 里异步分块光栅化,内容呈自上而下扫描式
/// 出现。切项目会重挂面板、每次重播动画,这个代价付不起。
///
/// 浮起感来自阴影,不描边(Claude Desktop 的卡片语言)。
const CARD = `panel-card flex flex-col min-h-[140px] rounded-xl bg-surface overflow-hidden
  shadow-[0_0_0_0.5px_rgba(0,0,0,0.05),0_1px_3px_rgba(0,0,0,0.06),0_6px_18px_rgba(0,0,0,0.08)]`
  .replace(/\s+/g, " ");

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
    // `panel-card` / `is-solo` 留作无样式钩子:solo 时兄弟卡收缩靠
    // `.panel-stack:has(.panel-card.is-solo)`(Tailwind 写不出「父级里有
    // 别的卡是 solo」),而 RightPane 和 ui/StackResizer 的 JS 还用
    // `.panel-card` 找相邻卡片。
    //
    // 没有入场动画:动画期间(即使只做 opacity)整张卡会被提成独立合成层,
    // 文件树这类大内容卡在 WKWebView 里异步分块光栅化,内容呈自上而下扫描式
    // 出现。切项目会重挂面板、每次重播动画,这个代价付不起。
    <section
      className={`${CARD} ${solo ? "is-solo flex-auto" : "flex-1 basis-0"}`}
      hidden={!open}
      aria-label={title}
    >
      {/* 通铺:header 与卡身同色、无分隔线(Claude Desktop 的卡片语言)。
          标题行靠留白和字重与内容区分,不靠色块。 */}
      <header className="flex-none flex items-center gap-2 pt-[7px] pr-2 pb-[7px] pl-3 bg-transparent flex-nowrap min-w-0">
        <span className="flex-none text-xs font-semibold text-text whitespace-nowrap">
          {title}
        </span>
        {bind && (
          <span
            // 终端卡的绑定内容是 WorkspaceTargetPicker(一个 select),
            // 在 chip 里要褪成纯文字 —— 边框和底色由 chip 自己提供。
            className="flex items-center gap-[5px] min-w-0 flex-[0_1_auto] overflow-hidden whitespace-nowrap
              text-[10.5px] text-muted bg-panel-raised rounded-md pt-0.5 pr-[7px] pb-0.5 pl-1
              [&_svg]:flex-none
              [&_.mono]:font-mono [&_.mono]:text-[10px] [&_.mono]:overflow-hidden [&_.mono]:text-ellipsis
              [&_.workspace-target-picker]:m-0 [&_.workspace-target-picker]:h-auto
              [&_.workspace-target-picker]:border-0 [&_.workspace-target-picker]:bg-transparent [&_.workspace-target-picker]:p-0
              [&_select]:bg-transparent [&_select]:border-none [&_select]:text-[10.5px] [&_select]:text-muted [&_select]:p-0"
          >
            {bind}
          </span>
        )}
        {count != null && (
          <span className="pcard-count flex-none font-mono text-[9px] rounded-full py-0.5 px-1.5 bg-st-working-tint text-st-working">
            {count}
          </span>
        )}
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
      {/* `panel-card-body` 留作钩子:solo 时兄弟卡的正文由
          `.panel-stack:has(...)` 隐藏。宿主面板本来是照着填满整列写的,
          进了卡片就只填满卡片 —— `[&>*]:min-h-0` 是那条 `> *` 规则。 */}
      <div className="panel-card-body flex-1 min-h-0 flex flex-col overflow-hidden [&>*]:min-h-0">
        {children}
      </div>
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
