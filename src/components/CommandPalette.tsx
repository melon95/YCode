// ⌘K command palette — dual-mode search for the active project.
//   • Default mode: fuzzy file-name search (VS Code ⌘P style). Filters the
//     project's full file list client-side, picks files (not directories),
//     and opens the selection in the right-pane editor.
//   • `>` prefix → cross-session text search across claude + codex jsonl
//     (per plan §8.13 / §9.2). Selecting a hit opens it in a HistoryTab
//     dialog rendered by App.tsx via the `onPick` callback.
//   • `@` 前缀 → 只显示「会话」组(不截断到 8 条),用于快速跳转会话。
//     注意:预览稿里 `>` 是命令前缀,但现网 `>` 一直是历史搜索,用户已
//     习惯,这里保持不变;`#` 与 `>` 语义重复,不再引入。
//
// Session mode is debounced 200ms (it's an IPC call); file mode runs
// synchronously on each keystroke against an in-memory list cached on open.
// Both modes cap displayed results at 50.

import { useEffect, useMemo, useRef, useState } from "react";
import { listFiles, searchSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { iconForFile } from "../lib/fileIcons";
import { sessionLight, type AgentProfileView, type SearchHit } from "../lib/types";
import { statusFromLight, STATUS_RANK, type StatusKind } from "../lib/sessionStatus";
import { AgentIcon } from "./AgentIcon";
import { StatusDot } from "./ui/StatusDot";

const LIMIT = 50;
const SESSION_DEBOUNCE_MS = 200;
/// `>` = 搜索历史记录(既有行为,保持不变)。
const HISTORY_PREFIX = ">";
/// `@` = 只过滤「会话」组,方便快速跳转。
const SESSION_LIST_PREFIX = "@";

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  onPick: (hit: SearchHit) => void;
}

type FileHit = { kind: "file"; path: string; score: number };
type SessionHitWrapped = { kind: "session"; hit: SearchHit };
/// Jump-to / do-this rows. They share the result list with files so one
/// keystroke stream reaches every destination in the app — the palette is
/// the only surface that can answer "take me to the blocked Codex session"
/// without first knowing which project it lives in.
type ActionHit = {
  kind: "action";
  id: string;
  group: string;
  label: string;
  detail?: string;
  icon?: AgentProfileView;
  status?: StatusKind;
  score: number;
  run: () => void;
  /// ⌘⏎ 的变体:强制在新面板打开(只有会话条目提供)。
  runNewPane?: () => void;
};
type Hit = FileHit | SessionHitWrapped | ActionHit;

