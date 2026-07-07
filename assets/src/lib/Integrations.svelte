<script lang="ts">
  import { onDestroy } from "svelte";
  import {
    oauthStatus,
    startOAuthFlow,
    revokeOAuthToken,
    openUrl,
    SERVICE_META,
    type OAuthService,
    type OAuthFlow,
  } from "$lib/api";

  let { onClose }: { onClose: () => void } = $props();

  let services = $state<Record<string, OAuthService>>({});
  let loading = $state(true);
  let error = $state<string | null>(null);

  // Per-service transient flow state. Only one service is ever "in flight".
  let busy = $state<string | null>(null); // service whose Connect was just clicked
  let waiting = $state<
    | { service: string; flow: OAuthFlow; authUrl?: string; userCode?: string; verifyUri?: string }
    | null
  >(null);
  let flowError = $state<string | null>(null);

  let poll: ReturnType<typeof setInterval> | undefined;
  let pollDeadline = 0;

  const label = (svc: string) =>
    SERVICE_META[svc]?.label ??
    svc.replace(/_/g, " ").replace(/\b\w/g, (c) => c.toUpperCase());
  const blurb = (svc: string) => SERVICE_META[svc]?.blurb ?? "";

  // Sort connected first, then alphabetically by label — done reads as progress.
  const rows = $derived(
    Object.entries(services).sort(([a, av], [b, bv]) => {
      if (av.connected !== bv.connected) return av.connected ? -1 : 1;
      return label(a).localeCompare(label(b));
    }),
  );

  async function refresh() {
    try {
      const res = await oauthStatus();
      services = res.services;
      error = null;
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }
  void refresh();

  function stopPolling() {
    clearInterval(poll);
    poll = undefined;
  }

  // Poll status until the service flips to connected (the backend saves the
  // token out-of-band: after the browser redirect for PKCE, or via the device
  // poller). Gives up after 3 min so a bailed-out flow doesn't spin forever.
  function startPolling(service: string) {
    stopPolling();
    pollDeadline = Date.now() + 3 * 60 * 1000;
    poll = setInterval(async () => {
      await refresh();
      if (services[service]?.connected) {
        stopPolling();
        waiting = null;
        busy = null;
      } else if (Date.now() > pollDeadline) {
        stopPolling();
        flowError = "Timed out waiting for authorization. Try again.";
        waiting = null;
        busy = null;
      }
    }, 2000);
  }

  async function connect(service: string) {
    flowError = null;
    busy = service;
    try {
      const res = await startOAuthFlow(service);
      switch (res.flow) {
        case "pkce_browser":
          await openUrl(res.auth_url);
          waiting = { service, flow: res.flow, authUrl: res.auth_url };
          startPolling(service);
          break;
        case "device_flow":
          await openUrl(res.verification_uri);
          waiting = {
            service,
            flow: res.flow,
            userCode: res.user_code,
            verifyUri: res.verification_uri,
          };
          startPolling(service);
          break;
      }
    } catch (e) {
      flowError = (e as Error).message;
      busy = null;
    }
  }

  async function disconnect(service: string) {
    flowError = null;
    try {
      await revokeOAuthToken(service);
      await refresh();
    } catch (e) {
      flowError = (e as Error).message;
    }
  }

  function cancelFlow() {
    stopPolling();
    waiting = null;
    busy = null;
    flowError = null;
  }

  function onkeydown(e: KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      if (waiting) cancelFlow();
      else onClose();
    }
  }

  onDestroy(stopPolling);
</script>

<svelte:window {onkeydown} />

<div
  class="fixed inset-0 z-50 flex items-start justify-center bg-black/50 pt-[12vh]"
  onclick={onClose}
  role="presentation"
