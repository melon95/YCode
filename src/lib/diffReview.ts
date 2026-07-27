import type { HunkData } from "react-diff-view";

export function extractHunkPatch(patch: string, hunkIndex: number): string {
  const headers = Array.from(patch.matchAll(/^@@ .*$/gm));
  const selected = headers[hunkIndex];
  if (!selected || selected.index === undefined || headers[0]?.index === undefined) {
    throw new Error("Diff hunk is no longer available");
  }
  const end = headers[hunkIndex + 1]?.index ?? patch.length;
  const preamble = patch.slice(0, headers[0].index);
  // Strip only trailing newlines, never trailing whitespace: a blank context
  // line is the single space " " on the wire, so trimming it would drop the
  // line entirely and leave fewer lines than the "@@ -a,b +c,d @@" header
  // declares — which git rejects as a corrupt patch.
  const hunk = patch.slice(selected.index, end).replace(/\n+$/, "");
  return `${preamble}${hunk}\n`;
}

export function hunkTotals(hunk: HunkData): {
  additions: number;
  deletions: number;
} {
  let additions = 0;
  let deletions = 0;
  for (const change of hunk.changes) {
    if (change.type === "insert") additions += 1;
    if (change.type === "delete") deletions += 1;
  }
  return { additions, deletions };
}
