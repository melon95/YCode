// The canvas toolbar — the strip above the agent panes.
//
// It replaces the old top-bar layout dropdown with the arrangement the
// redesign uses: the layout presets sit inline as icons (a dropdown to pick
// between four options was two clicks for a one-click decision), and the
// right-hand side owns the workspace-panel toggles so "which tools are open"
// is decided next to the work rather than inside the panel it controls.

import { Popover } from "@base-ui/react/popover";
import {
  defaultLayoutMode,
  useStore,
  validLayoutModes,
  type LayoutMode,
} from "../lib/store";
import type { RightTab } from "../lib/store";
import { IconButton } from "./ui/IconButton";
import { SidebarToggle } from "./ui/SidebarToggle";
import { AttentionInbox } from "./AttentionInbox";

const LAYOUT_LABEL: Record<LayoutMode, string> = {
  single: "单栏",
  stack: "上下堆叠",
  columns: "并排两栏",
  grid2x2: "网格 2×2",
  "main-side": "主 + 侧",
};

interface Props {
  onToggleSidebar: () => void;
  sidebarCollapsed: boolean;
  /// 设置 dialog 是否打开 —— 齿轮按钮的按压态。顶栏移除后全局入口
  /// (搜索/收件箱/设置)落在这条工具条右端。
  settingsActive?: boolean;
}

export function CanvasToolbar({
  onToggleSidebar,
  sidebarCollapsed,
  settingsActive = false,
}: Props) {
  const mode = useStore((s) => s.layout.mode);
  const count = useStore((s) => s.layout.visibleIds.length);
  const setLayoutMode = useStore((s) => s.setLayoutMode);
  const openPanels = useStore((s) => s.openPanels);
  const togglePanelOpen = useStore((s) => s.togglePanelOpen);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const todosByProject = useStore((s) => s.todos);
  // 变更面板上报的 diff 文件数(见 store.changesFileCount)。面板关闭时为
  // null,角标随之消失 —— 工具条不自己轮询 git diff。
  const changesFileCount = useStore((s) => s.changesFileCount);

  const valid = validLayoutModes(count);
  const activeMode = valid.includes(mode) ? mode : defaultLayoutMode(count);
  // Layout presets are meaningless with zero or one pane — dim rather than
  // hide them so the toolbar doesn't reflow the moment a second pane opens.
  const layoutDisabled = count <= 1;

  const openTodos = activeProjectId
    ? (todosByProject[activeProjectId] ?? []).filter((t) => t.status !== "done")
        .length
    : 0;

  return (
    <div className="canvas-toolbar toolbar-row">
      {/* Only while the sidebar is hidden. With it open the toggle sits in
          the sidebar's own toolbar — two buttons for one state would be a
          duplicate entry, and the preview picks the one next to the thing
          being toggled. */}
      {sidebarCollapsed && (
        <>
          <SidebarToggle collapsed onToggle={onToggleSidebar} />
          <span className="toolbar-div" />
        </>
      )}

      {(["single", "stack", "columns", "main-side", "grid2x2"] as LayoutMode[]).map(
        (m) => (
          <IconButton
            key={m}
            active={!layoutDisabled && activeMode === m}
            disabled={layoutDisabled || !valid.includes(m)}
            onClick={() => setLayoutMode(m)}
            title={LAYOUT_LABEL[m]}
            aria-label={LAYOUT_LABEL[m]}
          >
            <LayoutGlyph mode={m} />
          </IconButton>
        ),
      )}

      <span className="toolbar-spacer" />


      {/* Workspace panels. Highlighted when open, mirroring the way the
          preview (and Claude Code's own Code view) puts the panel switches
          at the top of the working area. */}
      <PanelToggle tab="terminal" open={openPanels} onPick={togglePanelOpen} label="终端">
        <TerminalIcon />
      </PanelToggle>
      <PanelToggle
        tab="files"
        open={openPanels}
        // 文件与编辑器共用一张卡(打开文件时 setRightTab("editor") 会把
        // "editor" 挂进 openPanels),开关也必须按一组开合 —— 只摘 "files"
        // 的话卡片因 "editor" 仍在而保持打开,按钮看起来就是坏的。
        // 与 RightPane 卡片自己的 × 按钮同一套逻辑。
        onPick={() => {
          togglePanelOpen("files");
          if (openPanels.includes("editor")) togglePanelOpen("editor");
        }}
        label="文件"
        matches={["files", "editor"]}
      >
        <FilesIcon />
      </PanelToggle>
      <PanelToggle
        tab="changes"
        open={openPanels}
        onPick={togglePanelOpen}
        label="变更"
        // 预览稿的变更角标。0 个文件不挂角标(与待办一致)。
        count={changesFileCount || undefined}
      >
        <ChangesIcon />
      </PanelToggle>
      <PanelToggle
        tab="todos"
        open={openPanels}
        onPick={togglePanelOpen}
        label="待办"
        count={openTodos || undefined}
      >
        <TodosIcon />
      </PanelToggle>

      <PanelCatalog />

      {/* 全局入口(原顶栏):搜索 / 收件箱 / 设置。 */}
      <span className="toolbar-div" />
      <IconButton
        onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-palette"))}
        title="搜索或执行命令 (⌘K)"
        aria-label="搜索或执行命令 (⌘K)"
      >
        <SearchIcon />
      </IconButton>
      <AttentionInbox />
      <IconButton
        active={settingsActive}
        onClick={() => window.dispatchEvent(new CustomEvent("ycode:open-settings"))}
        title="设置 (⌘,)"
        aria-label="设置"
      >
        <GearIcon />
      </IconButton>
    </div>
  );
}

