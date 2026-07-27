import type { RefObject } from "react";
import {
  Group,
  Panel,
  Separator,
  type Layout,
  type PanelImperativeHandle,
} from "react-resizable-panels";
import { RightPane } from "./RightPane";
import { Sidebar } from "./Sidebar";
import { TerminalPane } from "./TerminalPane";

interface Props {
  defaultLayout: Layout | undefined;
  onLayoutChanged: (layout: Layout) => void;
  sidebarRef: RefObject<PanelImperativeHandle | null>;
  rightPaneRef: RefObject<PanelImperativeHandle | null>;
}

export function WorkspaceCanvas({
  defaultLayout,
  onLayoutChanged,
  sidebarRef,
  rightPaneRef,
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
      >
        <Sidebar />
      </Panel>
      <Separator className="col-handle" />
      <Panel id="middle" defaultSize="34%" minSize="20%">
        <section className="agent-workspace-widget" aria-label="Agent workspace">
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
