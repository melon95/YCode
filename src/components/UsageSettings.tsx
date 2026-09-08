// Settings → Usage. Read-only token usage + estimated cost for the active
// project, aggregated from the agents' own jsonl session files (the same
// source the history viewer reads). Owns its IPC state — there's nothing to
// stage/save here, so the parent SettingsModal doesn't touch it.
//
// Costs are OFFLINE ESTIMATES: the backend prices known model families
// (Claude / GPT / Gemini) from a static table; unknown models still count
// tokens but contribute $0. We surface that caveat in the UI so the number is
// never mistaken for a bill.

import { useEffect, useMemo, useState } from "react";
import { useTranslation } from "react-i18next";
import { i18next } from "../lib/i18n";
import { getAllUsage, getWorkspaceUsage } from "../lib/ipc";
import type { SessionUsageView, WorkspaceUsageView } from "../lib/types";
import { AgentIcon } from "./AgentIcon";

/// 这一页自成一套排版:它是只读报表,不是设置行,所以没走 SettingCard。
const BLOCK_TITLE =
  "m-0 text-[11px] font-semibold text-muted uppercase tracking-[0.045em]";

/// 作用域选择器与 agent 分组共用的胶囊。窄面板下换行。
/// 只放形状与过渡 —— 内边距由调用点给。agent pill 比时间范围 pill 略窄,
/// 若基础串也写一份 `px-[11px]`,它和调用点的 `px-2.5` 特异性相同、在生成的
/// 样式表里又排在后面,窄的那份会被压掉。
const PILL_TAB = `appearance-none border rounded-full text-[12px] cursor-pointer whitespace-nowrap
  transition-[color,background,border-color] duration-[var(--duration-fast)] ease-out`
  .replace(/\s+/g, " ");

/// 时间范围 pill 的内边距。
const PILL_TAB_PAD = "py-1 px-[11px]";
const PILL_TAB_ON = "text-accent bg-accent-ring border-accent";
const PILL_TAB_OFF =
  "text-muted bg-transparent border-rule hover:text-text hover:border-accent";

/// 会话表的列宽。表头与数据行必须同宽,写成一处才不会飘。
const USAGE_TR =
  "grid grid-cols-[minmax(0,1.6fr)_minmax(0,1fr)_64px_64px_70px] gap-2.5 items-center py-[7px] border-b border-rule last:border-b-0";
const USAGE_NUM = "text-right tabular-nums";

/// 迁移前这段在 styles.css 里是斜体 Fraunces,但 design-system.css 随后
/// 把 font-family / font-style / font-variation-settings 三项全重置回了
/// 正常 —— 后者加载在后、同特异性下胜出,所以实际渲染一直是正体 Geist。
/// 这里保留的是「实际生效」的那一层。
const LOADING = "p-[60px] text-center font-ui not-italic text-[16px] text-subtle";

