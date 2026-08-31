import type { RefObject } from "react";
import {
  Group,
  Panel,
  Separator,
  type Layout,
  type PanelImperativeHandle,
} from "react-resizable-panels";
import { CanvasToolbar } from "./CanvasToolbar";
import { RightPane } from "./RightPane";
import { Sidebar } from "./Sidebar";
import { TerminalPane } from "./TerminalPane";

interface Props {
  defaultLayout: Layout | undefined;
  onLayoutChanged: (layout: Layout) => void;
  sidebarRef: RefObject<PanelImperativeHandle | null>;
  rightPaneRef: RefObject<PanelImperativeHandle | null>;
  sidebarCollapsed: boolean;
  /// 折叠状态的唯一权威来源:Panel 的 onResize。⌘B、工具条按钮、拖拽分隔条
  /// 三条路径都汇到这里,不需要各自去镜像状态。
  onSidebarCollapsedChange: (collapsed: boolean) => void;
  onToggleSidebar: () => void;
}

export function WorkspaceCanvas({
  defaultLayout,
  onLayoutChanged,
  sidebarRef,
  rightPaneRef,
  sidebarCollapsed,
  onSidebarCollapsedChange,
  onToggleSidebar,
}: Props) {
  return (
    <Group
      orientation="horizontal"
      className="columns docked-workspace"
      defaultLayout={defaultLayout}
      onLayoutChanged={onLayoutChanged}
    >
      <Panel
        id="sidebar"
        defaultSize="19%"
        minSize="12%"
        collapsible
        collapsedSize="0"
        panelRef={sidebarRef}
        onResize={(size) => onSidebarCollapsedChange(size.inPixels === 0)}
      >
        <Sidebar onToggleSidebar={onToggleSidebar} />
      </Panel>
      <Separator className="col-handle" />
      <Panel id="middle" defaultSize="34%" minSize="20%">
        <section className="agent-workspace-widget" aria-label="Agent workspace">
          <CanvasToolbar
            onToggleSidebar={onToggleSidebar}
            sidebarCollapsed={sidebarCollapsed}
          />
          <TerminalPane />
        </section>
      </Panel>
      <Separator className="col-handle" />
      <Panel
        id="right"
        defaultSize="47%"
        minSize="20%"
        collapsible
        collapsedSize="0"
        panelRef={rightPaneRef}
      >
        <section
          className="workspace-dock-widget"
          aria-label="Workspace tools widget"
        >
          <RightPane />
        </section>
      </Panel>
    </Group>
  );
}
