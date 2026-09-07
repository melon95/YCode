// Merging the sidebar's two session sources into one list.
//
// The sidebar used to show two: sessions ycode started (rows in the DB) and
// transcripts the scanner found on disk. They overlap almost entirely — in a
// real project, 23 of 25 DB rows carry a CLI session id that also appears in
// the scan — so the two blocks read as the same list twice, with different
// titles and different sort orders.
//
// Two things made it worse:
//
//   1. Resuming a session inserts a *new* DB row (the window-local ULID rolls
//      every resume), so one conversation could occupy four entries.
//   2. Those extra rows have an empty title, and the row renderer falls back
//      to the agent's name — producing a column of identical "Claude Code".
//
// Both are fixed by merging on `agent_session_id` / `session_id`, which is the
// CLI's own conversation id and the only identity that survives a resume. An
// earlier comment in Sidebar.tsx claimed deduping needed the SessionStart hook;
// that was wrong — the ids are already there.

import { i18next } from "./i18n";
import {
  sessionLight,
  type AgentProfileView,
  type DiscoveredSessionView,
  type SessionActivity,
  type SessionLight,
  type SessionView,
} from "./types";
import { STATUS_RANK, statusFromLight } from "./sessionStatus";

export interface MergedSession {
  /// Stable React key. The CLI session id when we have one, else the DB row
  /// id, else the transcript path.
  key: string;
  title: string;
  profile: AgentProfileView | undefined;
  /// The DB row, when ycode owns one. Present ⇒ clicking opens it directly,
  /// and it may carry a worktree. Absent ⇒ clicking resumes from transcript.
  live: SessionView | null;
  /// The transcript on disk, when the scanner found one.
  discovered: DiscoveredSessionView | null;
  updatedAtMs: number;
  /// Only live rows have a status light — a transcript on disk isn't running.
  light: SessionLight | null;
  /// Index of the canvas pane showing this session, or -1.
  paneIdx: number;
  hasWorktree: boolean;
}

interface MergeInput {
  live: SessionView[];
  discovered: DiscoveredSessionView[];
  agentByProfileId: Record<string, AgentProfileView>;
  /// introspect id ("claude") → the profile that parses it. Used to give a
  /// transcript-only row an icon and a name.
  profileByIntrospect: Record<string, AgentProfileView>;
  activityBySession: Record<string, SessionActivity | undefined>;
  visibleIds: string[];
}

export function mergeSessions({
  live,
  discovered,
  agentByProfileId,
  profileByIntrospect,
  activityBySession,
  visibleIds,
}: MergeInput): MergedSession[] {
  const byCliId = new Map<string, MergedSession>();
  const standalone: MergedSession[] = [];

  for (const s of live) {
    const profile = agentByProfileId[s.agent_profile];
    const light = sessionLight(s.status, activityBySession[s.id]);
    const row: MergedSession = {
      key: s.agent_session_id || s.id,
      title: liveTitle(s, profile),
      profile,
      live: s,
      discovered: null,
      updatedAtMs: s.updated_at_ms,
      light,
      paneIdx: visibleIds.indexOf(s.id),
      hasWorktree: s.worktree_path != null,
    };

    // No CLI id (a PTY-only agent, or a session that died before reporting
    // one) — nothing to merge on, so it stands alone.
    if (!s.agent_session_id) {
      standalone.push(row);
      continue;
    }

    const existing = byCliId.get(s.agent_session_id);
    if (!existing) {
      byCliId.set(s.agent_session_id, row);
      continue;
    }
    byCliId.set(s.agent_session_id, mergeDuplicateLive(existing, row));
  }

  for (const d of discovered) {
    const profile = profileByIntrospect[d.agent];
    if (!d.session_id) {
      // A malformed transcript with no id can't be resumed or matched, so
      // there is nothing useful to show for it.
      continue;
    }
    const existing = byCliId.get(d.session_id);
    if (existing) {
      existing.discovered = d;
      // The DB title is the user's rename and wins; the transcript's title is
      // what rescues the untitled rows.
      if (!hasRealTitle(existing.live) && d.title?.trim()) {
        existing.title = d.title.trim();
      }
      existing.updatedAtMs = Math.max(existing.updatedAtMs, d.modified_at_ms);
      continue;
    }
    byCliId.set(d.session_id, {
      key: d.session_id,
      title: d.title?.trim() || profile?.display_name || d.agent,
      profile,
      live: null,
      discovered: d,
      updatedAtMs: d.modified_at_ms,
      light: null,
      paneIdx: -1,
      hasWorktree: false,
    });
  }

  const rows = [...byCliId.values(), ...standalone];
  rows.sort((a, b) => {
    // Attention first, then recency. A row with no light (transcript only)
    // ranks below every live state — it isn't doing anything.
    const ra = a.light == null ? 99 : STATUS_RANK[statusFromLight(a.light)];
    const rb = b.light == null ? 99 : STATUS_RANK[statusFromLight(b.light)];
    if (ra !== rb) return ra - rb;
    return b.updatedAtMs - a.updatedAtMs;
  });
  return rows;
}

/// Two DB rows for the same conversation: keep the newer one's timestamps and
/// status, but don't lose a title or a worktree that only the older row has.
/// A resumed session's fresh row starts untitled, so the title almost always
/// comes from the one being replaced.
function mergeDuplicateLive(
  a: MergedSession,
  b: MergedSession,
): MergedSession {
  const [newer, older] = a.updatedAtMs >= b.updatedAtMs ? [a, b] : [b, a];
  return {
    ...newer,
    title: hasRealTitle(newer.live) ? newer.title : older.title,
    // Whichever row is actually on the canvas wins — that's the one the pane
    // number has to point at.
    paneIdx: newer.paneIdx >= 0 ? newer.paneIdx : older.paneIdx,
    live: newer.paneIdx >= 0 || older.paneIdx < 0 ? newer.live : older.live,
    hasWorktree: newer.hasWorktree || older.hasWorktree,
  };
}

function hasRealTitle(s: SessionView | null): boolean {
  return Boolean(s && s.title.trim());
}

/// Title for a DB row on its own, before any transcript is merged in.
/// `agent_thread_name` is what the CLI called the conversation — better than
/// the agent's product name, which every untitled row would otherwise share.
function liveTitle(s: SessionView, profile: AgentProfileView | undefined): string {
  return (
    s.title.trim() ||
    s.agent_thread_name?.trim() ||
    profile?.display_name ||
    i18next.t("ui.session")
  );
}

export type SessionBucket = "active" | "recent" | "older";

const DAY_MS = 86_400_000;

/// Split the merged list into the three groups the sidebar renders. "Active"
/// is anything with a live PTY or an agent waiting on you; the rest is split
/// by age so a project with two months of history doesn't bury this week's
/// work under a flat 90-row list.
export function bucketSessions(
  rows: MergedSession[],
  now = Date.now(),
): Record<SessionBucket, MergedSession[]> {
  const out: Record<SessionBucket, MergedSession[]> = {
    active: [],
    recent: [],
    older: [],
  };
  for (const row of rows) {
    if (row.light === "running" || row.light === "waiting") {
      out.active.push(row);
    } else if (now - row.updatedAtMs < 7 * DAY_MS) {
      out.recent.push(row);
    } else {
      out.older.push(row);
    }
  }
  return out;
}
