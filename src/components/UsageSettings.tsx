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
import { getAllUsage, getWorkspaceUsage } from "../lib/ipc";
import type { SessionUsageView, WorkspaceUsageView } from "../lib/types";
import { AgentIcon } from "./AgentIcon";

export function UsageSettings() {
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
    return <div className="settings-loading">Crunching session logs…</div>;
  }
  if (error) {
    return <div className="usage-empty">Failed to load usage: {error}</div>;
  }
  if (!usage || usage.sessions.length === 0) {
    return (
      <div className="usage-empty">
        No agent usage found yet. Run Claude Code or Codex in one of your
        projects and it'll show up here.
      </div>
    );
  }

  return <UsageReport usage={usage} />;
}

function UsageReport({ usage }: { usage: WorkspaceUsageView }) {
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
    <div className="usage-root">
      <p className="settings-section-blurb">
        Token usage and estimated cost across all your projects, read from each
        agent's own session logs. Costs are offline estimates for known model
        families.
      </p>

      {/* ── Part 1: summary across every project ───────────────────────── */}
      <div className="usage-cards">
        <UsageCard label="Estimated cost" value={fmtCost(usage.total_cost_usd)} primary />
        <UsageCard label="Total tokens" value={fmtCompact(totals.total)} />
        <UsageCard label="Sessions" value={`${usage.sessions.length}`} />
      </div>

      <div className="usage-breakdown">
        <BreakdownChip label="Input" value={totals.input} />
        <BreakdownChip label="Output" value={totals.output} />
        <BreakdownChip label="Cache write" value={totals.cache_creation} />
        <BreakdownChip label="Cache read" value={totals.cache_read} />
        {totals.reasoning > 0 && (
          <BreakdownChip label="Reasoning" value={totals.reasoning} />
        )}
      </div>

      {usage.by_project.length > 0 && (
        <section className="usage-block">
          <h3 className="usage-block-title">By project</h3>
          <div className="usage-projects">
            {usage.by_project.map((p) => {
              const ref = maxProjectCost > 0 ? maxProjectCost : 1;
              const val = p.cost_usd > 0 ? p.cost_usd : p.tokens.total;
              const pct = Math.max(2, (val / ref) * 100);
              return (
                <div className="usage-project-row" key={p.project_id}>
                  <div className="usage-project-head">
                    <span className="usage-project-name">{p.name}</span>
                    <span className="usage-project-meta">
                      {fmtCompact(p.tokens.total)} tokens ·{" "}
                      {Math.round(p.session_count)}{" "}
                      {p.session_count === 1 ? "session" : "sessions"}
                    </span>
                    <span className="usage-project-cost">{fmtCost(p.cost_usd)}</span>
                  </div>
                  <div className="usage-project-track">
                    <div
                      className="usage-project-fill"
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
      <div className="usage-detail">
        <div className="usage-detail-head">
          <h3 className="usage-block-title">Details</h3>
          <div className="usage-scope" role="tablist">
            <button
              type="button"
              role="tab"
              aria-selected={selected == null}
              className={"usage-scope-tab" + (selected == null ? " is-active" : "")}
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
                className={
                  "usage-scope-tab" +
                  (selected === p.project_id ? " is-active" : "")
                }
                onClick={() => setSelected(p.project_id)}
              >
                {p.name}
              </button>
            ))}
          </div>
        </div>

        {detailLoading || !scope ? (
          <div className="settings-loading">Crunching session logs…</div>
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
        <section className="usage-block">
          <h3 className="usage-block-title">Daily</h3>
          <div className="usage-daybars">
            {days.map((d) => {
              const ref = maxDayCost > 0 ? maxDayCost : maxDayTokens;
              const val = maxDayCost > 0 ? d.cost_usd : d.tokens.total;
              const pct = ref > 0 ? Math.max(2, (val / ref) * 100) : 0;
              return (
                <div
                  className="usage-daybar"
                  key={d.date}
                  title={`${d.date} · ${fmtCost(d.cost_usd)} · ${fmtCompact(d.tokens.total)} tokens`}
                >
                  <div className="usage-daybar-track">
                    <div
                      className="usage-daybar-fill"
                      style={{ height: `${pct}%` }}
                    />
                  </div>
                  <span className="usage-daybar-label">{d.date.slice(5)}</span>
                </div>
              );
            })}
          </div>
        </section>
      )}

      {usage.by_model.length > 0 && (
        <section className="usage-block">
          <h3 className="usage-block-title">By model</h3>
          <div className="usage-models">
            {usage.by_model.map((m) => (
              <div className="usage-model-row" key={m.model}>
                <span className="usage-model-name">{m.model}</span>
                <span className="usage-model-tokens">
                  {fmtCompact(m.tokens.total)} tokens
                </span>
                <span className="usage-model-cost">{fmtCost(m.cost_usd)}</span>
              </div>
            ))}
          </div>
        </section>
      )}

      {showSessions && sessionGroups.length > 0 && activeGroup && (
        <section className="usage-block">
          <div className="usage-sessions-head">
            <h3 className="usage-block-title">Sessions</h3>
            <div className="usage-agent-tabs" role="tablist" aria-label="Agent CLI">
              {sessionGroups.map((g) => {
                const meta = agentMeta(g.agent);
                const selected = g.agent === activeAgent;
                return (
                  <button
                    type="button"
                    role="tab"
                    key={g.agent}
                    aria-selected={selected}
                    className={"usage-agent-tab" + (selected ? " is-active" : "")}
                    onClick={() => setSelectedAgent(g.agent)}
                  >
                    <AgentIcon
                      icon={meta.icon}
                      fallbackChar={meta.label}
                      size={14}
                    />
                    <span className="usage-agent-tab-label">{meta.label}</span>
                    <span className="usage-agent-tab-meta">
                      {g.sessions.length} · {fmtCompact(g.tokens)} tokens
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
          <div className="usage-table">
            <div className="usage-tr usage-th">
              <span>Session</span>
              <span>Model</span>
              <span className="usage-num">Tokens</span>
              <span className="usage-num">Cost</span>
              <span className="usage-num">Last active</span>
            </div>
            {activeGroup.sessions.map((s) => (
              <div className="usage-tr" key={s.jsonl_path}>
                <span className="usage-session">
                  <span
                    className="usage-session-title"
                    title={s.title ?? s.session_id ?? ""}
                  >
                    {s.title || shortId(s.session_id) || "(untitled)"}
                  </span>
                </span>
                <span className="usage-model-cell">{s.model ?? "—"}</span>
                <span className="usage-num">{fmtCompact(s.tokens.total)}</span>
                <span className="usage-num">{fmtCost(s.cost_usd)}</span>
                <span className="usage-num usage-dim">
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
    <div className={"usage-card" + (primary ? " usage-card-primary" : "")}>
      <div className="usage-card-value">{value}</div>
      <div className="usage-card-label">{label}</div>
    </div>
  );
}

function BreakdownChip({ label, value }: { label: string; value: number }) {
  return (
    <div className="usage-chip">
      <span className="usage-chip-label">{label}</span>
      <span className="usage-chip-value">{fmtCompact(value)}</span>
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
      return { label: agent || "Unknown", icon: agent };
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
