// 侧边栏里的一个项目分组:组头(名字 + 会话数)+ 组内该项目的会话列表。
//
// 懒加载:transcript 扫描只在分组展开时进行 —— 一个项目两个月的历史
// 扫一次并不便宜,五个项目全量扫五份是布局形态不该强加的代价。收起时
// 缓存保留(组件保持挂载,只是列表 hidden),再展开不用重扫;jsonl
// 变化事件只刷新"当前展开"的分组。

import { useEffect, useMemo, useState } from "react";
import { useStore } from "../lib/store";
import { listenSessionEvents, scanWorkspaceSessions } from "../lib/ipc";
import {
  sessionLight,
  SESSION_LIGHT_LABEL,
  type AgentProfileView,
  type DiscoveredSessionView,
  type ProjectView,
} from "../lib/types";
import { statusFromLight, STATUS_RANK } from "../lib/sessionStatus";
import {
  bucketSessions,
  mergeSessions,
  type MergedSession,
} from "../lib/sessionList";
import { AgentIcon } from "./AgentIcon";
import { StatusDot } from "./ui/StatusDot";
import { OverflowMenu, type MenuAction } from "./ui/OverflowMenu";
import { archiveSessionWithConfirm } from "../lib/sessionActions";
import { removeProjectWithConfirm } from "../lib/projectActions";

function relativeTime(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "刚刚";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)} 分钟前`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)} 小时前`;
  return `${Math.floor(diff / 86_400_000)} 天前`;
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

