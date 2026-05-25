// Read-only structured renderer for a historical agent session. Per plan
// §9.1.2. Loads UnifiedEvent[] via `load_session_history` and renders one
// card per event. Filters by kind; auto-scrolls to a target seq when the
// command palette navigates here. v1 has no virtual scroll — sessions over
// ~5k events will be slow but plan §10.5 quotes ~50 message first-paint as
// the budget so we're well inside it for normal sessions.

import { useEffect, useMemo, useRef, useState } from "react";
import { loadSessionHistory, listenSessionEvents } from "../lib/ipc";
import type { UnifiedEvent, UnifiedEventKind } from "../lib/types";
import { AgentIcon } from "./AgentIcon";
import { useAgentByIntrospect } from "../lib/store";

const HISTORY_LIMIT = 5000;

interface HistoryTabProps {
  agent: string;
  sessionId: string;
  jsonlPath: string;
  /// Highlight + scroll to this event on first load.
  focusSeq?: number;
  /// Pre-computed title from the sidebar scan — shown in the header so users
  /// see "Refactor auth middleware" instead of just a UUID while the body
  /// loads.
  title?: string;
  onClose: () => void;
}

type Filter = "all" | "messages" | "tools";

export function HistoryTab({
  agent,
  sessionId,
  jsonlPath,
  focusSeq,
  title,
  onClose,
}: HistoryTabProps) {
  const [events, setEvents] = useState<UnifiedEvent[]>([]);
  const [filter, setFilter] = useState<Filter>("all");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const focusRef = useRef<HTMLDivElement | null>(null);
  const profile = useAgentByIntrospect(agent);

  // Initial + reload on JsonlChanged for this file.
  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    loadSessionHistory(agent, sessionId, jsonlPath, HISTORY_LIMIT)
      .then((evs) => {
        if (cancelled) return;
        setEvents(evs);
      })
      .catch((e) => {
        if (cancelled) return;
        setError(String(e));
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [agent, sessionId, jsonlPath]);

  // Live tail: when the watcher emits JsonlChanged for this file, refresh.
  useEffect(() => {
    let unlisten: (() => void) | undefined;
    let cancelled = false;
    listenSessionEvents((ev) => {
      if (ev.kind.type !== "JsonlChanged") return;
      if (ev.kind.jsonl_path !== jsonlPath) return;
      loadSessionHistory(agent, sessionId, jsonlPath, HISTORY_LIMIT)
        .then((evs) => {
          if (!cancelled) setEvents(evs);
        })
        .catch(() => {});
    }).then((fn) => {
      if (cancelled) fn();
      else unlisten = fn;
    });
    return () => {
      cancelled = true;
      unlisten?.();
    };
  }, [agent, sessionId, jsonlPath]);

  useEffect(() => {
    if (focusSeq == null) return;
    if (!focusRef.current) return;
    focusRef.current.scrollIntoView({ behavior: "auto", block: "center" });
  }, [focusSeq, events]);

  const filtered = useMemo(() => events.filter(matchesFilter(filter)), [events, filter]);

  return (
    <div className="history-tab" role="dialog" aria-label="Session history">
      <div className="history-tab-header">
        <span className={`history-tab-agent agent-${agent}`}>
          <AgentIcon
            icon={profile?.icon}
            variant={profile?.icon_variant}
            fallbackChar={profile?.display_name ?? agent}
            size={14}
          />{" "}
          {profile?.display_name ?? agent}
        </span>
        {title ? (
          <span className="history-tab-title" title={sessionId}>
            {title}
          </span>
        ) : (
          <span className="history-tab-session" title={sessionId}>
            {sessionId.slice(0, 12)}…
          </span>
        )}
        <span className="history-tab-count">{events.length} events</span>
        <div className="history-tab-filter" role="tablist" aria-label="Filter events">
          {(["all", "messages", "tools"] as Filter[]).map((f) => (
            <button
              key={f}
              type="button"
              role="tab"
              aria-selected={filter === f}
              className={"history-tab-filter-btn" + (filter === f ? " active" : "")}
              onClick={() => setFilter(f)}
            >
              {f}
            </button>
          ))}
        </div>
        <button type="button" className="history-tab-close" onClick={onClose} aria-label="Close">
          ×
        </button>
      </div>
      <div className="history-tab-body">
        {loading && <div className="history-tab-status">Loading session…</div>}
        {error && <div className="history-tab-status error">Failed: {error}</div>}
        {!loading &&
          filtered.map((ev) => (
            <EventCard
              key={`${ev.session_id}:${ev.seq}`}
              event={ev}
              focusRef={ev.seq === focusSeq ? focusRef : undefined}
              highlighted={ev.seq === focusSeq}
            />
          ))}
        {!loading && !error && filtered.length === 0 && (
          <div className="history-tab-status">No events match this filter.</div>
        )}
      </div>
    </div>
  );
}

function matchesFilter(filter: Filter): (ev: UnifiedEvent) => boolean {
  if (filter === "all") return () => true;
  if (filter === "messages") {
    return (ev) =>
      ev.kind.kind === "message" || ev.kind.kind === "thinking";
  }
  return (ev) =>
    ev.kind.kind === "tool_use" ||
    ev.kind.kind === "tool_result" ||
    ev.kind.kind === "edits";
}

function EventCard({
  event,
  focusRef,
  highlighted,
}: {
  event: UnifiedEvent;
  focusRef?: React.RefObject<HTMLDivElement | null>;
  highlighted: boolean;
}) {
  return (
    <div
      ref={focusRef}
      className={"history-card" + (highlighted ? " highlighted" : "")}
      data-kind={event.kind.kind}
    >
      <CardBody kind={event.kind} />
      {event.ts_ms > 0 && (
        <div className="history-card-ts">{new Date(event.ts_ms).toLocaleTimeString()}</div>
      )}
    </div>
  );
}

function CardBody({ kind }: { kind: UnifiedEventKind }) {
  switch (kind.kind) {
    case "message":
      return (
        <>
          <div className={`history-card-role role-${kind.role}`}>
            {kind.role === "user" ? "👤 you" : kind.role === "assistant" ? "🤖 assistant" : `📎 ${kind.role}`}
          </div>
          <pre className="history-card-text">{kind.text}</pre>
        </>
      );
    case "thinking":
      return (
        <>
          <div className="history-card-role role-thinking">💭 thinking</div>
          <pre className="history-card-text dim">{kind.text}</pre>
        </>
      );
    case "tool_use":
      return (
        <>
          <div className="history-card-role role-tool">🔧 {kind.tool}</div>
          <pre className="history-card-text dim">{prettyJson(kind.input_json)}</pre>
        </>
      );
    case "tool_result":
      return (
        <>
          <div className="history-card-role role-tool">
            {kind.status === "error" ? "❌" : "✓"} {kind.tool}
          </div>
          <pre className="history-card-text dim">{kind.output_excerpt}</pre>
        </>
      );
    case "plan":
      return (
        <>
          <div className="history-card-role role-plan">📋 plan</div>
          <ul className="history-card-plan">
            {kind.steps.map((s, i) => (
              <li key={i} data-state={s.state}>
                {s.text}
              </li>
            ))}
          </ul>
        </>
      );
    case "edits":
      return (
        <>
          <div className="history-card-role role-edits">📝 edits</div>
          <ul className="history-card-edits">
            {kind.files.map((f, i) => (
              <li key={i}>
                <code>{f.file}</code>{" "}
                <span className="diff-add">+{f.additions}</span>{" "}
                <span className="diff-del">-{f.deletions}</span>
              </li>
            ))}
          </ul>
        </>
      );
    case "permission":
      return (
        <>
          <div className="history-card-role role-permission">⚠ permission</div>
          <div className="history-card-text">
            <strong>{kind.tool}</strong>: {kind.summary}
            {kind.decided && <span className="history-card-decision"> → {kind.decided}</span>}
          </div>
        </>
      );
    case "unknown":
    default:
      return (
        <div className="history-card-role role-unknown">?? {(kind as { raw_type: string }).raw_type}</div>
      );
  }
}

function prettyJson(s: string): string {
  try {
    return JSON.stringify(JSON.parse(s), null, 2);
  } catch {
    return s;
  }
}