export function UsageSettings() {
  const { t } = useTranslation();
  const [usage, setUsage] = useState<WorkspaceUsageView | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    getAllUsage()
      .then((u) => {
        if (!cancelled) setUsage(u);
      })
      .catch((e) => {
        if (!cancelled) setError(`${e}`);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, []);

  if (loading) {
    return <div className={LOADING}>{t("settings.usage.counting")}</div>;
  }
  if (error) {
    return (
      <div className="text-muted text-[13px]/[1.5] py-6 px-1">
        {t("settings.usage.readFailed", { error })}
      </div>
    );
  }
  if (!usage || usage.sessions.length === 0) {
    return (
      <div className="text-muted text-[13px]/[1.5] py-6 px-1">
        {t("settings.usage.empty")}
      </div>
    );
  }

  return <UsageReport usage={usage} />;
}

function UsageReport({ usage }: { usage: WorkspaceUsageView }) {
  const { t } = useTranslation();
  // `null` = the all-projects rollup; a project id = drill into that project's
  // own detail (fetched lazily, then cached). The top summary always reflects
  // every project; only the lower "Details" panel re-scopes.
  const [selected, setSelected] = useState<string | null>(null);
  const [cache, setCache] = useState<Record<string, WorkspaceUsageView>>({});
  const [detailLoading, setDetailLoading] = useState(false);

  useEffect(() => {
    if (selected == null || cache[selected]) {
      setDetailLoading(false);
      return;
    }
    let cancelled = false;
    setDetailLoading(true);
    getWorkspaceUsage(selected)
      .then((u) => {
        if (!cancelled) setCache((c) => ({ ...c, [selected]: u }));
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setDetailLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selected, cache]);

  // The data that drives the lower "Details" panel. `null` while a freshly
  // selected project is still loading.
  const scope: WorkspaceUsageView | null =
    selected == null ? usage : cache[selected] ?? null;

  const { totals } = usage;
  const maxProjectCost = useMemo(
    () =>
      Math.max(...usage.by_project.map((p) => p.cost_usd || p.tokens.total), 0),
    [usage.by_project],
  );

  return (
    <div className="flex flex-col gap-[18px] py-[22px] px-6 max-w-[760px]">
      <p className="mt-1.5 mx-0 mb-[18px] text-[12.5px]/[1.55] text-muted">
        {t("settings.usage.lede")}
      </p>

      {/* ── Part 1: summary across every project ───────────────────────── */}
      <div className="grid grid-cols-3 gap-2.5">
        <UsageCard label={t("settings.usage.cost")} value={fmtCost(usage.total_cost_usd)} primary />
        <UsageCard label={t("settings.usage.totalTokens")} value={fmtCompact(totals.total)} />
        <UsageCard label={t("settings.usage.sessionCount")} value={`${usage.sessions.length}`} />
      </div>

      <div className="flex flex-wrap gap-2">
        <BreakdownChip label={t("settings.usage.input")} value={totals.input} />
        <BreakdownChip label={t("settings.usage.output")} value={totals.output} />
        <BreakdownChip label={t("settings.usage.cacheWrite")} value={totals.cache_creation} />
        <BreakdownChip label={t("settings.usage.cacheRead")} value={totals.cache_read} />
        {totals.reasoning > 0 && (
          <BreakdownChip label={t("settings.usage.reasoning")} value={totals.reasoning} />
        )}
      </div>

      {usage.by_project.length > 0 && (
        <section className="flex flex-col gap-2.5">
          <h3 className={BLOCK_TITLE}>{t("settings.usage.byProject")}</h3>
          <div className="flex flex-col gap-3">
            {usage.by_project.map((p) => {
              const ref = maxProjectCost > 0 ? maxProjectCost : 1;
              const val = p.cost_usd > 0 ? p.cost_usd : p.tokens.total;
              const pct = Math.max(2, (val / ref) * 100);
              return (
                <div className="flex flex-col gap-[5px]" key={p.project_id}>
                  <div className="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-3 items-baseline text-[12px]">
                    <span className="text-text font-medium overflow-hidden text-ellipsis whitespace-nowrap">{p.name}</span>
                    <span className="text-muted text-[11px] tabular-nums whitespace-nowrap">
                      {/* 原本这里是手写的 `count === 1 ? "session" : "sessions"`
                          外加硬编码的 "tokens" —— 中文界面下会漏出英文。
                          复用 groupSummary 这条词条,复数由 i18next 决定。 */}
                      {t("settings.usage.groupSummary", {
                        count: Math.round(p.session_count),
                        tokens: fmtCompact(p.tokens.total),
                      })}
                    </span>
                    <span className="text-text tabular-nums min-w-[56px] text-right">{fmtCost(p.cost_usd)}</span>
                  </div>
                  <div className="h-1.5 rounded-[3px] bg-rule overflow-hidden">
                    <div
                      className="h-full min-w-0.5 rounded-[3px] bg-accent transition-[width] duration-[var(--duration-fast)] ease-out"
                      style={{ width: `${pct}%` }}
                    />
                  </div>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {/* ── Part 2: detail, scoped via the tab selector ────────────────── */}
      <div className="flex flex-col gap-[18px]">
        <div className="flex flex-col gap-2.5">
          <h3 className={BLOCK_TITLE}>{t("settings.usage.detail")}</h3>
          <div className="flex flex-wrap gap-1.5" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={selected == null}
              className={`${PILL_TAB} ${PILL_TAB_PAD} ${selected == null ? PILL_TAB_ON : PILL_TAB_OFF}`}
              onClick={() => setSelected(null)}
            >
              All projects
            </button>
            {usage.by_project.map((p) => (
              <button
                type="button"
                role="tab"
                key={p.project_id}
                aria-selected={selected === p.project_id}
                className={`${PILL_TAB} ${PILL_TAB_PAD} ${
                  selected === p.project_id ? PILL_TAB_ON : PILL_TAB_OFF
                }`}
                onClick={() => setSelected(p.project_id)}
              >
                {p.name}
              </button>
            ))}
          </div>
        </div>

        {detailLoading || !scope ? (
          <div className={LOADING}>{t("settings.usage.counting")}</div>
        ) : (
          <UsageDetail usage={scope} showSessions={selected != null} />
        )}
      </div>
    </div>
  );
}

/** The Daily / By model / Sessions panel for one scope. */
function UsageDetail({
  usage,
  showSessions,
}: {
  usage: WorkspaceUsageView;
  showSessions: boolean;
}) {
  const { t } = useTranslation();
  // Day chart: just the last 7 days with usage — enough to read the recent
  // trend without the bars spanning months of sparse history.
  const days = useMemo(
    () => usage.by_day.filter((d) => d.date !== "unknown").slice(-7),
    [usage.by_day],
  );
  const maxDayCost = useMemo(
    () => Math.max(...days.map((d) => d.cost_usd), 0),
    [days],
  );
  const maxDayTokens = useMemo(
    () => Math.max(...days.map((d) => d.tokens.total), 0),
    [days],
  );
  // Sessions split by the CLI that produced them (Claude Code / Codex / …),
  // each group ordered by spend. `usage.sessions` is already sorted by recency,
  // so rows within a group keep that order.
  const sessionGroups = useMemo(() => {
    const map = new Map<string, SessionUsageView[]>();
    for (const s of usage.sessions) {
      const arr = map.get(s.agent);
      if (arr) arr.push(s);
      else map.set(s.agent, [s]);
    }
    return [...map.entries()]
      .map(([agent, sessions]) => ({
        agent,
        sessions,
        cost: sessions.reduce((a, s) => a + s.cost_usd, 0),
        tokens: sessions.reduce((a, s) => a + s.tokens.total, 0),
      }))
      .sort((a, b) => b.cost - a.cost || b.tokens - a.tokens);
  }, [usage.sessions]);
  const [selectedAgent, setSelectedAgent] = useState<string | null>(null);
  const activeAgent = sessionGroups.some((g) => g.agent === selectedAgent)
    ? selectedAgent
    : (sessionGroups[0]?.agent ?? null);
  const activeGroup = sessionGroups.find((g) => g.agent === activeAgent) ?? null;

  return (
    <>
      {days.length > 1 && (
        <section className="flex flex-col gap-2.5">
          <h3 className={BLOCK_TITLE}>{t("settings.usage.byDay")}</h3>
          <div className="flex items-end gap-1 h-24">
            {days.map((d) => {
              const ref = maxDayCost > 0 ? maxDayCost : maxDayTokens;
              const val = maxDayCost > 0 ? d.cost_usd : d.tokens.total;
              const pct = ref > 0 ? Math.max(2, (val / ref) * 100) : 0;
              return (
                <div
                  className="flex-1 flex flex-col items-center gap-1 min-w-0 h-full"
                  key={d.date}
                  title={`${d.date} · ${fmtCost(d.cost_usd)} · ${fmtCompact(d.tokens.total)} tokens`}
                >
                  <div className="flex-1 w-full flex items-end">
                    <div
                      className="w-full min-h-0.5 rounded-t-[3px] bg-accent transition-[height] duration-[var(--duration-fast)] ease-out"
                      style={{ height: `${pct}%` }}
                    />
                  </div>
                  <span className="text-[9px] text-muted whitespace-nowrap rotate-[-45deg] origin-center">{d.date.slice(5)}</span>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {usage.by_model.length > 0 && (
        <section className="flex flex-col gap-2.5">
          <h3 className={BLOCK_TITLE}>{t("settings.usage.byModel")}</h3>
          <div className="flex flex-col">
            {usage.by_model.map((m) => (
              <div className="grid grid-cols-[1fr_auto_auto] gap-3 items-center py-[7px] border-b border-rule last:border-b-0 text-[12px]" key={m.model}>
                <span className="font-mono text-text overflow-hidden text-ellipsis whitespace-nowrap">{m.model}</span>
                <span className="text-muted tabular-nums">
                  {fmtCompact(m.tokens.total)} tokens
                </span>
                <span className="text-text tabular-nums min-w-[56px] text-right">{fmtCost(m.cost_usd)}</span>
              </div>
            ))}
          </div>
        </section>
      )}

      {showSessions && sessionGroups.length > 0 && activeGroup && (
        <section className="flex flex-col gap-2.5">
          <div className="flex flex-col gap-2.5">
            <h3 className={BLOCK_TITLE}>{t("settings.usage.sessions")}</h3>
            <div className="flex flex-wrap gap-1.5" role="tablist" aria-label="Agent CLI">
              {sessionGroups.map((g) => {
                const meta = agentMeta(g.agent);
                const selected = g.agent === activeAgent;
                return (
                  <button
                    type="button"
                    role="tab"
                    key={g.agent}
                    aria-selected={selected}
                    className={`${PILL_TAB} inline-flex items-center gap-[7px] min-w-0 max-w-full px-2.5 py-[5px] group ${selected ? PILL_TAB_ON : PILL_TAB_OFF}`}
                    onClick={() => setSelectedAgent(g.agent)}
                  >
                    <AgentIcon
                      icon={meta.icon}
                      fallbackChar={meta.label}
                      size={14}
                    />
                    <span className="font-semibold overflow-hidden text-ellipsis whitespace-nowrap text-text group-aria-selected:text-accent">{meta.label}</span>
                    <span className="text-muted text-[11px] tabular-nums whitespace-nowrap">
                      {t("settings.usage.groupSummary", {
                    count: g.sessions.length,
                    tokens: fmtCompact(g.tokens),
                  })}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
          <div className="flex flex-col text-[12px]">
            <div className={`${USAGE_TR} text-muted text-[10px] uppercase tracking-caps`}>
              <span>{t("settings.usage.sessions")}</span>
              <span>{t("settings.usage.model")}</span>
              <span className={USAGE_NUM}>Token</span>
              <span className={USAGE_NUM}>{t("settings.usage.costCol")}</span>
              <span className={USAGE_NUM}>{t("settings.usage.lastActive")}</span>
            </div>
            {activeGroup.sessions.map((s) => (
              <div className={USAGE_TR} key={s.jsonl_path}>
                <span className="flex items-center gap-2 min-w-0">
                  <span
                    className="overflow-hidden text-ellipsis whitespace-nowrap text-text"
                    title={s.title ?? s.session_id ?? ""}
                  >
                    {s.title || shortId(s.session_id) || "(untitled)"}
                  </span>
                </span>
                <span className="font-mono text-muted overflow-hidden text-ellipsis whitespace-nowrap">{s.model ?? "—"}</span>
                <span className={USAGE_NUM}>{fmtCompact(s.tokens.total)}</span>
                <span className={USAGE_NUM}>{fmtCost(s.cost_usd)}</span>
                <span className={`${USAGE_NUM} text-muted`}>
                  {fmtDate(s.last_ts_ms)}
                </span>
              </div>
            ))}
          </div>
        </section>
      )}
    </>
  );
}

function UsageCard({
  label,
  value,
  primary,
}: {
  label: string;
  value: string;
  primary?: boolean;
}) {
  return (
    <div
      className={`flex flex-col gap-1 p-3.5 border rounded-md ${
        primary
          ? "border-accent-40 bg-accent-tint"
          : "border-rule bg-panel-sunken"
      }`}
    >
      <div className="font-ui text-[22px] font-semibold text-text tracking-[-0.01em]">{value}</div>
      <div className="text-[11px] text-muted uppercase tracking-[0.045em]">{label}</div>
    </div>
  );
}

function BreakdownChip({ label, value }: { label: string; value: number }) {
  return (
    <div className="flex items-baseline gap-1.5 py-[5px] px-2.5 border border-rule rounded-full text-[12px]">
      <span className="text-muted">{label}</span>
      <span className="font-mono text-text">{fmtCompact(value)}</span>
    </div>
  );
}

/** Display label + brand-icon key for a backend agent id. */
function agentMeta(agent: string): { label: string; icon: string } {
  switch (agent) {
    case "claude":
      return { label: "Claude Code", icon: "ClaudeCode" };
    case "codex":
      return { label: "Codex", icon: "Codex" };
    case "gemini":
      return { label: "Gemini CLI", icon: "GeminiCLI" };
    default:
      return { label: agent || i18next.t("settings.usage.unknownAgent"), icon: agent };
  }
}

function fmtCompact(n: number): string {
  if (n < 1000) return `${Math.round(n)}`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}K`;
  if (n < 1_000_000_000) return `${(n / 1_000_000).toFixed(n < 10_000_000 ? 1 : 0)}M`;
  return `${(n / 1_000_000_000).toFixed(1)}B`;
}

function fmtCost(usd: number): string {
  if (usd <= 0) return "$0.00";
  if (usd < 0.01) return "<$0.01";
  if (usd < 100) return `$${usd.toFixed(2)}`;
  return `$${usd.toFixed(0)}`;
}

function fmtDate(tsMs: number): string {
  if (!tsMs || tsMs <= 0) return "—";
  const d = new Date(tsMs);
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function shortId(id: string | null): string {
  if (!id) return "";
  return id.length > 8 ? id.slice(0, 8) : id;
}