>
  <div
    class="flex max-h-[76vh] w-[560px] max-w-[92vw] flex-col rounded-lg border border-border bg-surface shadow-2xl"
    onclick={(e) => e.stopPropagation()}
    role="presentation"
  >
    <div class="flex items-center justify-between border-b border-border px-4 py-3">
      <div>
        <h2 class="text-[13px] font-semibold text-fg">Integrations</h2>
        <p class="text-[11px] text-muted">Connect issue trackers so Codrift can import work.</p>
      </div>
      <button class="rounded-md p-1 text-muted hover:text-fg" onclick={onClose} aria-label="Close">✕</button>
    </div>

    {#if flowError}
      <p class="border-b border-red-500/30 bg-red-500/10 px-4 py-2 text-[11px] text-red-300">{flowError}</p>
    {/if}

    <div class="min-h-0 flex-1 overflow-y-auto p-2">
      {#if loading}
        <p class="p-3 text-xs text-muted">Loading…</p>
      {:else if error}
        <p class="p-3 text-xs text-red-400">{error}</p>
      {:else}
        {#each rows as [svc, s] (svc)}
          <div class="rounded-md px-2 py-2 hover:bg-canvas/60">
            <div class="flex items-center gap-2.5">
              <span
                class={["size-2 rounded-full", s.connected ? "bg-green-500" : "border border-muted"]}
              ></span>
              <div class="min-w-0 flex-1">
                <div class="flex items-center gap-2">
                  <span class="truncate text-xs font-semibold text-fg">{label(svc)}</span>
                  {#if s.connected}
                    <span class="text-[10px] text-green-400">connected</span>
                  {/if}
                </div>
                {#if blurb(svc)}<p class="truncate text-[11px] text-muted">{blurb(svc)}</p>{/if}
              </div>

              {#if s.connected}
                <button
                  class="rounded-md border border-border px-2.5 py-1 text-[11px] text-muted hover:text-fg"
                  onclick={() => disconnect(svc)}
                >
                  Disconnect
                </button>
              {:else}
                <button
                  class="rounded-md bg-accent/20 px-2.5 py-1 text-[11px] text-accent hover:bg-accent/30 disabled:opacity-50"
                  disabled={busy === svc || !!waiting}
                  onclick={() => connect(svc)}
                >
                  {busy === svc ? "Starting…" : "Connect"}
                </button>
              {/if}
            </div>

            <!-- In-flight browser / device flow for THIS service -->
            {#if waiting?.service === svc}
              <div class="mt-2 ml-[18px] rounded-md border border-border bg-canvas p-2.5">
                {#if waiting.flow === "device_flow"}
                  <p class="text-[11px] text-muted">Enter this code in the page that opened:</p>
                  <p class="my-1 font-mono text-base tracking-widest text-fg">{waiting.userCode}</p>
                  <button
                    class="text-[11px] text-accent hover:underline"
                    onclick={() => waiting?.verifyUri && openUrl(waiting.verifyUri)}
                  >
                    Reopen {waiting.verifyUri}
                  </button>
                {:else}
                  <p class="text-[11px] text-muted">
                    Authorize {label(svc)} in the browser window that opened, then this will update
                    automatically.
                  </p>
                  {#if waiting.authUrl}
                    <button
                      class="mt-1 text-[11px] text-accent hover:underline"
                      onclick={() => waiting?.authUrl && openUrl(waiting.authUrl)}
                    >
                      Reopen authorization page
                    </button>
                  {/if}
                {/if}
                <div class="mt-2 flex items-center gap-2">
                  <span class="size-1.5 rounded-full bg-accent motion-safe:animate-pulse"></span>
                  <span class="text-[11px] text-muted">Waiting for authorization…</span>
                  <button class="ml-auto text-[11px] text-muted hover:text-fg" onclick={cancelFlow}>
                    Cancel
                  </button>
                </div>
              </div>
            {/if}
          </div>
        {/each}
      {/if}
    </div>

    <p class="border-t border-border px-4 py-2 text-[11px] text-muted">Esc to close</p>
  </div>
</div>
