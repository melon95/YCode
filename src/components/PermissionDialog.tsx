import { answerPermission } from "../lib/ipc";
import { useStore } from "../lib/store";

export function PermissionDialog() {
  const activeId = useStore((s) => s.activeId);
  const perm = useStore((s) =>
    s.activeId ? s.permissions[s.activeId] : undefined,
  );
  const clearPermission = useStore((s) => s.clearPermission);

  if (!activeId || !perm) return null;

  async function answer(optionId: string) {
    if (!perm) return;
    clearPermission(perm.sessionId);
    try {
      await answerPermission({
        session_id: perm.sessionId,
        request_id: perm.requestId,
        option_id: optionId,
      });
    } catch (err) {
      alert(`answer_permission failed: ${err}`);
    }
  }

  return (
    <div className="modal-backdrop">
      <div className="modal">
        <h3>Permission requested</h3>
        <p style={{ margin: "0 0 12px 0" }}>
          <strong>{perm.toolName}</strong> — {perm.summary}
        </p>
        <div className="permission-options">
          {perm.options.map((o) => {
            const primary =
              o.kind.type === "AllowOnce" || o.kind.type === "AllowAlways";
            return (
              <button
                key={o.option_id}
                className={primary ? "primary" : ""}
                onClick={() => answer(o.option_id)}
              >
                {o.name}
              </button>
            );
          })}
        </div>
      </div>
    </div>
  );
}
