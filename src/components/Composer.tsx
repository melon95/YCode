import { useState } from "react";
import { cancelSession, sendPrompt } from "../lib/ipc";
import { useStore } from "../lib/store";
import { stateLabel } from "../lib/types";

export function Composer() {
  const [text, setText] = useState("");
  const activeSession = useStore((s) =>
    s.activeId ? s.sessions[s.activeId] : null,
  );

  const label = activeSession ? stateLabel(activeSession.state) : null;
  const canSend = label === "idle" || label === "done";
  const canCancel =
    label === "running" || label === "awaitingpermission" || label === "cancelling";

  async function send() {
    if (!activeSession || !canSend) return;
    const trimmed = text.trim();
    if (!trimmed) return;
    setText("");
    try {
      await sendPrompt({ session_id: activeSession.id, text: trimmed });
    } catch (err) {
      alert(`Send failed: ${err}`);
    }
  }

  async function cancel() {
    if (!activeSession || !canCancel) return;
    try {
      await cancelSession(activeSession.id);
    } catch (err) {
      alert(`Cancel failed: ${err}`);
    }
  }

  return (
    <div className="composer">
      <textarea
        value={text}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            send();
          }
        }}
        disabled={!canSend}
        placeholder="Send a prompt… (⌘↵ to send)"
      />
      <div className="composer-buttons">
        <button className="primary" onClick={send} disabled={!canSend}>
          Send
        </button>
        <button onClick={cancel} disabled={!canCancel}>
          Cancel
        </button>
      </div>
    </div>
  );
}
