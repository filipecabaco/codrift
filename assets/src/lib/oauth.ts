import { oauthStatus, openUrl, startOAuthFlow } from "$lib/api";

/**
 * Runs a service's auth flow to completion.
 *
 * The browser does the authorizing and the backend saves the token, so there is
 * no completion event to await — polling `get_oauth_status` until the service
 * flips to connected is the handshake. Device Flow reports its short code
 * through `onCode` on the way, because the user cannot proceed without seeing it.
 *
 * Resolves when the token is saved, rejects with something worth showing if the
 * flow fails or the user never finishes it.
 */
export async function authorize(
  service: string,
  opts: { onCode?: (code: string, uri: string) => void; timeoutMs?: number } = {},
): Promise<void> {
  const res = await startOAuthFlow(service);

  if (res.flow === "device_flow") {
    opts.onCode?.(res.user_code, res.verification_uri);
    await openUrl(res.verification_uri);
  } else {
    await openUrl(res.auth_url);
  }

  await waitForConnection(service, opts.timeoutMs ?? 180_000);
}

async function waitForConnection(service: string, timeoutMs: number): Promise<void> {
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    await sleep(2000);
    try {
      const status = await oauthStatus();
      const svc = status.services[service];
      // `connected` alone is not enough on a *re*-connect: the old, spent token
      // is still on disk until the new one replaces it, so the service reads as
      // connected the whole time. `needs_reauth` clearing is the real signal.
      if (svc?.connected && !svc.needs_reauth) return;
    } catch {
      // A dropped poll is not a failed authorization — the backend may just be
      // busy. Keep trying until the deadline.
    }
  }

  throw new Error("Timed out waiting for authorization. Try again.");
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
