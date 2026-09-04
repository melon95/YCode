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

const STATUS = "p-4 text-muted text-xs";

const CARD_TEXT = "font-mono text-xs m-0 whitespace-pre-wrap break-words";
const CARD_TEXT_DIM = `${CARD_TEXT} text-muted`;
const CARD_ROLE = "font-ui text-[11px] uppercase tracking-[0.4px] text-muted";
const CARD_LIST = "list-none p-0 mt-1 mr-0 mb-0 ml-0 text-xs";

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
    <div
      className="flex flex-col h-full"
      role="dialog"
      aria-label="Session history"
    >
      <div className="flex items-center gap-3 py-2.5 px-3.5 border-b border-rule bg-surface text-xs">
        <span className="inline-flex items-center gap-1.5">
          <AgentIcon
            icon={profile?.icon}
            variant={profile?.icon_variant}
            fallbackChar={profile?.display_name ?? agent}
            size={14}
          />{" "}
          {profile?.display_name ?? agent}
        </span>
        {title ? (
          <span
            className="flex-[0_1_auto] min-w-0 max-w-1/2 font-ui text-text overflow-hidden text-ellipsis whitespace-nowrap font-medium"
            title={sessionId}
          >
            {title}
          </span>
        ) : (
          <span className="font-mono text-muted" title={sessionId}>
            {sessionId.slice(0, 12)}…
          </span>
        )}
        <span className="text-muted">{events.length} events</span>
        <div
          className="ml-auto flex gap-1"
          role="tablist"
          aria-label="Filter events"
        >
          {(["all", "messages", "tools"] as Filter[]).map((f) => (
            <button
              key={f}
              type="button"
              role="tab"
              aria-selected={filter === f}
              className={`py-[3px] px-2.5 border border-rule rounded-[3px] text-text text-[11px] lowercase cursor-pointer ${
                filter === f
                  ? "bg-[rgba(var(--highlight-rgb),0.08)]"
                  : "bg-transparent"
              }`}
              onClick={() => setFilter(f)}
            >
              {f}
            </button>
          ))}
        </div>
        <button
          type="button"
          className="size-[26px] bg-transparent border border-rule rounded-[3px] text-text cursor-pointer text-base leading-none"
          onClick={onClose}
          aria-label="Close"
        >
          ×
        </button>
      </div>
      <div className="flex-1 min-h-0 overflow-y-auto py-3 px-3.5 flex flex-col gap-2.5">
        {loading && <div className={STATUS}>Loading session…</div>}
        {error && (
          <div className={`${STATUS} text-error`}>Failed: {error}</div>
        )}
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
          <div className={STATUS}>No events match this filter.</div>
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
      className={`border rounded-md py-2 px-2.5 flex flex-col gap-1 ${
        highlighted
          ? "border-accent bg-accent-ring"
          : "border-rule bg-surface"
      }`}
      data-kind={event.kind.kind}
    >
      <CardBody kind={event.kind} />
      {event.ts_ms > 0 && (
        <div className="self-end font-mono text-[10px] text-muted">
          {new Date(event.ts_ms).toLocaleTimeString()}
        </div>
      )}
    </div>
  );
}

function CardBody({ kind }: { kind: UnifiedEventKind }) {
  switch (kind.kind) {
    case "message":
      return (
        <>
          <div
            className={`${CARD_ROLE} ${
              kind.role === "user"
                ? "text-role-user"
                : kind.role === "assistant"
                  ? "text-accent"
                  : ""
            }`}
          >
            {kind.role === "user" ? "👤 you" : kind.role === "assistant" ? "🤖 assistant" : `📎 ${kind.role}`}
          </div>
          <pre className={CARD_TEXT}>{kind.text}</pre>
        </>
      );
    case "thinking":
      return (
        <>
          <div className={`${CARD_ROLE} text-role-thinking`}>💭 thinking</div>
          <pre className={CARD_TEXT_DIM}>{kind.text}</pre>
        </>
      );
    case "tool_use":
      return (
        <>
          <div className={`${CARD_ROLE} text-role-tool`}>🔧 {kind.tool}</div>
          <pre className={CARD_TEXT_DIM}>{prettyJson(kind.input_json)}</pre>
        </>
      );
    case "tool_result":
      return (
        <>
          <div className={`${CARD_ROLE} text-role-tool`}>
            {kind.status === "error" ? "❌" : "✓"} {kind.tool}
          </div>
          <pre className={CARD_TEXT_DIM}>{kind.output_excerpt}</pre>
        </>
      );
    case "plan":
      return (
        <>
          <div className={`${CARD_ROLE} text-role-plan`}>📋 plan</div>
          <ul
            className={`${CARD_LIST} [&_li[data-state=done]]:before:content-['☑_']
              [&_li[data-state=in_progress]]:before:content-['→_']
              [&_li[data-state=todo]]:before:content-['☐_']`}
          >
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
          <div className={CARD_ROLE}>📝 edits</div>
          <ul className={CARD_LIST}>
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
          <div className={CARD_ROLE}>⚠ permission</div>
          <div className={CARD_TEXT}>
            <strong>{kind.tool}</strong>: {kind.summary}
            {kind.decided && (
              <span className="text-role-plan ml-1"> → {kind.decided}</span>
            )}
          </div>
        </>
      );
    case "unknown":
    default:
      return (
        <div className={CARD_ROLE}>?? {(kind as { raw_type: string }).raw_type}</div>
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