export function CommandPalette({ open, onClose, onPick }: CommandPaletteProps) {
  const activeProjectId = useStore((s) => s.activeProjectId);
  const workspaceSessionId = useStore((s) =>
    s.activeProjectId
      ? (s.workspaceSessionByProject[s.activeProjectId] ?? null)
      : null,
  );
  const workspaceSession = useStore((s) =>
    workspaceSessionId ? s.sessions[workspaceSessionId] : undefined,
  );
  const targetSessionId =
    workspaceSession?.project_id === activeProjectId && workspaceSession.worktree_path
    ? workspaceSession.id
    : undefined;
  const openFile = useStore((s) => s.openFile);
  const setRightTab = useStore((s) => s.setRightTab);
  const agents = useStore((s) => s.agents);
  // Map introspect id → first matching profile so each hit row can resolve
  // its icon without a hook call per row.
  const profileByIntrospect = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) {
      if (a.introspect && !(a.introspect in out)) out[a.introspect] = a;
    }
    return out;
  }, [agents]);
  const sessions = useStore((s) => s.sessions);
  const projects = useStore((s) => s.projects);
  const activityBySession = useStore((s) => s.activityBySession);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  const appendSessionToLayout = useStore((s) => s.appendSessionToLayout);
  const setLayoutMode = useStore((s) => s.setLayoutMode);
  // `.cmdk-scope` 作用域标签:当前活跃项目名(纯展示)。
  const activeProjectName = activeProjectId
    ? (projects[activeProjectId]?.name ?? null)
    : null;
  const agentByProfileId = useMemo(() => {
    const out: Record<string, AgentProfileView> = {};
    for (const a of agents) out[a.id] = a;
    return out;
  }, [agents]);

  // 会话条目单独成一份「全量」列表:默认模式截断到 8 条防止淹没
  // 项目/命令组,`@` 前缀模式则展示全部。
  const sessionActions = useMemo<ActionHit[]>(() => {
    return Object.values(sessions)
      .filter((se) => se.archived_at_ms == null)
      .map((se) => ({
        se,
        // Fixtures (and any future partial row) may not carry a status —
        // fall back to idle rather than throwing inside the palette.
        status: se.status
          ? statusFromLight(sessionLight(se.status, activityBySession[se.id]))
          : ("idle" as StatusKind),
      }))
      .sort(
        (a, b) =>
          STATUS_RANK[a.status] - STATUS_RANK[b.status] ||
          b.se.updated_at_ms - a.se.updated_at_ms,
      )
      .map(({ se, status }): ActionHit => ({
        kind: "action",
        id: `session:${se.id}`,
        group: "会话",
        label:
          se.title?.trim() ||
          se.agent_thread_name?.trim() ||
          agentByProfileId[se.agent_profile]?.display_name ||
          "未命名会话",
        detail: projects[se.project_id]?.name,
        icon: agentByProfileId[se.agent_profile],
        status,
        score: 0,
        run: () => {
          setActiveProjectId(se.project_id);
          openSessionInLayout(se.id);
        },
        // ⌘⏎:无视 session_open_mode,总是新开一个面板放这个会话。
        runNewPane: () => {
          setActiveProjectId(se.project_id);
          appendSessionToLayout(se.id);
        },
      }));
  }, [
    sessions,
    projects,
    activityBySession,
    agentByProfileId,
    setActiveProjectId,
    openSessionInLayout,
    appendSessionToLayout,
  ]);

  // Everything the palette can *do*, as opposed to everything it can find.
  // Sessions come first and are ordered attention-first, so an empty query
  // already answers "who needs me".
  const actions = useMemo<ActionHit[]>(() => {
    const out: ActionHit[] = [];

    // Deliberately short. The palette is for jumping and running things,
    // not for browsing every session — and 30 rows buried the 项目 and
    // 命令 groups below the fold on an empty query. Typing filters the
    // full set (and `@` shows every session), so nothing is unreachable.
    out.push(...sessionActions.slice(0, 8));

    for (const p of Object.values(projects)) {
      if (p.id === activeProjectId) continue;
      out.push({
        kind: "action",
        id: `project:${p.id}`,
        group: "项目",
        label: p.name,
        detail: p.repo_path,
        score: 0,
        run: () => setActiveProjectId(p.id),
      });
    }

    const fire = (name: string) => () =>
      window.dispatchEvent(new CustomEvent(name));
    out.push(
      {
        kind: "action",
        id: "cmd:new-session",
        group: "命令",
        label: "新建会话",
        detail: "⌘N",
        score: 0,
        // 与侧边栏新建按钮同一条 store 路径 —— 之前派发的
        // "ycode:new-session" 事件没有任何监听者,命令是个哑弹。
        run: () => useStore.getState().showNewSessionPicker(),
      },
      {
        kind: "action",
        id: "cmd:open-project",
        group: "命令",
        label: "打开项目…",
        detail: "⌘O",
        score: 0,
        run: fire("ycode:new-project"),
      },
      {
        kind: "action",
        id: "cmd:overview",
        group: "命令",
        label: "全部项目总览",
        detail: "⇧⌘P",
        score: 0,
        run: fire("ycode:open-overview"),
      },
      {
        kind: "action",
        id: "cmd:settings",
        group: "命令",
        label: "打开设置",
        detail: "⌘,",
        score: 0,
        run: fire("ycode:open-settings"),
      },
      {
        kind: "action",
        id: "cmd:layout-columns",
        group: "命令",
        label: "切换布局:并排两栏",
        detail: "Columns",
        score: 0,
        // setLayoutMode 对当前面板数不合法的模式会静默忽略,
        // 所以这条命令始终可以安全执行。
        run: () => setLayoutMode("columns"),
      },
    );
    return out;
  }, [
    sessionActions,
    projects,
    activeProjectId,
    setLayoutMode,
  ]);

  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [loading, setLoading] = useState(false);
  const [focusedIdx, setFocusedIdx] = useState(0);
  const [allFiles, setAllFiles] = useState<string[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const reqIdRef = useRef(0);

  // `>` = 历史搜索;`@` = 只看会话组;其余为默认(命令 + 文件)模式。
  const historyMode = query.startsWith(HISTORY_PREFIX);
  const sessionListMode = !historyMode && query.startsWith(SESSION_LIST_PREFIX);
  const trimmedQuery = historyMode
    ? query.slice(HISTORY_PREFIX.length).trim()
    : sessionListMode
      ? query.slice(SESSION_LIST_PREFIX.length).trim()
      : query.trim();

  // Auto-focus + reset state when opened.
  useEffect(() => {
    if (open) {
      setQuery("");
      setHits([]);
      setFocusedIdx(0);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  // Load the project's file list once per open. Files for fuzzy matching are
  // filtered to non-directories; directory entries are kept out so the picker
  // never resolves to a path that openFile() can't load.
  useEffect(() => {
    if (!open || !activeProjectId) {
      setAllFiles([]);
      return;
    }
    let cancelled = false;
    listFiles(activeProjectId, targetSessionId)
      .then((entries) => {
        if (cancelled) return;
        setAllFiles(entries.filter((e) => !e.is_dir).map((e) => e.path));
      })
      .catch(() => {
        if (!cancelled) setAllFiles([]);
      });
    return () => {
      cancelled = true;
    };
  }, [open, activeProjectId, targetSessionId]);

  // Run the right search per mode. File mode is synchronous (client-side
  // fuzzy); session mode is a debounced IPC call.
  useEffect(() => {
    if (!open) return;
    if (!activeProjectId) {
      setHits([]);
      setLoading(false);
      return;
    }

    if (historyMode) {
      if (trimmedQuery.length < 2) {
        setHits([]);
        setLoading(false);
        return;
      }
      const myReq = ++reqIdRef.current;
      // Drop any prior-mode hits so the user doesn't see stale file matches
      // flash while the (debounced + IPC) session search is in flight.
      setHits([]);
      setLoading(true);
      const t = window.setTimeout(() => {
        searchSessions(activeProjectId, trimmedQuery, LIMIT)
          .then((results) => {
            if (myReq !== reqIdRef.current) return;
            setHits(results.map((hit) => ({ kind: "session", hit })));
            setFocusedIdx(0);
          })
          .catch(() => {
            if (myReq !== reqIdRef.current) return;
            setHits([]);
          })
          .finally(() => {
            if (myReq === reqIdRef.current) setLoading(false);
          });
      }, SESSION_DEBOUNCE_MS);
      return () => window.clearTimeout(t);
    }

    // `@` 模式:只显示会话组(全量,不截断到 8 条),按查询过滤。
    if (sessionListMode) {
      setLoading(false);
      const matched = sessionActions
        .map((a) => {
          if (trimmedQuery.length === 0) return { ...a, score: 0 };
          const score = fuzzyScore(trimmedQuery, `${a.label} ${a.detail ?? ""}`);
          return score === null ? null : { ...a, score };
        })
        .filter((a): a is ActionHit => a !== null)
        .sort((a, b) => b.score - a.score)
        .slice(0, LIMIT);
      setHits(matched);
      setFocusedIdx(0);
      return;
    }

    // Default mode: actions first, then fuzzy file matches. With an empty
    // query we show the actions alone — that is the "where do I go" case,
    // and listing every file in the repo would bury it.
    setLoading(false);
    const matchedActions = actions
      .map((a) => {
        if (trimmedQuery.length === 0) return { ...a, score: 0 };
        const score = fuzzyScore(trimmedQuery, `${a.label} ${a.detail ?? ""}`);
        return score === null ? null : { ...a, score };
      })
      .filter((a): a is ActionHit => a !== null)
      .sort((a, b) => b.score - a.score)
      .slice(0, 12);

    if (trimmedQuery.length === 0) {
      setHits(matchedActions);
      setFocusedIdx(0);
      return;
    }
    const scored: FileHit[] = [];
    for (const path of allFiles) {
      const score = fuzzyScore(trimmedQuery, path);
      if (score !== null) scored.push({ kind: "file", path, score });
    }
    scored.sort((a, b) => b.score - a.score);
    setHits([...matchedActions, ...scored.slice(0, LIMIT)]);
    setFocusedIdx(0);
  }, [
    open,
    activeProjectId,
    historyMode,
    sessionListMode,
    trimmedQuery,
    allFiles,
    actions,
    sessionActions,
  ]);

  // `newPane` 由 ⌘⏎ 触发:会话条目强制在新面板打开;
  // 其他条目没有 runNewPane,回落到默认行为。
  function pick(hit: Hit, newPane = false) {
    if (hit.kind === "action") {
      if (newPane && hit.runNewPane) hit.runNewPane();
      else hit.run();
      onClose();
    } else if (hit.kind === "file") {
      openFile(hit.path, { preview: true });
      setRightTab("editor");
      onClose();
    } else {
      onPick(hit.hit);
      onClose();
    }
  }

  function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
    // Escape is handled globally by useEscapeGuard (below) so it also works
    // when focus has left the input, and doesn't drop out of fullscreen.
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setFocusedIdx((i) => Math.min(hits.length - 1, i + 1));
      return;
    }
    if (e.key === "ArrowUp") {
      e.preventDefault();
      setFocusedIdx((i) => Math.max(0, i - 1));
      return;
    }
    if (e.key === "Enter" && hits[focusedIdx]) {
      e.preventDefault();
      // ⌘⏎(或 Ctrl⏎)= 在新面板打开。
      pick(hits[focusedIdx], e.metaKey || e.ctrlKey);
    }
  }

  const statusText = useMemo(() => {
    if (historyMode) {
      if (loading) return "正在搜索…";
      if (trimmedQuery.length < 2) return "至少输入 2 个字符才能搜索历史记录。";
      if (hits.length === 0) return "没有匹配的历史记录。";
      return null;
    }
    if (sessionListMode) {
      if (hits.length === 0) return "没有匹配的会话。";
      return null;
    }
    if (trimmedQuery.length === 0) return null;
    if (hits.length === 0) return "没有匹配项 —— 试试 > 历史、@ 会话";
    return null;
  }, [historyMode, sessionListMode, loading, trimmedQuery, hits.length]);

  useEscapeGuard(onClose, open);

  if (!open) return null;
  return (
    <div className="cmd-palette-backdrop" onClick={onClose}>
      <div className="cmd-palette" onClick={(e) => e.stopPropagation()}>
        <div className="cmd-palette-input-row">
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKey}
            placeholder={
              historyMode
                ? "搜索会话记录…"
                : sessionListMode
                  ? "过滤会话…"
                  : "跳转会话、切换项目、执行命令,或用 > 搜索历史记录…"
            }
            className="cmd-palette-input"
            aria-label={
              historyMode
                ? "搜索会话记录"
                : sessionListMode
                  ? "过滤会话"
                  : "搜索或执行命令"
            }
            autoComplete="off"
            spellCheck={false}
          />
          {/* 作用域标签:提示搜索/命令作用在哪个项目上(纯展示)。 */}
          {activeProjectName && (
            <span className="cmdk-scope" title="当前项目">
              {activeProjectName}
            </span>
          )}
        </div>
        <div className="cmd-palette-results" role="listbox">
          {statusText && <div className="cmd-palette-status">{statusText}</div>}
          {hits.map((hit, i) => {
            if (hit.kind === "action") {
              // A group caption is printed once, on the first row of each
              // run — cheaper to read than repeating the label per row.
              const prev = hits[i - 1];
              const newGroup =
                !prev || prev.kind !== "action" || prev.group !== hit.group;
              return (
                <div key={hit.id}>
                  {newGroup && <div className="cmd-group">{hit.group}</div>}
                  <button
                    type="button"
                    role="option"
                    aria-selected={i === focusedIdx}
                    className={`cmd-row${i === focusedIdx ? " focused" : ""}`}
                    onMouseEnter={() => setFocusedIdx(i)}
                    // ⌘+点击与 ⌘⏎ 同义:在新面板打开。
                    onClick={(e) => pick(hit, e.metaKey || e.ctrlKey)}
                  >
                    <span className="cmd-row-icon">
                      {hit.icon ? (
                        <AgentIcon
                          icon={hit.icon.icon}
                          variant={hit.icon.icon_variant}
                          fallbackChar={hit.label}
                          size={16}
                        />
                      ) : (
                        <span className="cmd-row-dot" aria-hidden />
                      )}
                    </span>
                    <span className="cmd-row-main">
                      <span className="cmd-row-label">{hit.label}</span>
                      {hit.detail && (
                        <span className="cmd-row-detail">{hit.detail}</span>
                      )}
                    </span>
                    {hit.status && (
                      <StatusDot status={hit.status} size="sm" labelled={false} />
                    )}
                  </button>
                </div>
              );
            }
            return hit.kind === "file" ? (
              <FileHitRow
                key={`file:${hit.path}`}
                hit={hit}
                query={trimmedQuery}
                focused={i === focusedIdx}
                onHover={() => setFocusedIdx(i)}
                onClick={() => pick(hit)}
              />
            ) : (
              <SessionHitRow
                key={`session:${hit.hit.jsonl_path}:${hit.hit.seq}`}
                hit={hit.hit}
                profile={profileByIntrospect[hit.hit.agent]}
                focused={i === focusedIdx}
                onHover={() => setFocusedIdx(i)}
                onClick={() => pick(hit)}
              />
            );
          })}
        </div>
        {/* 底部提示条:说明这里生效的按键(⏎ 与 ⌘⏎ 不同,靠猜猜不到),
            并如实列出前缀 —— `>` 历史搜索、`@` 会话过滤。 */}
        <div className="cmd-palette-foot">
          <span>↑↓ 选择</span>
          <span>⏎ 打开</span>
          <span>⌘⏎ 在新面板打开</span>
          <span>esc 关闭</span>
          <span className="cmd-foot-right">&gt; 历史 · @ 会话</span>
        </div>
      </div>
    </div>
  );
}

