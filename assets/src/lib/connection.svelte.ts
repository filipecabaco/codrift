// Shared liveness state. `rpc()` flips `online` on every call (false when the
// fetch itself fails — server down / offline), and App polls `health()` to
// recover. Importing `conn` anywhere gives reactive access to the banner state.
export const conn = $state({ online: true });

// True only when the failure is a transport-level one (server unreachable),
// not an API error with a real HTTP response. Used to phrase messages.
export function markOnline() {
  if (!conn.online) conn.online = true;
}

export function markOffline() {
  if (conn.online) conn.online = false;
}

// Lightweight reachability probe. Resolves true/false and never throws, so the
// reconnect loop stays simple. Updates `conn.online` as a side effect.
export async function health(): Promise<boolean> {
  try {
    const res = await fetch("/api/health", { cache: "no-store" });
    if (res.ok) {
      markOnline();
      return true;
    }
  } catch {
    /* still unreachable */
  }
  markOffline();
  return false;
}
