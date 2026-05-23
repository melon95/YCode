// App-wide keyboard shortcuts. One global listener — see `useHotkeys` below.
//
// Bindings (Cmd on macOS, Ctrl elsewhere — modifier required for every hotkey
// so plain typing in inputs/xterm stays untouched):
//   ⌘1 / ⌘2 / ⌘3  → switch right column to Files / Editor / Terminal
//   ⌘[  / ⌘]       → previous / next session in the active project
//   ⌘W              → archive the current session (with confirm)
//   ⌘T              → create a session with the first available AI agent
//   ⌘B              → collapse / expand the sidebar
//
// Numeric tab switches fire even when an input has focus (matches the VS Code
// feel for ⌘1/2/3). Everything else is suppressed inside text inputs, the CM6
// editor, or the xterm terminals.

import { useEffect } from "react";
import type { RefObject } from "react";
import type { PanelImperativeHandle } from "react-resizable-panels";
import { toast } from "@heroui/react";
import { useStore, type RightTab } from "./store";
import { archiveSession, createSession, listAgents } from "./ipc";
import { confirmDialog } from "./confirm";

interface HotkeyDeps {
  sidebarRef: RefObject<PanelImperativeHandle | null>;
}

export function useHotkeys({ sidebarRef }: HotkeyDeps) {
  useEffect(() => {
    function shouldSkip(e: KeyboardEvent): boolean {
      const target = e.target as HTMLElement | null;
      if (!target) return false;
      const tag = target.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
      if (target.isContentEditable) return true;
      // CM6 / xterm host their own keyboard input — don't intercept.
      if (target.closest(".xterm") || target.closest(".cm-editor")) return true;
      return false;
    }

    async function handler(e: KeyboardEvent) {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod || e.altKey) return;

      // ⌘1/2/3: numeric tab switch. Fire regardless of focus so the user can
      // jump back from the terminal to the editor without first clicking out.
      if (e.key === "1" || e.key === "2" || e.key === "3") {
        e.preventDefault();
        const tab: RightTab =
          e.key === "1" ? "files" : e.key === "2" ? "editor" : "terminal";
        useStore.getState().setRightTab(tab);
        return;
      }

      if (shouldSkip(e)) return;

      const key = e.key.toLowerCase();

      if (key === "[" || key === "]") {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) return;
        const list = Object.values(s.sessions)
          .filter((x) => x.project_id === s.activeProjectId)
          .sort((a, b) => b.updated_at_ms - a.updated_at_ms);
        if (list.length === 0) return;
        const idx = list.findIndex((x) => x.id === s.activeId);
        const next =
          key === "]"
            ? (idx + 1) % list.length
            : idx <= 0
              ? list.length - 1
              : idx - 1;
        s.setActiveId(list[next].id);
        return;
      }

      if (key === "w") {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeId) return;
        const sess = s.sessions[s.activeId];
        if (!sess) return;
        const ok = await confirmDialog({
          title: `Archive "${sess.title || "this session"}"?`,
          message: "Live processes will be killed.",
          confirmLabel: "Archive",
          destructive: true,
        });
        if (!ok) return;
        try {
          await archiveSession(sess.id);
          s.removeSession(sess.id);
        } catch (err) {
          toast.danger(`Archive failed: ${err}`);
        }
        return;
      }

      if (key === "t") {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) {
          toast.warning("Pick a project first");
          return;
        }
        try {
          const list = await listAgents();
          const usable = list.filter((a) => a.id !== "bash" && a.available);
          if (usable.length === 0) {
            toast.warning("No available AI agent on PATH");
            return;
          }
          const agent = usable[0];
          const view = await createSession({
            agent_profile_id: agent.id,
            project_id: s.activeProjectId,
            title: "",
          });
          s.upsertSession(view);
          s.setActiveId(view.id);
        } catch (err) {
          toast.danger(`Create session failed: ${err}`);
        }
        return;
      }

      if (key === "b") {
        e.preventDefault();
        const panel = sidebarRef.current;
        if (!panel) return;
        if (panel.isCollapsed()) panel.expand();
        else panel.collapse();
      }
    }

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [sidebarRef]);
}
