// Anonymous, per-install identifier used solely to de-duplicate the
// active-user pings that ride along on the update check (so the backend can
// derive DAU/MAU instead of raw request counts).
//
// It is a random UUID with NO link to the user, the machine, the network, or
// any file content. Persisted in localStorage so it survives restarts;
// wiping the app's data resets it (which simply counts as a fresh install).

const INSTANCE_ID_KEY = "ycode-instance-id";

/// Returns the stable anonymous instance id, minting one on first use.
export function getInstanceId(): string {
  try {
    const existing = window.localStorage.getItem(INSTANCE_ID_KEY);
    if (existing) return existing;
    const id = crypto.randomUUID();
    window.localStorage.setItem(INSTANCE_ID_KEY, id);
    return id;
  } catch {
    // Private mode / quota errors — fall back to an ephemeral id. This may
    // slightly inflate counts but must never block the update check.
    return crypto.randomUUID();
  }
}