export function SidebarProjectGroup({
  project,
  expanded,
  onToggle,
  onOpenRow,
  agentFilter,
}: {
  project: ProjectView;
  expanded: boolean;
  onToggle: () => void;
  /// 点会话行。内部会先把该项目设为活跃项目再打开/恢复 —— 对用户是
  /// 一个动作("打开这个会话"),不需要先手动切项目。
  onOpenRow: (project: ProjectView, row: MergedSession) => void;
  /// null = 全部 agent;否则只显示该 launch-profile 的会话。
  agentFilter: string | null;
}) {
  const isActiveProject = useStore((s) => s.activeProjectId === project.id);
  const sessions = useStore((s) => s.sessions);
  const activityBySession = useStore((s) => s.activityBySession);
  const agents = useStore((s) => s.agents);
  const visibleIds = useStore((s) => s.layout.visibleIds);

  const [items, setItems] = useState<DiscoveredSessionView[]>([]);
  const [scanned, setScanned] = useState(false);
  const [scanError, setScanError] = useState<string | null>(null);

  // 懒扫描:首次展开才扫;之后 jsonl 变化时只有仍展开的分组刷新。
  useEffect(() => {
    if (!expanded) return;
    let cancelled = false;
    const refresh = () => {
      scanWorkspaceSessions(project.id)
        .then((found) => {
          if (cancelled) return;
          setItems(found);
          setScanError(null);
        })
        .catch((e) => {
          if (cancelled) return;
          setScanError(String(e));
        })
        .finally(() => {
          if (!cancelled) setScanned(true);
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
  }, [expanded, project.id]);

  const agentByProfileId = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);
  const profileByIntrospect = useMemo(() => {
    const map: Record<string, AgentProfileView> = {};
    for (const a of agents) {
      if (a.introspect && !(a.introspect in map)) map[a.introspect] = a;
    }
    return map;
  }, [agents]);

  const liveSessions = useMemo(() => {
    const rows = Object.values(sessions).filter(
      (s) => s.project_id === project.id && s.archived_at_ms == null,
    );
    return rows.sort((a, b) => {
      const ra =
        STATUS_RANK[statusFromLight(sessionLight(a.status, activityBySession[a.id]))];
      const rb =
        STATUS_RANK[statusFromLight(sessionLight(b.status, activityBySession[b.id]))];
      if (ra !== rb) return ra - rb;
      return b.updated_at_ms - a.updated_at_ms;
    });
  }, [sessions, project.id, activityBySession]);

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

  const shownRows = useMemo(() => {
    if (!agentFilter) return allRows;
    return allRows.filter(
      (r) =>
        r.live?.agent_profile === agentFilter ||
        (r.live == null && r.profile?.id === agentFilter),
    );
  }, [allRows, agentFilter]);

  const waitingRows = useMemo(
    () => shownRows.filter((r) => r.light === "waiting"),
    [shownRows],
  );
  const restRows = useMemo(
    () => shownRows.filter((r) => r.light !== "waiting"),
    [shownRows],
  );
  const buckets = useMemo(() => bucketSessions(restRows), [restRows]);
  const [olderOpen, setOlderOpen] = useState(false);

  // 组头的会话数:展开前用 DB 里的活会话数(便宜且总有),展开扫过后
  // 用合并后的总数。

  return (
    <div className={"sb-project" + (isActiveProject ? " is-current" : "")}>
      {/* ⋮ 不能嵌在展开按钮里(button 套 button 无效),所以行是一个
          容器,展开按钮和菜单并排住在里面。 */}
      <div className="sb-project-head-row">
        <button
          type="button"
          className="sb-project-head"
          onClick={onToggle}
          aria-expanded={expanded}
          title={project.repo_path}
        >
          <ChevronIcon open={expanded} />
          <span className="sb-project-name">{project.name}</span>
        </button>
        <OverflowMenu
          label={`${project.name} 的更多操作`}
          actions={[
            {
              label: "删除",
              destructive: true,
              onClick: () => void removeProjectWithConfirm(project.id),
            },
          ]}
        />
      </div>

      {expanded && (
        <div className="sb-project-body">
          {waitingRows.length > 0 && (
            <div className="needs-you">
              <div className="sidebar-section-heading needs-you-head">
                <span>等你处理</span>
                <span className="sidebar-section-context">{waitingRows.length}</span>
              </div>
              {waitingRows.map((row) => (
                <SessionRowButton
                  key={row.key}
                  row={row}
                  onOpen={(r) => onOpenRow(project, r)}
                />
              ))}
            </div>
          )}

          {buckets.active.length > 0 && (
            <div className="sidebar-live">
              {buckets.active.map((row) => (
                <SessionRowButton
                  key={row.key}
                  row={row}
                  onOpen={(r) => onOpenRow(project, r)}
                />
              ))}
            </div>
          )}

          {buckets.recent.length > 0 && (
            <>
              <div className="sidebar-section-heading">
                <span>最近 7 天</span>
              </div>
              <div className="sidebar-live">
                {buckets.recent.map((row) => (
                  <SessionRowButton
                    key={row.key}
                    row={row}
                    onOpen={(r) => onOpenRow(project, r)}
                  />
                ))}
              </div>
            </>
          )}

          {buckets.older.length > 0 && (
            <>
              <button
                type="button"
                className={
                  "sidebar-section-heading is-toggle" + (olderOpen ? " open" : "")
                }
                onClick={() => setOlderOpen((v) => !v)}
                aria-expanded={olderOpen}
              >
                <ChevronIcon open={olderOpen} />
                <span title="更早的会话,点开可恢复继续">更早</span>
              </button>
              <div className="sidebar-live" hidden={!olderOpen}>
                {buckets.older.map((row) => (
                  <SessionRowButton
                    key={row.key}
                    row={row}
                    onOpen={(r) => onOpenRow(project, r)}
                  />
                ))}
              </div>
            </>
          )}

          {scanError && (
            <div className="sidebar-scan-error" title={scanError}>
              扫描 transcript 失败,列表可能不全
            </div>
          )}
          {scanned && shownRows.length === 0 && (
            <div className="sidebar-live-empty">这个项目还没有会话。</div>
          )}
          {!scanned && shownRows.length === 0 && (
            <div className="sidebar-live-empty">扫描中…</div>
          )}
        </div>
      )}
    </div>
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
  // 焦点会话的背景高亮。琥珀指示条回答的是「在不在画布上」,这个背景
  // 回答的是「键盘现在打到谁」—— 两件事。
  const isActive = useStore((s) => row.live != null && s.activeId === row.live.id);
  // 归档只对 ycode 自己的行有意义 —— 纯 transcript 行(live 为 null)是
  // 磁盘上 agent 写的文件,ycode 没有可归档的东西,也不该去删别人的记录。
  const rowActions: MenuAction[] = row.live
    ? [
        {
          label: "归档",
          destructive: true,
          onClick: () => void archiveSessionWithConfirm(row.live!.id),
        },
      ]
    : [];

  return (
    <div
      className={
        "live-row-wrap" + (row.paneIdx >= 0 ? " is-open" : "") +
        (isActive ? " is-active" : "")
      }
    >
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
      <OverflowMenu label={`${row.title} 的更多操作`} actions={rowActions} />
    </div>
  );
}
