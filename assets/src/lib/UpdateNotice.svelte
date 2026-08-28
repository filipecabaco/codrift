<script lang="ts">
  // The "a new Codrift is out" dialog, and the only place that starts an update.
  //
  // It stays open across the whole run because the run ends with the app
  // quitting: the last thing the user sees is this panel saying so, not a
  // window that vanishes mid-download with no explanation.
  import Overlay from "$lib/Overlay.svelte";
  import {
    quitApp,
    startUpdate,
    updateProgress,
    type UpdateProgress,
    type UpdateStatus,
  } from "$lib/api";

  let {
    status,
    onDismiss,
    onClose,
  }: {
    status: UpdateStatus;
    /** "Later" — the notice moves to the footer badge until the next version. */
    onDismiss: () => void;
    onClose: () => void;
  } = $props();

  let progress = $state<UpdateProgress | null>(null);
  let error = $state<string | null>(null);
  let quitting = $state(false);

  const running = $derived(progress?.stage === "running");
  const done = $derived(progress?.stage === "done");
  const busy = $derived(running || quitting);

  // Homebrew owns the install: `Casks/codrift.rb` is the thing that moves, and
  // replacing the bundle underneath brew would corrupt its manifest and be
  // reverted by the next `brew upgrade` anyway. Codrift still runs the upgrade
  // — it just runs brew rather than doing the work itself.
  const viaBrew = $derived(status.manager === "homebrew");

  async function begin() {
    if (busy) return;
    error = null;
    try {
      progress = await startUpdate();
      poll();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  // Polling, not a subscription: an update runs for at most a couple of minutes
  // and ends by killing this page, which is not worth a channel on the relay.
  function poll() {
    const timer = setInterval(async () => {
      try {
        const next = await updateProgress();
        progress = next;
        if (next.stage !== "running") clearInterval(timer);
      } catch {
        // The backend going away mid-poll is expected once the handoff starts.
        clearInterval(timer);
      }
    }, 700);
  }

  async function restart() {
    quitting = true;
    try {
      await quitApp();
    } catch (e) {
      quitting = false;
      error = (e as Error).message;
    }
  }
</script>

<Overlay
  label={`Codrift ${status.latest} is available`}
  width="480px"
  onClose={busy ? () => {} : onClose}
>
  <h2 class="text-[15px] font-semibold text-fg">Codrift {status.latest} is available</h2>
  <p class="mt-0.5 text-[12px] text-muted">You're running {status.current}.</p>

  {#if viaBrew}
    <p class="mt-3 text-[12px] text-fg/80">
      This copy came from Homebrew, so the update runs through it:
      <code class="rounded bg-surface px-1 py-0.5 text-[11px]">{status.brew_command}</code>
    </p>
    <p class="mt-2 text-[12px] text-muted">
      Homebrew has to close Codrift to replace it, so the app quits and reopens on its own when
      the upgrade finishes.
    </p>
  {:else}
    <p class="mt-3 text-[12px] text-muted">
      Codrift downloads the release, checks it against the published checksum, and restarts into
      it. {status.cli_manager === "self" ? "The codrift command is updated too." : ""}
    </p>
  {/if}

  {#if progress && progress.log.length > 0}
    <ul class="mt-3 max-h-32 overflow-auto rounded-md bg-surface px-2.5 py-2 text-[11px] text-fg/70">
      {#each progress.log as line, i (i)}
        <li class="py-px">{line}</li>
      {/each}
    </ul>
  {/if}

  {#if error || progress?.error}
    <p class="mt-3 rounded-md bg-red-500/10 px-2.5 py-2 text-[12px] text-red-300" role="alert">
      {error ?? progress?.error}
    </p>
    {#if progress?.stage === "failed"}
      <p class="mt-1 text-[11px] text-muted">Nothing was replaced — Codrift is still on {status.current}.</p>
    {/if}
  {/if}

  {#if done}
    <p class="mt-3 rounded-md bg-accent/10 px-2.5 py-2 text-[12px] text-fg">
      {viaBrew
        ? "Ready to hand over. Codrift closes now and Homebrew reopens it when it's done."
        : `Ready. Codrift closes now and reopens on ${progress?.version ?? status.latest}.`}
    </p>
  {/if}

  <div class="mt-4 flex justify-end gap-2">
    {#if done}
      <button
        class="rounded-md bg-accent/20 px-3 py-1.5 text-xs text-accent hover:bg-accent/30 disabled:opacity-40"
        disabled={quitting}
        onclick={restart}
      >
        {quitting ? "Closing…" : "Close Codrift"}
      </button>
    {:else}
      <button
        class="rounded-md px-3 py-1.5 text-xs text-muted hover:text-fg disabled:opacity-40"
        disabled={busy}
        onclick={onDismiss}
      >
        Later
      </button>
      <button
        class="rounded-md bg-accent/20 px-3 py-1.5 text-xs text-accent hover:bg-accent/30 disabled:opacity-40"
        disabled={busy}
        onclick={begin}
      >
        {running ? "Updating…" : viaBrew ? "Update with Homebrew" : "Update & Restart"}
      </button>
    {/if}
  </div>
</Overlay>
