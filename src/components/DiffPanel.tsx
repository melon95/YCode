// Read-only unified-diff view for `selectedFilePath` against HEAD.
// Re-fetches when the file selection or active project changes.
//
// Rendering is intentionally simple: split the patch into lines and class
// each one (added / removed / hunk / meta / context). The sidebar is
// narrow, so long lines wrap rather than horizontal-scroll — adequate for
// a glance; future work can move this to a wider main-area pane.

import { useEffect, useState } from "react";
import { getFileDiff } from "../lib/ipc";
import { useStore } from "../lib/store";
import type { FileDiff } from "../lib/types";

type LineKind = "added" | "removed" | "hunk" | "meta" | "context";

function classify(line: string): LineKind {
  if (line.startsWith("@@")) return "hunk";
  if (
    line.startsWith("+++") ||
    line.startsWith("---") ||
    line.startsWith("diff ") ||
    line.startsWith("index ") ||
    line.startsWith("new file") ||
    line.startsWith("deleted file") ||
    line.startsWith("rename ") ||
    line.startsWith("similarity") ||
    line.startsWith("Binary files")
  ) {
    return "meta";
  }
  if (line.startsWith("+")) return "added";
  if (line.startsWith("-")) return "removed";
  return "context";
}

export function DiffPanel() {
  const selectedFilePath = useStore((s) => s.selectedFilePath);
  const activeProjectId = useStore((s) => s.activeProjectId);
  const [diff, setDiff] = useState<FileDiff | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!activeProjectId || !selectedFilePath) {
      setDiff(null);
      setError(null);
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    getFileDiff(activeProjectId, selectedFilePath)
      .then((d) => {
        if (cancelled) return;
        setDiff(d);
        setLoading(false);
      })
      .catch((err) => {
        if (cancelled) return;
        setError(String(err));
        setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [activeProjectId, selectedFilePath]);

  if (!selectedFilePath) {
    return (
      <div className="empty">
        Pick a file from the <strong>Files</strong> tab.
      </div>
    );
  }
  if (error) {
    return (
      <div className="diff-view">
        <DiffHeader path={selectedFilePath} />
        <div className="form-error" style={{ margin: 8 }}>
          {error}
        </div>
      </div>
    );
  }
  if (loading && !diff) {
    return (
      <div className="diff-view">
        <DiffHeader path={selectedFilePath} />
        <div className="empty">Loading…</div>
      </div>
    );
  }
  if (!diff) return null;

  const trimmed = diff.patch.replace(/\n+$/, "");
  if (!trimmed) {
    return (
      <div className="diff-view">
        <DiffHeader path={selectedFilePath} />
        <div className="empty">No changes against HEAD.</div>
      </div>
    );
  }

  const lines = trimmed.split("\n");

  return (
    <div className="diff-view">
      <DiffHeader path={selectedFilePath} untracked={diff.is_untracked} />
      <div className="diff-body">
        {lines.map((line, i) => (
          <div key={i} className={`diff-line ${classify(line)}`}>
            {line.length === 0 ? " " : line}
          </div>
        ))}
      </div>
    </div>
  );
}

function DiffHeader({ path, untracked }: { path: string; untracked?: boolean }) {
  return (
    <div className="diff-header">
      <span className="diff-header-path" title={path}>
        {path}
      </span>
      {untracked && <span className="diff-badge">untracked</span>}
    </div>
  );
}
