// ⌘K command palette — cross-session text search across the active
// project's claude + codex jsonl. Per plan §8.13 / §9.2.
//
// Debounced 200ms; results capped at 50. Selecting a hit opens it in a
// HistoryTab dialog (rendered by App.tsx via the `openHistory` callback).

import { useEffect, useMemo, useRef, useState } from "react";
import { searchSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { AgentProfileView, SearchHit } from "../lib/types";
import { AgentIcon } from "./AgentIcon";

const LIMIT = 50;
const DEBOUNCE_MS = 200;

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  onPick: (hit: SearchHit) => void;
}

export function CommandPalette({ open, onClose, onPick }: CommandPaletteProps) {
  const activeProjectId = useStore((s) => s.activeProjectId);
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
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<SearchHit[]>([]);
  const [loading, setLoading] = useState(false);
  const [focusedIdx, setFocusedIdx] = useState(0);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const reqIdRef = useRef(0);

  // Auto-focus + reset state when opened.
  useEffect(() => {
    if (open) {
      setQuery("");
      setHits([]);
      setFocusedIdx(0);
      requestAnimationFrame(() => inputRef.current?.focus());
    }
  }, [open]);

  // Debounced search.
  useEffect(() => {
    if (!open) return;
    if (!activeProjectId) return;
    if (query.trim().length < 2) {
      setHits([]);
      setLoading(false);
      return;
    }
    const myReq = ++reqIdRef.current;
    setLoading(true);
    const t = window.setTimeout(() => {
      searchSessions(activeProjectId, query, LIMIT)
        .then((results) => {
          if (myReq !== reqIdRef.current) return;
          setHits(results);
          setFocusedIdx(0);
        })
        .catch(() => {
          if (myReq !== reqIdRef.current) return;
          setHits([]);
        })
        .finally(() => {
          if (myReq === reqIdRef.current) setLoading(false);
        });
    }, DEBOUNCE_MS);
    return () => window.clearTimeout(t);
  }, [open, activeProjectId, query]);

  function onKey(e: React.KeyboardEvent<HTMLInputElement>) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
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
      onPick(hits[focusedIdx]);
      onClose();
    }
  }

  const noResults = useMemo(
    () => !loading && query.trim().length >= 2 && hits.length === 0,
    [loading, query, hits.length],
  );

  if (!open) return null;
  return (
    <div className="cmd-palette-backdrop" onClick={onClose}>
      <div className="cmd-palette" onClick={(e) => e.stopPropagation()}>
        <input
          ref={inputRef}
          type="text"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          onKeyDown={onKey}
          placeholder="Search across this project's sessions…"
          className="cmd-palette-input"
          aria-label="Search sessions"
          autoComplete="off"
          spellCheck={false}
        />
        <div className="cmd-palette-results" role="listbox">
          {loading && <div className="cmd-palette-status">Searching…</div>}
          {noResults && <div className="cmd-palette-status">No matches.</div>}
          {!loading && hits.length === 0 && query.trim().length < 2 && (
            <div className="cmd-palette-status">Type at least 2 characters.</div>
          )}
          {hits.map((hit, i) => (
            <button
              key={`${hit.jsonl_path}:${hit.seq}`}
              type="button"
              role="option"
              aria-selected={i === focusedIdx}
              className={"cmd-palette-hit" + (i === focusedIdx ? " focused" : "")}
              onMouseEnter={() => setFocusedIdx(i)}
              onClick={() => {
                onPick(hit);
                onClose();
              }}
            >
              <div className="cmd-palette-hit-meta">
                <span className={`cmd-palette-hit-agent agent-${hit.agent}`}>
                  <AgentIcon
                    icon={profileByIntrospect[hit.agent]?.icon}
                    variant={profileByIntrospect[hit.agent]?.icon_variant}
                    fallbackChar={
                      profileByIntrospect[hit.agent]?.display_name ?? hit.agent
                    }
                    size={12}
                  />{" "}
                  {profileByIntrospect[hit.agent]?.display_name ?? hit.agent}
                </span>
                <span className="cmd-palette-hit-session">{shortId(hit.session_id)}</span>
                {hit.ts_ms > 0 && (
                  <span className="cmd-palette-hit-ts">{formatRelative(hit.ts_ms)}</span>
                )}
              </div>
              <div className="cmd-palette-hit-preview">{hit.preview}</div>
            </button>
          ))}
        </div>
      </div>
    </div>
  );
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
