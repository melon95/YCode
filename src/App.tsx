import { useEffect } from "react";
import { listProjects, listSessions, listenSessionEvents } from "./lib/ipc";
import { useStore } from "./lib/store";
import { TopBar } from "./components/TopBar";
import { Sidebar } from "./components/Sidebar";
import { TerminalPane } from "./components/TerminalPane";
import { StatusBar } from "./components/StatusBar";

export function App() {
  const setSessions = useStore((s) => s.setSessions);
  const setProjects = useStore((s) => s.setProjects);

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
      // PtyOutput/PtyExit are handled inside TerminalPane; here we react
      // only to membership-changing events by re-fetching the full lists.
      if (kind.type === "PtyOutput" || kind.type === "PtyExit") {
        // PtyExit also implies an exit-code mutation persisted server-side;
        // re-fetch sessions so the SessionRow status badge updates.
        if (kind.type === "PtyExit") refresh();
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
  }, [setSessions, setProjects]);

  return (
    <>
      <TopBar />
      <Sidebar />
      <div className="main">
        <TerminalPane />
      </div>
      <StatusBar />
    </>
  );
}
