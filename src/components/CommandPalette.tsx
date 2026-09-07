// ⌘K command palette — jump-to / run-this for the active project.
//   • Default mode: 会话、项目、命令,外加对当前项目文件名的模糊匹配
//     (VS Code ⌘P 式,客户端过滤,只挑文件不挑目录)。
//   • `@` 前缀 → 只显示「会话」组(不截断到 8 条),用于快速跳转会话。
//
// 曾经还有一个 `>` 前缀,做的是跨会话的 jsonl 全文搜索(命中后弹
// HistoryTab)。它和 `@` 的差别—— 搜对话正文 vs 按名字跳转 —— 光看
// 「历史 / 会话」这两个词分不出来,实际也少有人用,已经整个移除。
// 后端的 `search_sessions` 还留着,要重新接入的话从那里接。
//
// File matching runs synchronously on each keystroke against an in-memory
// list cached on open. Results cap at 50.

import { useEffect, useMemo, useRef, useState } from "react";
import { useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { listFiles } from "../lib/ipc";
import { useStore } from "../lib/store";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { iconForFile } from "../lib/fileIcons";
import { sessionLight, type AgentProfileView } from "../lib/types";
import { statusFromLight, STATUS_RANK, type StatusKind } from "../lib/sessionStatus";
import { AgentIcon } from "./AgentIcon";
import { StatusDot } from "./ui/StatusDot";

const LIMIT = 50;
/// `@` = 只过滤「会话」组,方便快速跳转。
const SESSION_LIST_PREFIX = "@";

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
}

type FileHit = { kind: "file"; path: string; score: number };
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
type Hit = FileHit | ActionHit;

/// 一条结果归在哪个分组标题下。action 自带 `group`;文件只有一种归属。
// 模块级纯函数,拿不到 hook —— 直接用 i18next 实例。分组标题只在渲染
// 期读一次,不需要 hook 那套「语言变了重渲染」的订阅。
function groupCaption(hit: Hit): string {
  return hit.kind === "action" ? hit.group : i18next.t("palette.file");
}