function PanelToggle({
  tab,
  open,
  onPick,
  label,
  count,
  matches,
  children,
}: {
  tab: RightTab;
  open: RightTab[];
  onPick: (t: RightTab) => void;
  label: string;
  count?: number;
  matches?: RightTab[];
  children: React.ReactNode;
}) {
  const active = (matches ?? [tab]).some((t) => open.includes(t));
  return (
    <span className="panel-toggle">
      <IconButton
        active={active}
        onClick={() => onPick(tab)}
        title={label}
        aria-label={label}
      >
        {children}
      </IconButton>
      {count != null && (
        <span className="count-badge count-badge-float">{count}</span>
      )}
    </span>
  );
}

/// The catalogue of panels that aren't built yet. It exists now, disabled,
/// because the panel row is where a user will look for "can I get a browser
/// preview in here?" — and an entry that says "not yet" answers that faster
/// than its absence does.
function PanelCatalog() {
  return (
    <Popover.Root>
      <Popover.Trigger
        className="icon-btn2 icon-btn2-md panel-add"
        title="添加面板"
        aria-label="添加面板"
      >
        <PlusIcon />
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Positioner sideOffset={8} align="end">
          <Popover.Popup className="panel-catalog">
            <div className="panel-catalog-head">面板</div>
            <div className="panel-catalog-row">
              <span className="pc-icon"><TerminalIcon /></span>
              <span className="pc-main">
                <span className="pc-name">终端</span>
                <span className="pc-desc">在项目目录里开一个 shell</span>
              </span>
              <span className="pc-state">内置</span>
            </div>
            <div className="panel-catalog-row">
              <span className="pc-icon"><FilesIcon /></span>
              <span className="pc-main">
                <span className="pc-name">文件</span>
                <span className="pc-desc">文件树 · CodeMirror 编辑器</span>
              </span>
              <span className="pc-state is-on">已启用</span>
            </div>
            <div className="panel-catalog-row">
              <span className="pc-icon"><ChangesIcon /></span>
              <span className="pc-main">
                <span className="pc-name">变更</span>
                <span className="pc-desc">工作区 diff · 检查点回顾</span>
              </span>
              <span className="pc-state is-on">已启用</span>
            </div>
            <div className="panel-catalog-row">
              <span className="pc-icon"><TodosIcon /></span>
              <span className="pc-main">
                <span className="pc-name">待办</span>
                <span className="pc-desc">项目待办 · agent 可经 MCP 读写</span>
              </span>
              <span className="pc-state is-on">已启用</span>
            </div>
            <div className="panel-catalog-row is-disabled">
              <span className="pc-icon"><BrowserIcon /></span>
              <span className="pc-main">
                <span className="pc-name">浏览器</span>
                <span className="pc-desc">预览本地 dev server</span>
              </span>
              <span className="pc-state">未实现</span>
            </div>
            <div className="panel-catalog-foot">
              面板可插拔:未实现的条目会在支持后出现在上方的开关里。
            </div>
          </Popover.Popup>
        </Popover.Positioner>
      </Popover.Portal>
    </Popover.Root>
  );
}

/* ---------- glyphs ---------- */

function LayoutGlyph({ mode }: { mode: LayoutMode }) {
  const common = {
    width: 15,
    height: 15,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.9,
    strokeLinejoin: "round" as const,
  };
  return (
    <svg {...common}>
      <rect x="3" y="4" width="18" height="16" rx="2" />
      {mode === "stack" && <path d="M3 12h18" />}
      {mode === "columns" && <path d="M12 4v16" />}
      {mode === "grid2x2" && <path d="M12 4v16M3 12h18" />}
      {mode === "main-side" && <path d="M15 4v16M15 12h6" />}
    </svg>
  );
}

function SearchIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" aria-hidden>
      <circle cx="11" cy="11" r="7" />
      <path d="m20 20-4-4" />
    </svg>
  );
}

function GearIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <circle cx="12" cy="12" r="3" />
      <path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33H9a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82V9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z" />
    </svg>
  );
}

function TerminalIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="m4 17 6-6-6-6" />
      <path d="M12 19h8" />
    </svg>
  );
}
function FilesIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
    </svg>
  );
}
function ChangesIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <circle cx="6" cy="6" r="3" />
      <circle cx="18" cy="18" r="3" />
      <path d="M6 9v3a3 3 0 0 0 3 3h6" />
    </svg>
  );
}
function TodosIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M3 6h11M3 12h11M3 18h11" />
      <path d="m17 6 2 2 4-4" />
    </svg>
  );
}
function BrowserIcon() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinejoin="round">
      <rect x="3" y="4" width="18" height="16" rx="2" />
      <path d="M3 9h18" />
    </svg>
  );
}
function PlusIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}
