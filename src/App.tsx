import { useEffect } from "react";
import {
  Group,
  Panel,
  Separator,
  useDefaultLayout,
  usePanelRef,
} from "react-resizable-panels";
import { listProjects, listSessions, listenSessionEvents } from "./lib/ipc";
import { useStore } from "./lib/store";
import { useHotkeys } from "./lib/hotkeys";
import { TopBar } from "./components/TopBar";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { RightPane } from "./components/RightPane";
import { StatusBar } from "./components/StatusBar";

const COLUMN_PANEL_IDS = ["sidebar", "middle", "right"];

export function App() {
  const setSessions = useStore((s) => s.setSessions);
  const setProjects = useStore((s) => s.setProjects);
  const setLiveTitle = useStore((s) => s.setLiveTitle);
  // Persist column widths across reloads. Panel ids must match the literal
  // ids passed to <Panel> below or the restored layout won't apply.
  const { defaultLayout, onLayoutChanged } = useDefaultLayout({
    id: "ycode-columns",
    panelIds: COLUMN_PANEL_IDS,
    storage: typeof window !== "undefined" ? window.localStorage : undefined,
  });
  // Imperative handle for ⌘B (toggle sidebar collapse).
  const sidebarRef = usePanelRef();
  useHotkeys({ sidebarRef });

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;

    const refresh = () => {
      Promise.all([listProjects(), listSessions()])
        .then(([projects, sessions]) => {
          if (cancelled) return;
          setProjects(projects);
          setSessions(sessions);
        })
        .catch((err) => console.error("initial load failed", err));
    };
    refresh();

    listenSessionEvents((event) => {
      const kind = event.kind;
      if (kind.type === "PtyOutput" || kind.type === "PtyExit") {
        if (kind.type === "PtyExit") refresh();
        return;
      }
      if (kind.type === "TitleChanged") {
        setLiveTitle(event.session_id, kind.title);
        return;
      }
      refresh();
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setSessions, setProjects, setLiveTitle]);

  return (
    <>
      <TopBar />
      <Group
        orientation="horizontal"
        className="columns"
        defaultLayout={defaultLayout}
        onLayoutChanged={onLayoutChanged}
      >
        <Panel
          id="sidebar"
          defaultSize="20%"
          minSize="12%"
          collapsible
          collapsedSize="0"
          panelRef={sidebarRef}
        >
          <Sidebar />
        </Panel>
        <Separator className="col-handle" />
        <Panel id="middle" defaultSize="40%" minSize="20%">
          <TerminalPane />
        </Panel>
        <Separator className="col-handle" />
        <Panel id="right" defaultSize="40%" minSize="20%">
          <RightPane />
        </Panel>
      </Group>
      <StatusBar />
    </>
  );
}
