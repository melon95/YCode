import { useEffect, useRef, useState } from "react";
import { Button, toast } from "@heroui/react";
import { archiveSession, renameSession, restartSession } from "../lib/ipc";
import { useStore, displaySessionTitle } from "../lib/store";
import { isRestartable, statusLabel, type SessionView } from "../lib/types";
import { confirmDialog } from "../lib/confirm";

export function SessionRow({ session: s }: { session: SessionView }) {
  const activeId = useStore((st) => st.activeId);
  const setActiveId = useStore((st) => st.setActiveId);
  const removeSession = useStore((st) => st.removeSession);
  const upsertSession = useStore((st) => st.upsertSession);
  const liveTitles = useStore((st) => st.liveTitles);

  const [editing, setEditing] = useState(false);
  const inputRef = useRef<HTMLInputElement | null>(null);

  const display = displaySessionTitle(s, liveTitles);
  const label = statusLabel(s.status);

  // Focus + select-all whenever we enter edit mode so the user can overwrite.
  useEffect(() => {
    if (editing && inputRef.current) {
      inputRef.current.focus();
      inputRef.current.select();
    }
  }, [editing]);

  function select() {
    if (editing) return;
    setActiveId(s.id);
  }

  async function commitRename(next: string) {
    setEditing(false);
    const trimmed = next.trim();
    // Same as the persisted value (or both empty) → nothing to do.
    if (trimmed === (s.title ?? "").trim()) return;
    try {
      const view = await renameSession({
        session_id: s.id,
        title: trimmed,
      });
      upsertSession(view);
    } catch (err) {
      toast.danger(`Rename failed: ${err}`);
    }
  }

  async function archive() {
    const ok = await confirmDialog({
      title: `Archive "${display}"?`,
      message: "Live processes will be killed.",
      confirmLabel: "Archive",
      destructive: true,
    });
    if (!ok) return;
    try {
      await archiveSession(s.id);
      removeSession(s.id);
    } catch (err) {
      toast.danger(`Archive failed: ${err}`);
    }
  }

  async function restart() {
    try {
      const view = await restartSession(s.id);
      upsertSession(view);
    } catch (err) {
      toast.danger(`Restart failed: ${err}`);
    }
  }

  return (
    <div
      className={"session-row" + (s.id === activeId ? " active" : "")}
      onClick={select}
      onDoubleClick={(e) => {
        e.stopPropagation();
        setEditing(true);
      }}
    >
      {editing ? (
        <input
          ref={inputRef}
          className="session-row-edit"
          defaultValue={s.title || display}
          onClick={(e) => e.stopPropagation()}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              commitRename((e.target as HTMLInputElement).value);
            } else if (e.key === "Escape") {
              e.preventDefault();
              setEditing(false);
            }
          }}
          onBlur={(e) => commitRename(e.target.value)}
        />
      ) : (
        <div className="title" title="Double-click to rename">
          {display}
        </div>
      )}
      <div className="meta">
        <span className={`dot ${label}`} />
        <span>{label}</span>
        <span style={{ marginLeft: "auto", color: "var(--muted)" }}>
          {s.agent_profile}
        </span>
      </div>
      <div className="row-actions">
        {isRestartable(s.status) && (
          <Button
            size="sm"
            variant="ghost"
            isIconOnly
            onPress={restart}
            aria-label="Restart this session"
          >
            ↻
          </Button>
        )}
        <Button
          size="sm"
          variant="ghost"
          isIconOnly
          onPress={archive}
          aria-label="Archive this session"
        >
          ×
        </Button>
      </div>
    </div>
  );
}