function FileHitRow({
  hit,
  query,
  focused,
  onHover,
  onClick,
}: {
  hit: FileHit;
  query: string;
  focused: boolean;
  onHover: () => void;
  onClick: () => void;
}) {
  const slash = hit.path.lastIndexOf("/");
  const dir = slash >= 0 ? hit.path.slice(0, slash) : "";
  const name = slash >= 0 ? hit.path.slice(slash + 1) : hit.path;
  const iconUrl = iconForFile(name);
  return (
    <button
      type="button"
      role="option"
      aria-selected={focused}
      className={"cmd-palette-hit cmd-palette-hit-file" + (focused ? " focused" : "")}
      onMouseEnter={onHover}
      onClick={onClick}
    >
      <div className="cmd-palette-file-row">
        {iconUrl && (
          <img className="cmd-palette-file-icon" src={iconUrl} alt="" aria-hidden />
        )}
        <span className="cmd-palette-file-name">{highlightMatch(name, query)}</span>
        {dir && <span className="cmd-palette-file-dir">{dir}</span>}
      </div>
    </button>
  );
}

function SessionHitRow({
  hit,
  profile,
  focused,
  onHover,
  onClick,
}: {
  hit: SearchHit;
  profile: AgentProfileView | undefined;
  focused: boolean;
  onHover: () => void;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      role="option"
      aria-selected={focused}
      className={"cmd-palette-hit" + (focused ? " focused" : "")}
      onMouseEnter={onHover}
      onClick={onClick}
    >
      <div className="cmd-palette-hit-meta">
        <span className={`cmd-palette-hit-agent agent-${hit.agent}`}>
          <AgentIcon
            icon={profile?.icon}
            variant={profile?.icon_variant}
            fallbackChar={profile?.display_name ?? hit.agent}
            size={12}
          />{" "}
          {profile?.display_name ?? hit.agent}
        </span>
        <span className="cmd-palette-hit-session">{shortId(hit.session_id)}</span>
        {hit.ts_ms > 0 && (
          <span className="cmd-palette-hit-ts">{formatRelative(hit.ts_ms)}</span>
        )}
      </div>
      <div className="cmd-palette-hit-preview">{hit.preview}</div>
    </button>
  );
}

