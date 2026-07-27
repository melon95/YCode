import { describe, expect, it } from "vitest";
import { parseDiff } from "react-diff-view";
import { extractHunkPatch, hunkTotals } from "./diffReview";

const PATCH = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,2 +1,2 @@
-old one
+new one
 keep
@@ -10,2 +10,3 @@
 context
+added a
+added b
`;

// A hunk whose trailing context lines are blank. On the wire each blank
// context line is a lone space, so this is the shape that a whitespace-
// trimming extractor silently corrupts.
const PATCH_WITH_BLANK_TAIL = [
  "diff --git a/src/blank.ts b/src/blank.ts",
  "index 1111111..2222222 100644",
  "--- a/src/blank.ts",
  "+++ b/src/blank.ts",
  "@@ -1,5 +1,5 @@",
  " a",
  "-b",
  "+B",
  " c",
  " ",
  " ",
  "",
].join("\n");

/** Line counts a hunk actually carries, as `git apply` tallies them. */
function hunkLineCounts(patch: string): { old: number; new: number } {
  const lines = patch.split("\n");
  const start = lines.findIndex((line) => line.startsWith("@@ "));
  let oldCount = 0;
  let newCount = 0;
  for (const line of lines.slice(start + 1)) {
    if (line === "") continue;
    if (line.startsWith("-")) oldCount += 1;
    else if (line.startsWith("+")) newCount += 1;
    else {
      oldCount += 1;
      newCount += 1;
    }
  }
  return { old: oldCount, new: newCount };
}

describe("diff review helpers", () => {
  it("extracts one applicable hunk while preserving the file preamble", () => {
    const patch = extractHunkPatch(PATCH, 1);

    expect(patch).toContain("diff --git a/src/app.ts b/src/app.ts");
    expect(patch).toContain("@@ -10,2 +10,3 @@");
    expect(patch).toContain("+added b");
    expect(patch).not.toContain("@@ -1,2 +1,2 @@");
  });

  it("keeps blank trailing context so the hunk matches its @@ header", () => {
    const patch = extractHunkPatch(PATCH_WITH_BLANK_TAIL, 0);

    // The header promises 5 old / 5 new lines; dropping the two blank
    // context lines would leave 3 and git would reject the patch.
    expect(hunkLineCounts(patch)).toEqual({ old: 5, new: 5 });
    expect(patch.endsWith(" c\n \n \n")).toBe(true);
  });

  it("counts additions and deletions for the hunk toolbar", () => {
    const file = parseDiff(PATCH)[0];
    expect(hunkTotals(file.hunks[0])).toEqual({ additions: 1, deletions: 1 });
    expect(hunkTotals(file.hunks[1])).toEqual({ additions: 2, deletions: 0 });
  });
});
