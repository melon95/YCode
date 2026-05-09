import { useEffect } from "react";
import { listSessions, listenSessionEvents } from "./lib/ipc";
import { useStore } from "./lib/store";
import { TopBar } from "./components/TopBar";
import { Sidebar } from "./components/Sidebar";
import { LogPane } from "./components/LogPane";
import { Composer } from "./components/Composer";
import { StatusBar } from "./components/StatusBar";
import { PermissionDialog } from "./components/PermissionDialog";

export function App() {
  const setSessions = useStore((s) => s.setSessions);
  const applyAgentEvent = useStore((s) => s.applyAgentEvent);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;

    listSessions()
      .then((list) => !cancelled && setSessions(list))
      .catch((err) => console.error("list_sessions failed", err));

    listenSessionEvents((event) => {
      const kind = event.kind;
      if (kind.type === "Agent") {
        applyAgentEvent(event.session_id, kind.event);
      } else {
        // Membership-changing kinds (SessionAppeared / Touched / Removed)
        // arrive too rarely to deserve incremental handling — refresh.
        listSessions()
          .then((list) => !cancelled && setSessions(list))
          .catch((err) => console.error("list_sessions failed", err));
      }
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });

    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [setSessions, applyAgentEvent]);

  return (
    <>
      <TopBar />
      <Sidebar />
      <div className="main">
        <LogPane />
        <Composer />
      </div>
      <StatusBar />
      <PermissionDialog />
    </>
  );
}
