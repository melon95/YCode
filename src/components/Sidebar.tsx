import { useEffect, useMemo, useRef, useState } from "react";
import { toast } from "@heroui/react";
import { LAYOUT_CAP, useStore } from "../lib/store";
import {
  createSession,
  listenSessionEvents,
  scanWorkspaceSessions,
} from "../lib/ipc";
import {
  sessionLight,
  SESSION_LIGHT_LABEL,
  type SessionLight,
  type SessionView,
  type AgentProfileView,
  type DiscoveredSessionView,
  type ProjectView,
} from "../lib/types";
import { AgentIcon } from "./AgentIcon";
import { StatusDot } from "./ui/StatusDot";
import { SidebarToggle } from "./ui/SidebarToggle";
import { statusFromLight, STATUS_RANK } from "../lib/sessionStatus";
import {
  bucketSessions,
  mergeSessions,
  type MergedSession,
} from "../lib/sessionList";

interface SidebarProps {
  /// Hides the sidebar. Optional so the component still renders standalone
  /// in tests, where there is no surrounding column to collapse.
  onToggleSidebar?: () => void;
}

function ChevronIcon({ open }: { open: boolean }) {
  return (
    <svg
      className={"sec-chevron" + (open ? " open" : "")}
      width="11"
      height="11"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden
    >
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`;
  return `${Math.floor(diff / 86_400_000)} 天前`;
}

export function Sidebar({ onToggleSidebar }: SidebarProps) {
  const [creating, setCreating] = useState(false);
  const [historyOpen, setHistoryOpen] = useState(false);
  const [showAllAgents, setShowAllAgents] = useState(true);
  const upsertSession = useStore((s) => s.upsertSession);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  // The footer button opens the agent picker rather than starting a session
  // outright — that's the preview's behaviour, and it's the honest one: the
  // sidebar's agent filter is a *view* control, so using it as the implicit
  // launch target meant the button did something different depending on a
  // pill you may have clicked minutes ago. ⌘N still takes the fast path.
  const showNewSessionPicker = useStore((s) => s.showNewSessionPicker);
  const projects = useStore((s) => s.projects);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const activeProject = activeProjectId ? projects[activeProjectId] : null;
  const agents = useStore((s) => s.agents);
  const sessions = useStore((s) => s.sessions);
  const activityBySession = useStore((s) => s.activityBySession);

  // Agent filter tabs = every configured profile whose command resolves on
  // PATH. Unavailable agents are hidden entirely (per user request) — the
  // Settings dialog is where the user discovers what's configured but not
  // installed.
  const agentTabs = useMemo(() => agents.filter((a) => a.available), [agents]);
  // The row can't scroll (that would clip the count badges), so it shows the
  // first few and folds the rest into a "+N" chip. Most setups have two or
  // three agents; this only bites at five or more.
  const AGENT_PILL_CAP = 4;
  const shownAgentTabs = agentTabs.slice(0, AGENT_PILL_CAP);
  const hiddenAgentTabs = agentTabs.slice(AGENT_PILL_CAP);
  // Cap-aware "+ new session" button. The layout reducer would silently
  // replace-focused-slot at cap, but we'd rather block the click so the
  // user doesn't accidentally lose a pane they were looking at.
  const visibleCount = useStore((s) => s.layout.visibleIds.length);
  const atCap = visibleCount >= LAYOUT_CAP;
  const visibleIds = useStore((s) => s.layout.visibleIds);

  // Live sessions of the active project, ordered by how much they want your
  // attention (blocked first, then error/working, then finished). This is the
  // list the redesign leads with: the discovered-transcript list below is for
  // *resuming* past work, this one is for the work already running.
  const liveSessions = useMemo(() => {
    if (!activeProjectId) return [];
    const rows = Object.values(sessions).filter(
      (s) => s.project_id === activeProjectId && s.archived_at_ms == null,
    );
    return rows.sort((a, b) => {
      const ra = STATUS_RANK[statusFromLight(sessionLight(a.status, activityBySession[a.id]))];
      const rb = STATUS_RANK[statusFromLight(sessionLight(b.status, activityBySession[b.id]))];
      if (ra !== rb) return ra - rb;
      return b.updated_at_ms - a.updated_at_ms;
    });
  }, [sessions, activeProjectId, activityBySession]);

  // The "更早" group opens itself only when it's the whole list — otherwise
  // it would bury this week's work under two months of history. A manual
  // toggle pins it either way. (It has to be able to close again too: the
  // first render happens before the store is populated, so a one-way
  // "open when empty" rule would leave it open forever.)
  const historyPinnedRef = useRef(false);

  const agentByProfileId = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);

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
  // introspect id → the profile that parses it, so a transcript-only row can
  // resolve to an icon and a display name.
  const profileByIntrospect = useMemo(() => {
    const map: Record<string, AgentProfileView> = {};
    for (const a of agents) {
      if (a.introspect && !(a.introspect in map)) map[a.introspect] = a;
    }
    return map;
  }, [agents]);

  // The whole project as one list: sessions ycode started, transcripts found
  // on disk, and the overlap between them folded together.
  const allRows = useMemo(
    () =>
      mergeSessions({
        live: liveSessions,
        discovered: items,
        agentByProfileId,
        profileByIntrospect,
        activityBySession,
        visibleIds,
      }),
    [
      liveSessions,
      items,
      agentByProfileId,
      profileByIntrospect,
      activityBySession,
      visibleIds,
    ],
  );

  // Per-agent counts for the filter pills' badges. Counted off the merged
  // rows rather than the raw DB list — a conversation resumed four times was
  // being counted four times, so the badge read 23 for 16 conversations.
  const countByProfile = useMemo(() => {
    const out: Record<string, number> = {};
    for (const r of allRows) {
      const id = r.live?.agent_profile ?? r.profile?.id;
      if (id) out[id] = (out[id] ?? 0) + 1;
    }
    return out;
  }, [allRows]);

  const shownRows = useMemo(() => {
    if (showAllAgents) return allRows;
    // The filter is by launch profile, but a transcript-only row only knows
    // its introspect id — so match either way round.
    return allRows.filter(
      (r) =>
        r.live?.agent_profile === activeAgent ||
        (r.live == null && r.profile?.id === activeAgent),
    );
  }, [allRows, showAllAgents, activeAgent]);

  // Blocked sessions are hoisted out of the list into their own block: with
  // 25 sessions in a project, one that stopped and scrolled out of view is a
  // stalled agent you don't know about.
  const waitingRows = useMemo(
    () => shownRows.filter((r) => r.light === "waiting"),
    [shownRows],
  );
  const mergedRows = useMemo(
    () => shownRows.filter((r) => r.light !== "waiting"),
    [shownRows],
  );
  const buckets = useMemo(() => bucketSessions(mergedRows), [mergedRows]);

  /// One click, two meanings — but only one to the user. A row ycode owns
  /// opens its existing pane; a transcript-only row resumes into a new one.
  function openRow(row: MergedSession) {
    if (row.live) {
      openSessionInLayout(row.live.id);
      return;
    }
    if (row.discovered && activeProject) {
      void onResume(row.discovered, activeProject);
    }
  }

  const statusByProfile = useMemo(() => {
    const latest = new Map<string, SessionView>();
    for (const session of Object.values(sessions)) {
      if (session.project_id !== activeProjectId || session.archived_at_ms) continue;
      const current = latest.get(session.agent_profile);
      if (!current || session.updated_at_ms > current.updated_at_ms) {
        latest.set(session.agent_profile, session);
      }
    }
    const result = new Map<string, { light: SessionLight; label: string }>();
    for (const [profileId, session] of latest) {
      const light = sessionLight(session.status, activityBySession[session.id]);
      result.set(profileId, {
        light,
        label: SESSION_LIGHT_LABEL[light],
      });
    }
    return result;
  }, [activeProjectId, activityBySession, sessions]);
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
        {onToggleSidebar && (
          <SidebarToggle collapsed={false} onToggle={onToggleSidebar} />
        )}
        <div className="sidebar-agent-tabs" role="tablist" aria-label="Agent filter">
          {/* "All" is a filter value like any other, so it lives in the same
              row rather than as a separate clear-filter affordance. */}
          <button
            type="button"
            role="tab"
            aria-selected={userPickedAgent === null && showAllAgents}
            className={
              "sidebar-agent-tab is-all" +
              (showAllAgents ? " active" : "")
            }
            onClick={() => setShowAllAgents(true)}
            title="全部 agent"
          >
            ALL
          </button>
          {shownAgentTabs.map((profile) => {
            const status = statusByProfile.get(profile.id);
            const historyLabel = profile.introspect
              ? `只看 ${profile.display_name} 的会话`
              : `${profile.display_name}(无会话历史)`;
            return (
              <button
                key={profile.id}
                type="button"
                role="tab"
                aria-label={`${profile.display_name}${status ? `, ${status.label}` : ""}`}
                aria-selected={activeAgent === profile.id}
                className={
                  `sidebar-agent-tab agent-${profile.id}` +
                  (!showAllAgents && activeAgent === profile.id ? " active" : "")
                }
                onClick={() => {
                  setShowAllAgents(false);
                  setUserPickedAgent(profile.id);
                }}
                title={`${historyLabel}${status ? ` · ${status.label}` : ""}`}
              >
                <AgentIcon
                  icon={profile.icon}
                  variant={profile.icon_variant}
                  fallbackChar={profile.display_name}
                  size={20}
                />
                {countByProfile[profile.id] ? (
                  <span className="count-badge count-badge-float">
                    {countByProfile[profile.id]}
                  </span>
                ) : null}
              </button>
            );
          })}
          {hiddenAgentTabs.length > 0 && (
            <span
              className="sidebar-agent-more"
              title={hiddenAgentTabs.map((a) => a.display_name).join(" · ")}
            >
              +{hiddenAgentTabs.length}
            </span>
          )}
        </div>
      </div>

      {/* One list, two sources. A session ycode started and the transcript it
          wrote are the same conversation, so they're merged on the CLI
          session id rather than shown as two lists the user has to
          cross-reference. See lib/sessionList.ts for why that id is the right
          join key — and why the resumed-session duplicates disappear with it.

          Everything below scrolls as one column: with up to four groups, a
          per-group scroller would slice the sidebar into equal strips. */}
      <div className="sidebar-scroll">
      {waitingRows.length > 0 && (
        <div className="needs-you">
          <div className="sidebar-section-heading needs-you-head">
            <span>等你处理</span>
            <span className="sidebar-section-context">{waitingRows.length}</span>
          </div>
          {waitingRows.map((row) => (
            <SessionRowButton key={row.key} row={row} onOpen={openRow} />
          ))}
        </div>
      )}

      {buckets.active.length > 0 && (
        <>
          <div className="sidebar-section-heading">
            <span>进行中</span>
            <span className="sidebar-section-context">
              {activeProject?.name ?? ""}
            </span>
          </div>
          <div className="sidebar-live">
            {buckets.active.map((row) => (
              <SessionRowButton key={row.key} row={row} onOpen={openRow} />
            ))}
          </div>
        </>
      )}

      {buckets.recent.length > 0 && (
        <>
          <div className="sidebar-section-heading">
            <span>最近 7 天</span>
            <span className="sidebar-section-context">
              {buckets.recent.length}
            </span>
          </div>
          <div className="sidebar-live">
            {buckets.recent.map((row) => (
              <SessionRowButton key={row.key} row={row} onOpen={openRow} />
            ))}
          </div>
        </>
      )}

      {/* Collapsed by default: a project with two months of history has
          dozens of these, and none of them is what you came for. */}
      {buckets.older.length > 0 && (
        <>
          <button
            type="button"
            className={
              "sidebar-section-heading is-toggle" + (historyOpen ? " open" : "")
            }
            onClick={() => {
              historyPinnedRef.current = true;
              setHistoryOpen((v) => !v);
            }}
            aria-expanded={historyOpen}
          >
            <ChevronIcon open={historyOpen} />
            <span title="更早的会话,点开可恢复继续">更早</span>
            <span className="sidebar-section-context">
              {buckets.older.length}
            </span>
          </button>
          <div className="sidebar-live" hidden={!historyOpen}>
            {buckets.older.map((row) => (
              <SessionRowButton key={row.key} row={row} onOpen={openRow} />
            ))}
          </div>
        </>
      )}

      {scanError && (
        <div className="sidebar-scan-error" title={scanError}>
          扫描 transcript 失败,列表可能不全
        </div>
      )}
      {!scanning && mergedRows.length === 0 && waitingRows.length === 0 && (
        <div className="sidebar-live-empty">
          {activeProject
            ? "这个项目还没有会话。用下面的按钮开一个。"
            : "还没有选中项目。"}
        </div>
      )}
      </div>
      {/* Always present, even while the picker fills the canvas: the button
          is where a user's hand goes for "another one", and hiding it made
          that depend on what the middle column happened to be showing. */}
      <div className="sidebar-footer">
        <button
          type="button"
          className="new-session-btn"
          onClick={showNewSessionPicker}
          disabled={!activeProject || creating || atCap}
          aria-label={
            atCap
              ? `已达 ${LAYOUT_CAP} 个面板上限,先关一个`
              : "新建会话"
          }
          title={
            atCap
              ? `已达 ${LAYOUT_CAP} 个面板上限,先关一个`
              : "新建会话 —— 打开 agent 选择器"
          }
        >
          <span className="nsb-plus" aria-hidden>
            <PlusIcon />
          </span>
          <span className="nsb-label">{creating ? "启动中…" : "新建会话"}</span>
          <kbd aria-hidden>⇧⌘N</kbd>
        </button>
      </div>
    </aside>
  );
}

function PlusIcon() {
  return (
    <svg
      width="14"
      height="14"
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      aria-hidden
    >
      <path d="M12 5v14M5 12h14" />
    </svg>
  );
}

/// One row in the merged list. Renders the same shape whether it came from
/// the DB, the transcript scan, or both — which is the whole point: the user
/// is looking at a conversation, not at our two storage mechanisms.
function SessionRowButton({
  row,
  onOpen,
}: {
  row: MergedSession;
  onOpen: (row: MergedSession) => void;
}) {
  const status = row.light ? statusFromLight(row.light) : "idle";
  // 副行只标注仍需注意的状态(进行中 / 等你处理 / 出错)。「已结束」和
  // 「可恢复」不写 —— 历史会话本来就都可以恢复,逐行重复只是噪音。
  const activeLabel =
    row.light && row.light !== "done" ? SESSION_LIGHT_LABEL[row.light] : null;
  // 焦点会话的背景高亮(预览稿 .sess.active)。琥珀指示条回答的是
  // 「在不在画布上」,这个背景回答的是「键盘现在打到谁」—— 两件事。
  const isActive = useStore((s) => row.live != null && s.activeId === row.live.id);
  return (
    <button
      type="button"
      className={
        "live-row" +
        (row.paneIdx >= 0 ? " is-open" : "") +
        (isActive ? " is-active" : "")
      }
      onClick={() => onOpen(row)}
      title={activeLabel ? `${row.title} · ${activeLabel}` : row.title}
    >
      <span className="live-agent">
        <AgentIcon
          icon={row.profile?.icon}
          variant={row.profile?.icon_variant}
          fallbackChar={row.profile?.display_name ?? row.title}
          size={18}
        />
      </span>
      <span className="live-main">
        <span className="live-title">{row.title}</span>
        <span className="live-sub">
          {activeLabel && (
            <>
              {activeLabel}
              {" · "}
            </>
          )}
          {relativeTime(row.updatedAtMs)}
          {row.hasWorktree && (
            <span className="live-worktree" title="运行在独立的 git worktree 里">
              {" · "}
              worktree
            </span>
          )}
        </span>
      </span>
      {row.paneIdx >= 0 && (
        <span className="live-pane" title={`面板 ${row.paneIdx + 1}`}>
          {row.paneIdx + 1}
        </span>
      )}
      <StatusDot status={status} labelled={false} />
    </button>
  );
}