export function CommandPalette({ open, onClose }: CommandPaletteProps) {
  const { t } = useTranslation();
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
  const sessions = useStore((s) => s.sessions);
  const projects = useStore((s) => s.projects);
  const activityBySession = useStore((s) => s.activityBySession);
  const setActiveProjectId = useStore((s) => s.setActiveProjectId);
  const openSessionInLayout = useStore((s) => s.openSessionInLayout);
  const appendSessionToLayout = useStore((s) => s.appendSessionToLayout);
  const setLayoutMode = useStore((s) => s.setLayoutMode);
  // 作用域标签:当前活跃项目名。
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
        group: t("palette.session"),
        label:
          se.title?.trim() ||
          se.agent_thread_name?.trim() ||
          agentByProfileId[se.agent_profile]?.display_name ||
          t("palette.untitledSession"),
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
        group: t("palette.project"),
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
        group: t("palette.command"),
        label: t("palette.newSession"),
        detail: "⌘N",
        score: 0,
        // 与侧边栏新建按钮同一条 store 路径 —— 之前派发的
        // "ycode:new-session" 事件没有任何监听者,命令是个哑弹。
        run: () => useStore.getState().showNewSessionPicker(),
      },
      {
        kind: "action",
        id: "cmd:open-project",
        group: t("palette.command"),
        label: t("palette.openProject"),
        detail: "⌘O",
        score: 0,
        run: fire("ycode:new-project"),
      },
      {
        kind: "action",
        id: "cmd:overview",
        group: t("palette.command"),
        label: t("palette.allProjects"),
        detail: "⇧⌘P",
        score: 0,
        run: fire("ycode:open-overview"),
      },
      {
        kind: "action",
        id: "cmd:settings",
        group: t("palette.command"),
        label: t("palette.openSettings"),
        detail: "⌘,",
        score: 0,
        run: fire("ycode:open-settings"),
      },
      {
        kind: "action",
        id: "cmd:layout-columns",
        group: t("palette.command"),
        label: t("palette.layoutTwoColumns"),
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
  const [focusedIdx, setFocusedIdx] = useState(0);
  const [allFiles, setAllFiles] = useState<string[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);

  // `@` = 只看会话组;其余为默认(会话 + 项目 + 命令 + 文件)模式。
  const sessionListMode = query.startsWith(SESSION_LIST_PREFIX);
  const trimmedQuery = sessionListMode
    ? query.slice(SESSION_LIST_PREFIX.length).trim()
    : query.trim();

  // 搜索是否真的被限在当前项目里 —— 默认模式开始输入之后才是(那时文件
  // 匹配参与结果,而文件列表只来自当前项目)。`@` 的会话列表跨全部项目。
  const scoped = !sessionListMode && trimmedQuery.length > 0;

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

  // 结果全部在客户端算:`@` 过滤内存里的会话列表,默认模式再叠上对
  // `allFiles` 的模糊匹配。没有 IPC,所以不需要防抖或请求竞态保护。
  useEffect(() => {
    if (!open) return;
    if (!activeProjectId) {
      setHits([]);
      return;
    }

    // `@` 模式:只显示会话组(全量,不截断到 8 条),按查询过滤。
    if (sessionListMode) {
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
    } else {
      openFile(hit.path, { preview: true });
      setRightTab("editor");
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

  /// 当前选中的条目 —— 底部提示条要据此决定 ⌘⏎ 是否有意义。
  const focusedHit = hits[focusedIdx];

  const statusText = useMemo(() => {
    if (sessionListMode) {
      if (hits.length === 0) return t("palette.noSessionMatch");
      return null;
    }
    if (trimmedQuery.length === 0) return null;
    if (hits.length === 0) return t("palette.noMatch");
    return null;
  }, [sessionListMode, trimmedQuery, hits.length]);

  useEscapeGuard(onClose, open);

  if (!open) return null;
  return (
    <div
      className="fixed inset-0 flex items-start justify-center pt-[10vh] z-200
        bg-[rgba(var(--shadow-rgb),0.55)]"
      onClick={onClose}
    >
      <div
        className="w-[min(720px,92vw)] max-h-[70vh] bg-surface border border-rule rounded-lg
          shadow-[0_16px_48px_rgba(var(--shadow-rgb),0.6)] flex flex-col overflow-hidden"
        onClick={(e) => e.stopPropagation()}
      >
        {/* 输入行:包住 input,好在右侧放作用域标签。底边框长在这一行上,
            不在 input 上。 */}
        <div className="flex-none flex items-center gap-2.5 pr-3.5 border-b border-rule">
          <input
            ref={inputRef}
            type="text"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKey}
            placeholder={
              sessionListMode ? t("palette.filterSessions") : t("palette.searchAll")
            }
            // `cmd-palette-input` 是无样式钩子:全局焦点环画的是 box-shadow
            // 且规则是 unlayered 的,utility 层压不过它,清除只能写在
            // styles.css 里(见那里的注释)。
            className="cmd-palette-input flex-1 min-w-0 w-full py-3 px-3.5 text-sm
              bg-transparent text-text border-none outline-none font-[inherit]"
            aria-label={
            sessionListMode ? t("palette.filterSessionsAria") : t("palette.searchAria")
          }
            autoComplete="off"
            spellCheck={false}
          />
          {/* 作用域标签:提示搜索被限在哪个项目里。
              只在真的受限时才出现 —— 空查询的默认视图列的是全部项目的会话
              和全部项目本身,那时挂一个项目名是在说谎(而且当前项目在侧栏和
              状态栏各已经写了一次)。历史搜索始终限当前项目;默认模式一旦
              开始输入,文件匹配也只查当前项目的文件列表。 */}
          {activeProjectName && scoped && (
            <span
              className="flex-none max-w-[180px] overflow-hidden text-ellipsis whitespace-nowrap
                font-mono text-[10.5px] text-accent bg-accent-tint rounded-md py-[3px] px-2"
              title={t("palette.currentProject")}
            >
              {activeProjectName}
            </span>
          )}
        </div>
        <div className="flex-1 min-h-0 overflow-y-auto" role="listbox">
          {statusText && (
            <div className="py-3.5 px-4 text-muted text-xs">{statusText}</div>
          )}
          {hits.map((hit, i) => {
            // A group caption is printed once, on the first row of each run —
            // cheaper to read than repeating the label per row. 文件与会话
            // 结果原本没有标题:默认模式下命令组带着标题、文件却直接跟在
            // 后面,读起来像是上一组的延续。
            const caption = groupCaption(hit);
            const prev = hits[i - 1];
            const newGroup = !prev || groupCaption(prev) !== caption;
            const heading = newGroup && (
              <div className="pt-2.5 px-3.5 pb-[5px] text-[9px] font-bold tracking-caps uppercase text-muted">
                {caption}
              </div>
            );

            if (hit.kind === "action") {
              const focused = i === focusedIdx;
              return (
                <div key={hit.id}>
                  {heading}
                  <button
                    type="button"
                    role="option"
                    aria-selected={focused}
                    // 背景由三元统一给出。基础串里若也写 `bg-transparent`,
                    // 它和 `bg-panel-raised` 特异性相同、在样式表里又排在
                    // 后面,会把键盘选中的底色整个压掉(见 HIT_ROW 的注释)。
                    className={`group w-full flex items-center gap-[11px] py-2 px-3.5 border-none
                      text-[inherit] text-left cursor-pointer
                      transition-colors duration-[var(--t-fast)] ease-smooth
                      ${focused ? "bg-panel-raised" : "bg-transparent hover:bg-panel-raised"}`}
                    onMouseEnter={() => setFocusedIdx(i)}
                    // ⌘+点击与 ⌘⏎ 同义:在新面板打开。
                    onClick={(e) => pick(hit, e.metaKey || e.ctrlKey)}
                  >
                    <span
                      className={`flex-none size-[22px] rounded-md flex items-center justify-center
                        text-muted ${focused ? "bg-panel-sunken" : "bg-panel-raised"}`}
                    >
                      {hit.icon ? (
                        <AgentIcon
                          icon={hit.icon.icon}
                          variant={hit.icon.icon_variant}
                          fallbackChar={hit.label}
                          size={16}
                        />
                      ) : (
                        <span
                          className="size-[5px] rounded-full bg-whisper"
                          aria-hidden
                        />
                      )}
                    </span>
                    <span className="flex-1 min-w-0 flex flex-col gap-0.5">
                      <span className="text-[13px] text-text whitespace-nowrap overflow-hidden text-ellipsis">
                        {hit.label}
                      </span>
                      {hit.detail && (
                        <span className="font-mono text-[10.5px] text-subtle whitespace-nowrap overflow-hidden text-ellipsis">
                          {hit.detail}
                        </span>
                      )}
                    </span>
                    {hit.status && (
                      <StatusDot status={hit.status} size="sm" labelled={false} />
                    )}
                  </button>
                </div>
              );
            }
            return (
              <div key={`file:${hit.path}`}>
                {heading}
                <FileHitRow
                  hit={hit}
                  query={trimmedQuery}
                  focused={i === focusedIdx}
                  onHover={() => setFocusedIdx(i)}
                  onClick={() => pick(hit)}
                />
              </div>
            );
          })}
        </div>
        {/* 底部提示条:说明这里生效的按键(⏎ 与 ⌘⏎ 不同,靠猜猜不到)。
            ⌘⏎ 只对会话条目有意义 —— 别的条目按了会回落成普通 ⏎,常驻一
            条按下去没反应的提示比不提示更糟。 */}
        <div className="flex-none flex items-center gap-3.5 py-2 px-3.5 border-t border-rule bg-surface text-[10.5px] text-muted">
          <span>{t("palette.hintSelect")}</span>
          <span>{t("palette.hintOpen")}</span>
          {focusedHit?.kind === "action" && focusedHit.runNewPane && (
            <span>{t("palette.hintOpenPane")}</span>
          )}
          <span>{t("palette.hintClose")}</span>
          <span className="ml-auto font-mono">{t("palette.hintSessionsOnly")}</span>
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
      className={`${HIT_ROW} py-[7px] px-3.5 ${focused ? HIT_ROW_ON : HIT_ROW_OFF}`}
      onMouseEnter={onHover}
      onClick={onClick}
    >
      <div className="flex items-center gap-2 min-w-0">
        {iconUrl && (
          <img className="size-4 flex-none" src={iconUrl} alt="" aria-hidden />
        )}
        <span className="text-[13px] text-text flex-[0_1_auto] whitespace-nowrap overflow-hidden text-ellipsis">
          {highlightMatch(name, query)}
        </span>
        {/* `direction: rtl` 让长路径从左侧省略 —— 尾部的目录名比仓库根更
            能说明这是哪个文件。 */}
        {dir && (
          <span className="text-[11px] text-muted flex-auto min-w-0 whitespace-nowrap overflow-hidden text-ellipsis [direction:rtl] text-left">
            {dir}
          </span>
        )}
      </div>
    </button>
  );
}

/// 注意这里**不写** `bg-transparent`:它和 `bg-panel-raised` 特异性相同,
/// 而在生成的样式表里排在后面,于是会静静地压掉选中态 —— 表现是键盘上下
/// 移动时整行不着色(只有图标那个自带底色的小方块在变),鼠标 hover 却正常
/// (那条带伪类,特异性更高)。背景一律由下面的三元表达式给出。
/// 别写 `border-none`:它设的是 shorthand `border-style: none`,会抹掉
/// `border-b` 依赖的 `--tw-border-style`,分隔线整条消失。其余三边用透明
/// 边框表达「没有」。
const HIT_ROW = `block w-full text-left border border-transparent
  border-b-highlight-hairline text-text cursor-pointer
  transition-colors duration-[var(--t-fast)] ease-smooth`;

/// 选中态跟命令行(`.cmd-row`)统一走 `--panel-raised`。原来这里是
/// `rgba(var(--highlight-rgb), 0.06)`,而 `--highlight-rgb` 在浅色主题下
/// 仍是白色 —— 白底上叠 6% 白等于没有,键盘选中位置根本看不出来。
/// `--panel-raised` 是随主题翻转的真实表面色,深浅两侧都读得出。
const HIT_ROW_ON = "bg-panel-raised";
const HIT_ROW_OFF = "bg-transparent hover:bg-panel-raised";

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
      <mark key={idx} className="bg-transparent text-accent font-semibold">
        {target[idx]}
      </mark>,
    );
    cursor = idx + 1;
  }
  if (cursor < target.length) out.push(target.slice(cursor));
  return out;
}
