// App-wide keyboard shortcuts. One global listener — see `useHotkeys` below.
//
// Bindings (Cmd on macOS, Ctrl elsewhere — modifier required for every hotkey
// so plain typing in inputs/xterm stays untouched):
//   ⌘K              → open cross-session command palette
//   ⌘,              → open Settings
//   ⌘1 / ⌘2 / ⌘3   → switch right column to Files / Editor / Terminal
//   ⌘[  / ⌘]        → previous / next session in the active project
//   ⌘W              → archive the current session (with confirm)
//   ⌘N              → open the new-session picker (UI to choose an agent)
//   ⌘T              → create a session with the first available AI agent
//   ⌘B              → toggle the left sidebar
//   ⌘J              → toggle the right pane on the terminal tab
//   ⇧⌘B             → toggle the right pane
//
// Session-lifecycle shortcuts (⌘N, ⌘W) plus the toggle/palette ones (⌘K,
// ⌘B, ⌘J, ⇧⌘B) and the numeric tab switches all fire even when an input
// has focus — xterm holds focus once a session is running, so gating them
// would turn each into a one-shot. The remaining shortcuts (⌘[/⌘], ⌘T) are
// suppressed inside text inputs, the CM6 editor, or the xterm terminals.

import { useEffect } from "react";
import type { RefObject } from "react";
import type { PanelImperativeHandle } from "react-resizable-panels";
import { toast } from "@heroui/react";
import { LAYOUT_CAP, useStore, type RightTab } from "./store";
import { archiveSession, createSession, listAgents } from "./ipc";
import { confirmDialog } from "./confirm";

interface HotkeyDeps {
  sidebarRef: RefObject<PanelImperativeHandle | null>;
  rightPaneRef: RefObject<PanelImperativeHandle | null>;
  openCommandPalette: () => void;
}

export function useHotkeys({
  sidebarRef,
  rightPaneRef,
  openCommandPalette,
}: HotkeyDeps) {
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

      // ⌘K: open cross-session command palette. Fires regardless of focus
      // so users can search even while typing in the terminal.
      if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        openCommandPalette();
        return;
      }

      // ⌘,: open Settings. Mirrors the macOS / VS Code convention. Routed
      // through a custom event so this module doesn't need to plumb a
      // setter from TopBar.
      if (e.key === ",") {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("ycode:open-settings"));
        return;
      }

      // ⌘1/2/3: numeric tab switch. Fire regardless of focus so the user can
      // jump back from the terminal to the editor without first clicking out.
      if (e.key === "1" || e.key === "2" || e.key === "3") {
        e.preventDefault();
        const tab: RightTab =
          e.key === "1" ? "files" : e.key === "2" ? "editor" : "terminal";
        useStore.getState().setRightTab(tab);
        return;
      }

      const key = e.key.toLowerCase();

      // ⌘B (no shift): toggle the left sidebar. Fires regardless of focus so
      // users can hide the sidebar while typing in the terminal.
      if (key === "b" && !e.shiftKey) {
        e.preventDefault();
        togglePanel(sidebarRef);
        return;
      }

      // ⇧⌘B: toggle the right pane.
      if (key === "b" && e.shiftKey) {
        e.preventDefault();
        togglePanel(rightPaneRef);
        return;
      }

      // ⌘J: focus the right-pane terminal. If the pane is collapsed expand
      // it + switch to the terminal tab; if already showing terminal,
      // collapse (VS Code's `Cmd+J` toggle semantics).
      if (key === "j" && !e.shiftKey) {
        e.preventDefault();
        const panel = rightPaneRef.current;
        const onTerminal = useStore.getState().rightTab === "terminal";
        if (panel && !panel.isCollapsed() && onTerminal) {
          panel.collapse();
        } else {
          if (panel?.isCollapsed()) panel.expand();
          useStore.getState().setRightTab("terminal");
          requestAnimationFrame(() => {
            window.dispatchEvent(new CustomEvent("ycode:focus-manual-terminal"));
          });
        }
        return;
      }

      // ⌘N (above the shouldSkip gate): create a new session with the
      // sidebar's current agent. Must fire regardless of focus — once a
      // session is open, xterm holds focus, and gating on shouldSkip would
      // turn this into a one-shot. ⇧⌘N is the OS "new window" shortcut and
      // is handled by the macOS menu, not here.
      if (key === "n" && !e.shiftKey) {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) {
          toast.warning("Pick a project first");
          return;
        }
        if (s.layout.visibleIds.length >= LAYOUT_CAP) {
          toast.warning(
            `Close a pane first — at the ${LAYOUT_CAP}-pane limit.`,
          );
          return;
        }
        const agentId =
          s.activeSidebarAgentId ??
          s.agents.find((a) => a.available && a.id !== "bash")?.id ??
          null;
        if (!agentId) {
          toast.warning("No available AI agent on PATH");
          return;
        }
        try {
          const view = await createSession({
            agent_profile_id: agentId,
            project_id: s.activeProjectId,
            title: "",
          });
          s.upsertSession(view);
          s.appendSessionToLayout(view.id);
        } catch (err) {
          toast.danger(`Create session failed: ${err}`);
        }
        return;
      }

      // ⌘W (above the shouldSkip gate): archive the currently active
      // session. xterm typically holds focus once a session is live, so
      // gating on shouldSkip would silently drop this — same trap ⌘N hit.
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

      if (shouldSkip(e)) return;

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

      if (key === "t") {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) {
          toast.warning("Pick a project first");
          return;
        }
        if (s.layout.visibleIds.length >= LAYOUT_CAP) {
          toast.warning(
            `Close a pane first — at the ${LAYOUT_CAP}-pane limit.`,
          );
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
          s.openSessionInLayout(view.id);
        } catch (err) {
          toast.danger(`Create session failed: ${err}`);
        }
        return;
      }

    }

    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [sidebarRef, rightPaneRef, openCommandPalette]);
}

function togglePanel(ref: RefObject<PanelImperativeHandle | null>) {
  const panel = ref.current;
  if (!panel) return;
  if (panel.isCollapsed()) panel.expand();
  else panel.collapse();
}
