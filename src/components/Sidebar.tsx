import { useEffect, useMemo, useState } from "react";
import { Button, toast } from "@heroui/react";
import { LAYOUT_CAP, useStore } from "../lib/store";
import {
  createSession,
  listenSessionEvents,
  scanWorkspaceSessions,
} from "../lib/ipc";
import type {
  AgentProfileView,
  DiscoveredSessionView,
  ProjectView,
} from "../lib/types";
import { AgentIcon } from "./AgentIcon";

export function Sidebar() {
  const [creating, setCreating] = useState(false);
  const upsertSession = useStore((s) => s.upsertSession);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const agents = useStore((s) => s.agents);

  // Agent filter tabs = every configured profile whose command resolves on
  // PATH. Unavailable agents are hidden entirely (per user request) — the
  // Settings dialog is where the user discovers what's configured but not
  // installed.
  const agentTabs = useMemo(() => agents.filter((a) => a.available), [agents]);
  // Cap-aware "+ new session" button. The layout reducer would silently
  // replace-focused-slot at cap, but we'd rather block the click so the
  // user doesn't accidentally lose a pane they were looking at.
  const visibleCount = useStore((s) => s.layout.visibleIds.length);
  const atCap = visibleCount >= LAYOUT_CAP;

  // Discovered sessions live here (rather than inside the panel) so we can
  // derive the default agent tab from the most-recent one.
  const [items, setItems] = useState<DiscoveredSessionView[]>([]);
  const [scanError, setScanError] = useState<string | null>(null);
  const [scanning, setScanning] = useState(true);

  // Re-scan whenever the active project changes or the backend reports a
  // jsonl change for the active workspace.
  useEffect(() => {
    if (!activeProjectId) {
      setItems([]);
      setScanning(false);
      return;
    }
    let cancelled = false;
    setScanning(true);
    setScanError(null);
    const refresh = () => {
      scanWorkspaceSessions(activeProjectId)
        .then((found) => {
          if (cancelled) return;
          setItems(found);
        })
        .catch((e) => {
          if (cancelled) return;
          setScanError(String(e));
        })
        .finally(() => {
          if (!cancelled) setScanning(false);
        });
    };
    refresh();

    let unlisten: (() => void) | undefined;
    listenSessionEvents((ev) => {
      if (ev.kind.type === "JsonlChanged") refresh();
    }).then((u) => {
      if (cancelled) u();
      else unlisten = u;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [activeProjectId]);

  // Reset the user's manual tab pick whenever the active project changes —
  // the new project gets its own auto-default (last-used agent).
  const [userPickedAgent, setUserPickedAgent] = useState<string | null>(null);
  useEffect(() => {
    setUserPickedAgent(null);
  }, [activeProjectId]);

  // items is mtime-DESC, so items[0].agent is the project's most-recently-used
  // CLI (introspect id). Resolve that to a profile id; fall back to the
  // first configured agent for projects with no history.
  const defaultAgent = useMemo(() => {
    const recentIntrospect = items[0]?.agent;
    if (recentIntrospect) {
      const matched = agentTabs.find((p) => p.introspect === recentIntrospect);
      if (matched) return matched.id;
    }
    return agentTabs[0]?.id ?? null;
  }, [items, agentTabs]);

  const activeAgent = userPickedAgent ?? defaultAgent;
  const activeAgentProfile = useMemo(
    () => agentTabs.find((p) => p.id === activeAgent) ?? null,
    [agentTabs, activeAgent],
  );

  // Mirror the active agent tab id into the store so the ⌘N hotkey can
  // build a createSession call without reaching into our local state. A
  // plain string is durable across our re-renders; a function value would
  // capture this render's closure and go stale on the next one.
  const setActiveSidebarAgentId = useStore((s) => s.setActiveSidebarAgentId);
  useEffect(() => {
    setActiveSidebarAgentId(activeAgent);
    return () => setActiveSidebarAgentId(null);
  }, [activeAgent, setActiveSidebarAgentId]);

  async function onCreate(
    project: ProjectView,
    profileId: string | null,
    opts?: { resume?: string; title?: string },
  ) {
    if (creating) return;
    if (atCap) {
      toast.warning(`Close a pane first — at the ${LAYOUT_CAP}-pane limit.`);
      return;
    }
    if (!profileId) {
      toast.warning("No agent selected.");
      return;
    }
    const profile = useStore
      .getState()
      .agents.find((a) => a.id === profileId);
    if (!profile) {
      toast.danger(`No configured agent with id "${profileId}"`);
      return;
    }
    setCreating(true);
    try {
      const view = await createSession({
        agent_profile_id: profile.id,
        project_id: project.id,
        // Empty title — the CLI's OSC window-title (or a manual rename)
        // fills it in.
        title: opts?.title ?? "",
        resume: opts?.resume,
      });
      upsertSession(view);
      openSessionInLayout(view.id);
    } catch (err) {
      toast.danger(`Create ${profile.display_name} session failed: ${err}`);
    } finally {
      setCreating(false);
    }
  }

  async function onResume(d: DiscoveredSessionView, project: ProjectView) {
    if (!d.session_id) {
      toast.warning("This jsonl has no resumable session id yet.");
      return;
    }
    // Reuse-if-running: a jsonl conversation can already be live in this
    // window from an earlier click. Spawning another `--resume <id>` then
    // would attach a second CLI to the same on-disk conversation, double
    // the panes, and almost certainly isn't what the user means by "open
    // this row again". Match by `agent_session_id` — that's the stable
    // CLI-side id, while `SessionView.id` is our window-local ULID and
    // rolls every resume.
    const existing = Object.values(useStore.getState().sessions).find(
      (s) =>
        s.agent_session_id === d.session_id &&
        s.status.type === "Running" &&
        s.project_id === project.id,
    );
    if (existing) {
      openSessionInLayout(existing.id);
      return;
    }
    // Discovered rows carry the introspect id — map back to a launch profile.
    const profile = agentTabs.find((a) => a.introspect === d.agent);
    if (!profile) {
      toast.danger(
        `No configured agent can resume "${d.agent}" sessions. Add one in Settings.`,
      );
      return;
    }
    await onCreate(project, profile.id, {
      resume: d.session_id,
      // Pre-seed the row title with the discovered title so the sidebar /
      // tab strip aren't blank while the CLI replays.
      title: d.title ?? "",
    });
  }

  return (
    <aside className="sidebar">
      <div className="sidebar-header">
        <div className="sidebar-agent-tabs" role="tablist" aria-label="Agent filter">
          {agentTabs.map((profile) => (
            <button
              key={profile.id}
              type="button"
              role="tab"
              aria-selected={activeAgent === profile.id}
              className={
                `sidebar-agent-tab agent-${profile.id}` +
                (activeAgent === profile.id ? " active" : "")
              }
              onClick={() => setUserPickedAgent(profile.id)}
              title={
                profile.introspect
                  ? `Show ${profile.display_name} sessions`
                  : `${profile.display_name} (no session history)`
              }
            >
              <AgentIcon
                icon={profile.icon}
                variant={profile.icon_variant}
                fallbackChar={profile.display_name}
                size={18}
              />
            </button>
          ))}
        </div>
        <Button
          size="sm"
          variant="primary"
          onPress={() => activeProject && onCreate(activeProject, activeAgent)}
          isDisabled={!activeProject || creating || atCap}
          className="sidebar-new-session"
          isIconOnly
          aria-label={
            atCap
              ? `Close a pane to add another (limit ${LAYOUT_CAP})`
              : `New ${activeAgentProfile?.display_name ?? activeAgent ?? "session"}`
          }
        >
          +
        </Button>
      </div>
      <div className="sidebar-content">
        {!activeProject ? (
          <div className="empty">
            No project selected.
            <br />
            Create one with <em>+</em> in the top bar.
          </div>
        ) : (
          <DiscoveredSessionsPanel
            items={items}
            profile={activeAgentProfile}
            loading={scanning}
            error={scanError}
            onResume={(d) => activeProject && onResume(d, activeProject)}
            resuming={creating}
          />
        )}
      </div>
    </aside>
  );
}

/// Filtered History list. Pure renderer — parent owns the data.
function DiscoveredSessionsPanel({
  items,
  profile,
  loading,
  error,
  onResume,
  resuming,
}: {
  items: DiscoveredSessionView[];
  profile: AgentProfileView | null;
  loading: boolean;
  error: string | null;
  onResume: (d: DiscoveredSessionView) => void;
  resuming: boolean;
}) {
  const agents = useStore((s) => s.agents);
  // introspect id → first matching profile, so each row's `d.agent` can be
  // resolved to a launch profile (and thus an icon / display name).
  const profileByIntrospect = useMemo(() => {
    const map: Record<string, AgentProfileView> = {};
    for (const a of agents) {
      if (a.introspect && !(a.introspect in map)) map[a.introspect] = a;
    }
    return map;
  }, [agents]);

  // Only profiles bound to a jsonl parser have a meaningful history list;
  // PTY-only agents (Cursor, Aider, etc.) show an explanatory empty state.
  const introspectId = profile?.introspect ?? null;
  const filtered = useMemo(
    () =>
      introspectId ? items.filter((d) => d.agent === introspectId) : [],
    [items, introspectId],
  );

  return (
    <div className="discovered-panel">
      {loading && <div className="project-empty">Scanning…</div>}
      {error && <div className="project-empty error">Scan failed: {error}</div>}
      {!loading && !error && filtered.length === 0 && (
        <div className="project-empty">
          {!profile
            ? "No agent selected."
            : !profile.introspect
              ? `${profile.display_name} runs PTY-only — no session history is tracked.`
              : items.length === 0
                ? "No sessions on disk for this project yet."
                : `No ${profile.display_name} sessions for this cwd.`}
        </div>
      )}
      {filtered.map((d) => {
        const label = d.title?.trim() || (d.session_id ? shortId(d.session_id) : "(no id)");
        const tooltip = d.title
          ? `Resume: ${d.title}\n${d.jsonl_path}`
          : `Resume\n${d.jsonl_path}`;
        return (
          <button
            key={d.jsonl_path}
            type="button"
            className="discovered-row"
            onClick={() => onResume(d)}
            disabled={resuming || !d.session_id}
            title={tooltip}
          >
            <span className={`discovered-row-agent agent-${d.agent}`}>
              <AgentIcon
                icon={profileByIntrospect[d.agent]?.icon}
                variant={profileByIntrospect[d.agent]?.icon_variant}
                fallbackChar={
                  profileByIntrospect[d.agent]?.display_name ?? d.agent
                }
                size={14}
              />
            </span>
            <span
              className={
                "discovered-row-title" + (d.title ? "" : " discovered-row-title-id")
              }
            >
              {label}
            </span>
            <span className="discovered-row-time">{relative(d.modified_at_ms)}</span>
          </button>
        );
      })}
    </div>
  );
}

function shortId(id: string): string {
  return id.length <= 10 ? id : `${id.slice(0, 10)}…`;
}

function relative(ms: number): string {
  if (!ms) return "";
  const diff = Date.now() - ms;
  if (diff < 60_000) return "now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h`;
  const days = Math.floor(diff / 86_400_000);
  if (days < 30) return `${days}d`;
  return new Date(ms).toLocaleDateString();
}
