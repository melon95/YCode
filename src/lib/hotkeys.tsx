// App-wide keyboard shortcuts. One global listener — see `useHotkeys` below.
//
// Bindings (Cmd on macOS, Ctrl elsewhere — modifier required for every hotkey
// so plain typing in inputs/xterm stays untouched):
//   ⌘K              → open cross-session command palette
//   ⌘,              → open Settings
//   ⌘O              → open/add a project folder
//   ⌘1-4            → switch right column to Terminal / Files / Changes / Todos
//                     (⌘2 lands on the editor when a file is open)
//   ⇧⌘1-4           → focus visible agent pane 1-4
//   ⌘[  / ⌘]        → previous / next session in the active project
//   ⇧⌘[ / ⇧⌘]       → previous / next project
//   ⌘W              → archive the current session (with confirm)
//   ⌘N              → create a session with the current sidebar agent
//   ⇧⌘N             → open the new-session picker (UI to choose an agent)
//   ⌘T              → create a session with the first available AI agent
//   ⌘B              → toggle the left sidebar
//   ⌘J              → toggle the right pane on the terminal tab
//   ⇧⌘B             → toggle the right pane
//
// Session-lifecycle shortcuts (⌘N, ⌘W) plus the toggle/palette ones (⌘K,
// ⌘B, ⌘J, ⇧⌘B), the numeric tab switches, and pane-focus shortcuts all fire
// even when an input has focus — xterm holds focus once a session is running,
// so gating them would turn each into a one-shot. The remaining shortcuts
// (⌘[/⌘], ⌘T) are suppressed inside text inputs, the CM6 editor, or the xterm
// terminals.

import { useEffect } from "react";
import type { RefObject } from "react";
import type { PanelImperativeHandle } from "react-resizable-panels";
import { toast } from "@heroui/react";
import { LAYOUT_CAP, PICKER_SLOT, useStore, type RightTab } from "./store";
import { archiveSession, createSession, listAgents } from "./ipc";
import { confirmDialog } from "./confirm";

// Numeric right-pane tab switches, matching the visible left-to-right order of
// the tab strip: Terminal · Files · Changes · Todos. The "files" slot is shared
// with the editor — when files are open the Files tab is hidden and ⌘2 jumps to
// the editor instead (see the handler below).
const RIGHT_TAB_BY_KEY: Record<string, RightTab> = {
  "1": "terminal",
  "2": "files",
  "3": "changes",
  "4": "todos",
};

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
      const target =
        e.target instanceof HTMLElement ? e.target : null;
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

      // ⌘O: open/add a project folder. Routed through TopBar so the dialog
      // flow stays in one place.
      if (e.key.toLowerCase() === "o" && !e.shiftKey) {
        e.preventDefault();
        window.dispatchEvent(new CustomEvent("ycode:new-project"));
        return;
      }

      // ⌘1-4: right-pane tab switch. ⇧⌘1-4 instead focuses the matching
      // visible agent pane. Fire regardless of focus so the user can jump
      // between terminals and side tools without first clicking out of xterm.
      if (e.key in RIGHT_TAB_BY_KEY) {
        e.preventDefault();
        if (e.shiftKey) {
          const slotIdx = Number(e.key) - 1;
          if (slotIdx < LAYOUT_CAP) {
            useStore.getState().focusLayoutSlot(slotIdx);
          }
        } else {
          let tab = RIGHT_TAB_BY_KEY[e.key];
          // The Files tab and the editor share a slot: once a file is open the
          // Files browser tab is hidden, so ⌘2 lands on the editor instead.
          if (tab === "files" && useStore.getState().openFiles.length > 0) {
            tab = "editor";
          }
          useStore.getState().setRightTab(tab);
        }
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

      // ⇧⌘N: open the agent picker as a NEW pane beside the existing ones
      // (not a fullscreen takeover) — pick an agent and it becomes a session
      // in that slot. Must fire from xterm focus for the same reason ⌘N does.
      if (key === "n" && e.shiftKey) {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) {
          toast.warning("Pick a project first");
          return;
        }
        // Already at the pane cap (and not just re-focusing an open picker) —
        // there's no room for another pane.
        if (
          s.layout.visibleIds.length >= LAYOUT_CAP &&
          !s.layout.visibleIds.includes(PICKER_SLOT)
        ) {
          toast.warning(`Close a pane first — at the ${LAYOUT_CAP}-pane limit.`);
          return;
        }
        s.showNewSessionPicker();
        return;
      }

      // ⌘N (above the shouldSkip gate): create a new session with the
      // sidebar's current agent. Must fire regardless of focus — once a
      // session is open, xterm holds focus, and gating on shouldSkip would
      // turn this into a one-shot.
      if (key === "n" && !e.shiftKey) {
        e.preventDefault();
        const s = useStore.getState();
        if (!s.activeProjectId) {
          toast.warning("Pick a project first");
          return;
        }
        // The agent picker is already on screen — empty project (fullscreen
        // picker), a lone exited pane (picker takes over), or an open ⇧⌘N
        // picker pane. The picker IS the "new session" UI, so ⌘N would just
        // bypass the user's pending choice. No-op and let them pick from it.
        const { visibleIds } = s.layout;
        const lone =
          visibleIds.length === 1 ? s.sessions[visibleIds[0]] : undefined;
        const pickerVisible =
          visibleIds.includes(PICKER_SLOT) ||
          visibleIds.length === 0 ||
          (!!lone && lone.status.type !== "Running");
        if (pickerVisible) return;
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

      // ⇧⌘[ / ⇧⌘] — previous / next project. Holding Shift turns the bracket
      // glyphs into braces (Shift+[ → "{", Shift+] → "}") on macOS/US layouts,
      // so match both pairs or this never fires.
      if (e.shiftKey && (key === "[" || key === "]" || key === "{" || key === "}")) {
        e.preventDefault();
        switchProject(key === "]" || key === "}" ? 1 : -1);
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

function switchProject(delta: 1 | -1) {
  const s = useStore.getState();
  if (s.lockedProjectId) return;
  const list = Object.values(s.projects)
    .filter((p) => !s.lockedByOtherWindows[p.id])
    .sort((a, b) => a.created_at_ms - b.created_at_ms);
  if (list.length <= 1) return;
  const idx = list.findIndex((p) => p.id === s.activeProjectId);
  const base = idx >= 0 ? idx : 0;
  const next = (base + delta + list.length) % list.length;
  s.setActiveProjectId(list[next].id);
}
