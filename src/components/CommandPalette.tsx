// ⌘K command palette — dual-mode search for the active project.
//   • Default mode: fuzzy file-name search (VS Code ⌘P style). Filters the
//     project's full file list client-side, picks files (not directories),
//     and opens the selection in the right-pane editor.
//   • `>` prefix → cross-session text search across claude + codex jsonl
//     (per plan §8.13 / §9.2). Selecting a hit opens it in a HistoryTab
//     dialog rendered by App.tsx via the `onPick` callback.
//
// Session mode is debounced 200ms (it's an IPC call); file mode runs
// synchronously on each keystroke against an in-memory list cached on open.
// Both modes cap displayed results at 50.

import { useEffect, useMemo, useRef, useState } from "react";
import { listFiles, searchSessions } from "../lib/ipc";
import { useStore } from "../lib/store";
import { useEscapeGuard } from "../lib/useEscapeGuard";
import { iconForFile } from "../lib/fileIcons";
import type { AgentProfileView, SearchHit } from "../lib/types";
import { AgentIcon } from "./AgentIcon";

const LIMIT = 50;
const SESSION_DEBOUNCE_MS = 200;
const SESSION_PREFIX = ">";

interface CommandPaletteProps {
  open: boolean;
  onClose: () => void;
  onPick: (hit: SearchHit) => void;
}

type FileHit = { kind: "file"; path: string; score: number };
type SessionHitWrapped = { kind: "session"; hit: SearchHit };
type Hit = FileHit | SessionHitWrapped;

export function CommandPalette({ open, onClose, onPick }: CommandPaletteProps) {
  const activeProjectId = useStore((s) => s.activeProjectId);
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
  const [query, setQuery] = useState("");
  const [hits, setHits] = useState<Hit[]>([]);
  const [loading, setLoading] = useState(false);
  const [focusedIdx, setFocusedIdx] = useState(0);
  const [allFiles, setAllFiles] = useState<string[]>([]);
  const inputRef = useRef<HTMLInputElement | null>(null);
  const reqIdRef = useRef(0);

  const sessionMode = query.startsWith(SESSION_PREFIX);
  const trimmedQuery = sessionMode
    ? query.slice(SESSION_PREFIX.length).trim()
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
    listFiles(activeProjectId)
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
  }, [open, activeProjectId]);

  // Run the right search per mode. File mode is synchronous (client-side
  // fuzzy); session mode is a debounced IPC call.
  useEffect(() => {
    if (!open) return;
    if (!activeProjectId) {
      setHits([]);
      setLoading(false);
      return;
    }

    if (sessionMode) {
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

    // File mode.
    setLoading(false);
    if (trimmedQuery.length === 0) {
      setHits([]);
      setFocusedIdx(0);
      return;
    }
    const scored: FileHit[] = [];
    for (const path of allFiles) {
      const score = fuzzyScore(trimmedQuery, path);
      if (score !== null) scored.push({ kind: "file", path, score });
    }
    scored.sort((a, b) => b.score - a.score);
    setHits(scored.slice(0, LIMIT));
    setFocusedIdx(0);
  }, [open, activeProjectId, sessionMode, trimmedQuery, allFiles]);

  function pick(hit: Hit) {
    if (hit.kind === "file") {
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
      pick(hits[focusedIdx]);
    }
  }

  const statusText = useMemo(() => {
    if (sessionMode) {
      if (loading) return "Searching…";
      if (trimmedQuery.length < 2) return "Type at least 2 characters to search sessions.";
      if (hits.length === 0) return "No matches.";
      return null;
    }
    if (trimmedQuery.length === 0)
      return "Type to search files. Use `>` to search session history.";
    if (hits.length === 0) return "No matching files.";
    return null;
  }, [sessionMode, loading, trimmedQuery, hits.length]);

  useEscapeGuard(onClose, open);

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
          placeholder={
            sessionMode
              ? "Search session transcripts…"
              : "Search files. Start with `>` to search sessions…"
          }
          className="cmd-palette-input"
          aria-label={sessionMode ? "Search sessions" : "Search files"}
          autoComplete="off"
          spellCheck={false}
        />
        <div className="cmd-palette-results" role="listbox">
          {statusText && <div className="cmd-palette-status">{statusText}</div>}
          {hits.map((hit, i) =>
            hit.kind === "file" ? (
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
            ),
          )}
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