// Subsequence-based fuzzy score. Returns null if `query` chars don't appear
// in `target` in order (case-insensitive); otherwise returns a score where
// higher = better. Heuristics: matches in the basename outweigh matches in
// the directory; matches right after a separator (`/`, `_`, `-`, `.`) get a
// "word-start" bonus; consecutive matches get a streak bonus. A small length
// penalty prevents long paths with sparse matches from outranking short
// tight ones.
function fuzzyScore(query: string, target: string): number | null {
  if (query.length === 0) return null;
  const q = query.toLowerCase();
  const t = target.toLowerCase();
  const basenameStart = t.lastIndexOf("/") + 1;
  let qi = 0;
  let score = 0;
  let lastMatchIdx = -2;
  for (let i = 0; i < t.length && qi < q.length; i++) {
    if (t[i] !== q[qi]) continue;
    let bonus = 1;
    if (i >= basenameStart) bonus += 3;
    if (i === 0 || isSeparator(t[i - 1])) bonus += 5;
    if (lastMatchIdx + 1 === i) bonus += 3;
    score += bonus;
    lastMatchIdx = i;
    qi++;
  }
  if (qi < q.length) return null;
  score -= t.length * 0.01;
  return score;
}

function isSeparator(ch: string): boolean {
  return ch === "/" || ch === "_" || ch === "-" || ch === ".";
}

// Bold the chars of `target` that participate in a subsequence match with
// `query`. Same matching policy as fuzzyScore; if the match fails (shouldn't
// happen for rendered hits, but defensive), returns the plain text.
function highlightMatch(target: string, query: string): React.ReactNode {
  if (!query) return target;
  const q = query.toLowerCase();
  const t = target.toLowerCase();
  const indices: number[] = [];
  let qi = 0;
  for (let i = 0; i < t.length && qi < q.length; i++) {
    if (t[i] === q[qi]) {
      indices.push(i);
      qi++;
    }
  }
  if (qi < q.length) return target;
  const out: React.ReactNode[] = [];
  let cursor = 0;
  for (const idx of indices) {
    if (idx > cursor) out.push(target.slice(cursor, idx));
    out.push(
      <mark key={idx} className="cmd-palette-match">
        {target[idx]}
      </mark>,
    );
    cursor = idx + 1;
  }
  if (cursor < target.length) out.push(target.slice(cursor));
  return out;
}

function shortId(id: string): string {
  if (id.length <= 8) return id;
  return `${id.slice(0, 8)}…`;
}

function formatRelative(ms: number): string {
  const diff = Date.now() - ms;
  if (diff < 60_000) return "just now";
  if (diff < 3_600_000) return `${Math.floor(diff / 60_000)}m ago`;
  if (diff < 86_400_000) return `${Math.floor(diff / 3_600_000)}h ago`;
  const days = Math.floor(diff / 86_400_000);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString();
}
